//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2019-2020 Apple Inc. and the AsyncHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation
import Logging
import NIO
import NIOConcurrencyHelpers
import NIOHTTP1
import NIOHTTPCompression
import NIOSSL
import NIOTLS
import NIOTransportServices

/// A connection pool that manages and creates new connections to hosts respecting the specified preferences
///
/// - Note: All `internal` methods of this class are thread safe
final class ConnectionPool {
    /// The configuration used to bootstrap new HTTP connections
    private let configuration: HTTPClient.Configuration

    /// The main data structure used by the `ConnectionPool` to retreive and create connections associated
    /// to a given `Key` .
    ///
    /// - Warning: This property should be accessed with proper synchronization, see `lock`
    private var providers: [Key: HTTP1ConnectionProvider] = [:]

    /// The lock used by the connection pool used to ensure correct synchronization of accesses to `providers`
    ///
    /// - Warning: This lock should always be acquired *before* `HTTP1ConnectionProvider`s `lock` if used in combination with it.
    private let lock = Lock()

    private let backgroundActivityLogger: Logger

    let sslContextCache = SSLContextCache()

    init(configuration: HTTPClient.Configuration, backgroundActivityLogger: Logger) {
        self.configuration = configuration
        self.backgroundActivityLogger = backgroundActivityLogger
    }

    /// Gets the `EventLoop` associated with the given `Key` if it exists
    ///
    /// This is part of an optimization used by the `.execute(...)` method when
    /// a request has its `EventLoopPreference` property set to `.indifferent`.
    /// Having a default `EventLoop` shared by the *channel* and the *delegate* avoids
    /// loss of performance due to `EventLoop` hopping
    func associatedEventLoop(for key: Key) -> EventLoop? {
        return self.lock.withLock {
            self.providers[key]?.eventLoop
        }
    }

    /// This method asks the pool for a connection usable by the specified `request`, respecting the specified options.
    ///
    /// - parameter request: The request that needs a `Connection`
    /// - parameter preference: The `EventLoopPreference` the connection pool will respect to lease a new connection
    /// - parameter deadline: The connection timeout
    /// - Returns: A connection  corresponding to the specified parameters
    ///
    /// When the pool is asked for a new connection, it creates a `Key` from the url associated to the `request`. This key
    /// is used to determine if there already exists an associated `HTTP1ConnectionProvider` in `providers`.
    /// If there is, the connection provider then takes care of leasing a new connection. If a connection provider doesn't exist, it is created.
    func getConnection(_ request: HTTPClient.Request,
                       preference: HTTPClient.EventLoopPreference,
                       taskEventLoop: EventLoop,
                       deadline: NIODeadline?,
                       setupComplete: EventLoopFuture<Void>,
                       logger: Logger) -> EventLoopFuture<Connection> {
        let key = Key(request)

        let provider: HTTP1ConnectionProvider = self.lock.withLock {
            if let existing = self.providers[key], existing.enqueue() {
                return existing
            } else {
                let provider = HTTP1ConnectionProvider(key: key,
                                                       eventLoop: taskEventLoop,
                                                       configuration: key.config(overriding: self.configuration),
                                                       tlsConfiguration: request.tlsConfiguration,
                                                       pool: self,
                                                       sslContextCache: self.sslContextCache,
                                                       backgroundActivityLogger: self.backgroundActivityLogger)
                let enqueued = provider.enqueue()
                assert(enqueued)
                self.providers[key] = provider
                return provider
            }
        }

        return provider.getConnection(preference: preference, setupComplete: setupComplete, logger: logger)
    }

    func delete(_ provider: HTTP1ConnectionProvider) {
        self.lock.withLockVoid {
            self.providers[provider.key] = nil
        }
    }

    func close(on eventLoop: EventLoop) -> EventLoopFuture<Bool> {
        let providers = self.lock.withLock {
            self.providers.values
        }

        return EventLoopFuture.reduce(true, providers.map { $0.close() }, on: eventLoop) { $0 && $1 }
    }

    var count: Int {
        return self.lock.withLock {
            return self.providers.count
        }
    }

    /// Used by the `ConnectionPool` to index its `HTTP1ConnectionProvider`s
    ///
    /// A key is initialized from a `URL`, it uses the components to derive a hashed value
    /// used by the `providers` dictionary to allow retrieving and creating
    /// connection providers associated to a certain request in constant time.
    struct Key: Hashable {
        init(_ request: HTTPClient.Request) {
            switch request.scheme {
            case "http":
                self.scheme = .http
            case "https":
                self.scheme = .https
            case "unix":
                self.scheme = .unix
            case "http+unix":
                self.scheme = .http_unix
            case "https+unix":
                self.scheme = .https_unix
            default:
                fatalError("HTTPClient.Request scheme should already be a valid one")
            }
            self.port = request.port
            self.host = request.host
            self.unixPath = request.socketPath
            if let tls = request.tlsConfiguration {
                self.tlsConfiguration = BestEffortHashableTLSConfiguration(wrapping: tls)
            }
        }

        var scheme: Scheme
        var host: String
        var port: Int
        var unixPath: String
        private var tlsConfiguration: BestEffortHashableTLSConfiguration?

        enum Scheme: Hashable {
            case http
            case https
            case unix
            case http_unix
            case https_unix

            var requiresTLS: Bool {
                switch self {
                case .https, .https_unix:
                    return true
                default:
                    return false
                }
            }
        }

        /// Returns a key-specific `HTTPClient.Configuration` by overriding the properties of `base`
        func config(overriding base: HTTPClient.Configuration) -> HTTPClient.Configuration {
            var config = base
            if let tlsConfiguration = self.tlsConfiguration {
                config.tlsConfiguration = tlsConfiguration.base
            }
            return config
        }
    }
}

/// A connection provider of `HTTP/1.1` connections with a given `Key` (host, scheme, port)
///
/// On top of enabling connection reuse this provider it also facilitates the creation
/// of concurrent requests as it has built-in politeness regarding the maximum number
/// of concurrent requests to the server.
class HTTP1ConnectionProvider {
    /// The client configuration used to bootstrap new requests
    private let configuration: HTTPClient.Configuration

    /// The pool this provider belongs to
    private let pool: ConnectionPool

    /// The key associated with this provider
    let key: ConnectionPool.Key

    /// The default `EventLoop` for this provider
    ///
    /// The default event loop is used to create futures and is used when creating `Channel`s for requests
    /// for which the `EventLoopPreference` is set to `.indifferent`
    let eventLoop: EventLoop

    /// The lock used to access and modify the provider state - `availableConnections`, `waiters` and `openedConnectionsCount`.
    ///
    /// - Warning: This lock should always be acquired *after* `ConnectionPool`s `lock` if used in combination with it.
    private let lock = Lock()

    var closePromise: EventLoopPromise<Void>

    var state: ConnectionsState<Connection>

    private let backgroundActivityLogger: Logger

    private let factory: HTTPConnectionPool.ConnectionFactory

    /// Creates a new `HTTP1ConnectionProvider`
    ///
    /// - parameters:
    ///     - key: The `Key` (host, scheme, port) this provider is associated to
    ///     - configuration: The client configuration used globally by all requests
    ///     - initialConnection: The initial connection the pool initializes this provider with
    ///     - pool: The pool this provider belongs to
    ///     - backgroundActivityLogger: The logger used to log activity in the background, ie. not associated with a
    ///                                 request.
    init(key: ConnectionPool.Key,
         eventLoop: EventLoop,
         configuration: HTTPClient.Configuration,
         tlsConfiguration: TLSConfiguration?,
         pool: ConnectionPool,
         sslContextCache: SSLContextCache,
         backgroundActivityLogger: Logger) {
        self.eventLoop = eventLoop
        self.configuration = configuration
        self.key = key
        self.pool = pool
        self.closePromise = eventLoop.makePromise()
        self.state = .init(eventLoop: eventLoop)
        self.backgroundActivityLogger = backgroundActivityLogger

        self.factory = HTTPConnectionPool.ConnectionFactory(
            key: self.key,
            tlsConfiguration: tlsConfiguration,
            clientConfiguration: self.configuration,
            sslContextCache: sslContextCache
        )
    }

    deinit {
        self.state.assertInvariants()
    }

    func execute(_ action: Action<Connection>, logger: Logger) {
        switch action {
        case .lease(let connection, let waiter):
            // if connection is became inactive, we create a new one.
            connection.cancelIdleTimeout().whenComplete { _ in
                if connection.isActiveEstimation {
                    logger.trace("leasing existing connection",
                                 metadata: ["ahc-connection": "\(connection)"])
                    waiter.promise.succeed(connection)
                } else {
                    logger.trace("opening fresh connection (found matching but inactive connection)",
                                 metadata: ["ahc-dead-connection": "\(connection)"])
                    self.makeChannel(preference: waiter.preference,
                                     logger: logger).whenComplete { result in
                        self.connect(result, waiter: waiter, logger: logger)
                    }
                }
            }
        case .create(let waiter):
            logger.trace("opening fresh connection (no connections to reuse available)")
            self.makeChannel(preference: waiter.preference, logger: logger).whenComplete { result in
                self.connect(result, waiter: waiter, logger: logger)
            }
        case .replace(let connection, let waiter):
            connection.cancelIdleTimeout().flatMap {
                connection.close()
            }.whenComplete { _ in
                logger.trace("opening fresh connection (replacing exising connection)",
                             metadata: ["ahc-old-connection": "\(connection)",
                                        "ahc-waiter": "\(waiter)"])
                self.makeChannel(preference: waiter.preference, logger: logger).whenComplete { result in
                    self.connect(result, waiter: waiter, logger: logger)
                }
            }
        case .park(let connection):
            logger.trace("parking connection",
                         metadata: ["ahc-connection": "\(connection)"])
            connection.setIdleTimeout(timeout: self.configuration.connectionPool.idleTimeout,
                                      logger: self.backgroundActivityLogger)
        case .closeProvider:
            logger.debug("closing provider",
                         metadata: ["ahc-provider": "\(self)"])
            self.closeAndDelete()
        case .none:
            break
        case .parkAnd(let connection, let action):
            logger.trace("parking connection & doing further action",
                         metadata: ["ahc-connection": "\(connection)",
                                    "ahc-action": "\(action)"])
            connection.setIdleTimeout(timeout: self.configuration.connectionPool.idleTimeout,
                                      logger: self.backgroundActivityLogger)
            self.execute(action, logger: logger)
        case .closeAnd(let connection, let action):
            logger.trace("closing connection & doing further action",
                         metadata: ["ahc-connection": "\(connection)",
                                    "ahc-action": "\(action)"])
            connection.channel.close(promise: nil)
            self.execute(action, logger: logger)
        case .fail(let waiter, let error):
            logger.debug("failing connection for waiter",
                         metadata: ["ahc-waiter": "\(waiter)",
                                    "ahc-error": "\(error)"])
            waiter.promise.fail(error)
        }
    }

    /// This function is needed to ensure that there is no race between getting a provider from map, and shutting it down when there are no requests processed by it.
    func enqueue() -> Bool {
        return self.lock.withLock {
            self.state.enqueue()
        }
    }

    func getConnection(preference: HTTPClient.EventLoopPreference,
                       setupComplete: EventLoopFuture<Void>,
                       logger: Logger) -> EventLoopFuture<Connection> {
        let waiter = Waiter<Connection>(promise: self.eventLoop.makePromise(), setupComplete: setupComplete, preference: preference)

        let action: Action = self.lock.withLock {
            self.state.acquire(waiter: waiter)
        }

        self.execute(action, logger: logger)

        return waiter.promise.futureResult
    }

    func connect(_ result: Result<Channel, Error>, waiter: Waiter<Connection>, logger: Logger) {
        let action: Action<Connection>
        switch result {
        case .success(let channel):
            logger.trace("successfully created connection",
                         metadata: ["ahc-connection": "\(channel)"])
            let connection = Connection(channel: channel, provider: self)
            action = self.lock.withLock {
                self.state.offer(connection: connection)
            }

            switch action {
            case .closeAnd:
                // This happens when client was shut down during connect
                logger.trace("connection cancelled due to client shutdown",
                             metadata: ["ahc-connection": "\(channel)"])
                connection.channel.close(promise: nil)
                waiter.promise.fail(HTTPClientError.cancelled)
            default:
                waiter.promise.succeed(connection)
            }
        case .failure(let error):
            logger.debug("connection attempt failed",
                         metadata: ["ahc-error": "\(error)"])
            action = self.lock.withLock {
                self.state.connectFailed()
            }
            waiter.promise.fail(error)
        }

        waiter.setupComplete.whenComplete { _ in
            self.execute(action, logger: logger)
        }
    }

    func release(connection: Connection, closing: Bool, logger: Logger) {
        logger.debug("releasing connection, request complete",
                     metadata: ["ahc-closing": "\(closing)"])
        let action: Action = self.lock.withLock {
            self.state.release(connection: connection, closing: closing)
        }

        // We close defensively here: we may have failed to actually close on other codepaths,
        // or we may be expecting the server to close. In either case, we want our FD back, so
        // we close now to cover our backs. We don't care about the result: if the channel is
        // _already_ closed, that's fine by us.
        if closing {
            connection.close(promise: nil)
        }

        switch action {
        case .none:
            break
        case .park, .closeProvider:
            // Since both `.park` and `.deleteProvider` are terminal in terms of execution,
            // we can execute them immediately
            self.execute(action, logger: logger)
        case .closeAnd, .create, .fail, .lease, .parkAnd, .replace:
            // This is needed to start a new stack, otherwise, since this is called on a previous
            // future completion handler chain, it will be growing indefinitely until the connection is closed.
            // We might revisit this when https://github.com/apple/swift-nio/issues/970 is resolved.
            connection.eventLoop.execute {
                self.execute(action, logger: logger)
            }
        }
    }

    func remoteClosed(connection: Connection, logger: Logger) {
        let action: Action = self.lock.withLock {
            self.state.remoteClosed(connection: connection)
        }

        self.execute(action, logger: logger)
    }

    func timeout(connection: Connection, logger: Logger) {
        let action: Action = self.lock.withLock {
            self.state.timeout(connection: connection)
        }

        self.execute(action, logger: logger)
    }

    private func closeAndDelete() {
        self.pool.delete(self)
        self.closePromise.succeed(())
    }

    func close() -> EventLoopFuture<Bool> {
        if let (waiters, available, leased, clean) = self.lock.withLock({ self.state.close() }) {
            waiters.forEach {
                $0.promise.fail(HTTPClientError.cancelled)
            }

            if available.isEmpty, leased.isEmpty, clean {
                self.closePromise.succeed(())
                return self.closePromise.futureResult.map { clean }
            }

            EventLoopFuture.andAllComplete(leased.map { $0.cancel() }, on: self.eventLoop).flatMap { _ in
                EventLoopFuture.andAllComplete(available.map { $0.close() }, on: self.eventLoop)
            }.whenFailure { error in
                self.closePromise.fail(error)
            }

            return self.closePromise.futureResult.map { clean }
        }

        return self.closePromise.futureResult.map { true }
    }

    private func makeChannel(preference: HTTPClient.EventLoopPreference,
                             logger: Logger) -> EventLoopFuture<Channel> {
        let connectionID = HTTPConnectionPool.Connection.ID.globalGenerator.next()
        let eventLoop = preference.bestEventLoop ?? self.eventLoop
        let deadline = NIODeadline.now() + (self.configuration.timeout.connect ?? .seconds(10))
        return self.factory.makeChannel(
            connectionID: connectionID,
            deadline: deadline,
            eventLoop: eventLoop,
            logger: logger
        ).flatMapThrowing {
            (channel, _) -> Channel in

            // add the http1.1 channel handlers
            let syncOperations = channel.pipeline.syncOperations
            try syncOperations.addHTTPClientHandlers(leftOverBytesStrategy: .forwardBytes)

            switch self.configuration.decompression {
            case .disabled:
                ()
            case .enabled(let limit):
                let decompressHandler = NIOHTTPResponseDecompressor(limit: limit)
                try syncOperations.addHandler(decompressHandler)
            }

            return channel
        }
    }

    /// A `Waiter` represents a request that waits for a connection when none is
    /// currently available
    ///
    /// `Waiter`s are created when `maximumConcurrentConnections` is reached
    /// and we cannot create new connections anymore.
    struct Waiter<ConnectionType: PoolManageableConnection> {
        /// The promise to complete once a connection is available
        let promise: EventLoopPromise<ConnectionType>

        /// Future that will be succeeded when request timeout handler and `TaskHandler` are added to the pipeline.
        let setupComplete: EventLoopFuture<Void>

        /// The event loop preference associated to this particular request
        /// that the provider should respect
        let preference: HTTPClient.EventLoopPreference
    }
}

extension CircularBuffer {
    mutating func swap(at index: Index, with value: Element) -> Element {
        let tmp = self[index]
        self[index] = value
        return tmp
    }
}
