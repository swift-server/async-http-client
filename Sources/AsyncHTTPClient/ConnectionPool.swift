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
                                                       configuration: self.configuration,
                                                       pool: self,
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
        return self.providers.count
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
        }

        var scheme: Scheme
        var host: String
        var port: Int
        var unixPath: String

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
    }
}

/// A `Connection` represents a `Channel` in the context of the connection pool
///
/// In the `ConnectionPool`, each `Channel` belongs to a given `HTTP1ConnectionProvider`
/// and has a certain "lease state" (see the `inUse` property).
/// The role of `Connection` is to model this by storing a `Channel` alongside its associated properties
/// so that they can be passed around together and correct provider can be identified when connection is released.
class Connection {
    /// The provider this `Connection` belongs to.
    ///
    /// This enables calling methods like `release()` directly on a `Connection` instead of
    /// calling `provider.release(connection)`. This gives a more object oriented feel to the API
    /// and can avoid having to keep explicit references to the pool at call site.
    let provider: HTTP1ConnectionProvider

    /// The `Channel` of this `Connection`
    ///
    /// - Warning: Requests that lease connections from the `ConnectionPool` are responsible
    /// for removing the specific handlers they added to the `Channel` pipeline before releasing it to the pool.
    let channel: Channel

    init(channel: Channel, provider: HTTP1ConnectionProvider) {
        self.channel = channel
        self.provider = provider
    }

    /// Convenience property indicating wether the underlying `Channel` is active or not.
    var isActiveEstimation: Bool {
        return self.channel.isActive
    }

    /// Release this `Connection` to its associated `HTTP1ConnectionProvider`.
    ///
    /// - Warning: This only releases the connection and doesn't take care of cleaning handlers in the `Channel` pipeline.
    func release(closing: Bool, logger: Logger) {
        assert(self.channel.eventLoop.inEventLoop)
        self.provider.release(connection: self, closing: closing, logger: logger)
    }

    /// Called when channel exceeds idle time in pool.
    func timeout(logger: Logger) {
        assert(self.channel.eventLoop.inEventLoop)
        self.provider.timeout(connection: self, logger: logger)
    }

    /// Called when channel goes inactive while in the pool.
    func remoteClosed(logger: Logger) {
        assert(self.channel.eventLoop.inEventLoop)
        self.provider.remoteClosed(connection: self, logger: logger)
    }

    func cancel() -> EventLoopFuture<Void> {
        return self.channel.triggerUserOutboundEvent(TaskCancelEvent())
    }

    /// Called from `HTTP1ConnectionProvider.close` when client is shutting down.
    func close() -> EventLoopFuture<Void> {
        return self.channel.close()
    }

    /// Sets idle timeout handler and channel inactivity listener.
    func setIdleTimeout(timeout: TimeAmount?, logger: Logger) {
        _ = self.channel.pipeline.addHandler(IdleStateHandler(writeTimeout: timeout), position: .first).flatMap { _ in
            self.channel.pipeline.addHandler(IdlePoolConnectionHandler(connection: self,
                                                                       logger: logger))
        }
    }

    /// Removes idle timeout handler and channel inactivity listener
    func cancelIdleTimeout() -> EventLoopFuture<Void> {
        return self.removeHandler(IdleStateHandler.self).flatMap { _ in
            self.removeHandler(IdlePoolConnectionHandler.self)
        }
    }
}

struct ConnectionKey: Hashable {
    let connection: Connection

    init(_ connection: Connection) {
        self.connection = connection
    }

    static func == (lhs: ConnectionKey, rhs: ConnectionKey) -> Bool {
        return ObjectIdentifier(lhs.connection) == ObjectIdentifier(rhs.connection)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self.connection))
    }

    func cancel() -> EventLoopFuture<Void> {
        return self.connection.cancel()
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

    var state: ConnectionsState

    private let backgroundActivityLogger: Logger

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
         pool: ConnectionPool,
         backgroundActivityLogger: Logger) {
        self.eventLoop = eventLoop
        self.configuration = configuration
        self.key = key
        self.pool = pool
        self.closePromise = eventLoop.makePromise()
        self.state = .init(eventLoop: eventLoop)
        self.backgroundActivityLogger = backgroundActivityLogger
    }

    deinit {
        self.state.assertInvariants()
    }

    func execute(_ action: Action, logger: Logger) {
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
                    self.makeChannel(preference: waiter.preference).whenComplete { result in
                        self.connect(result, waiter: waiter, replacing: connection, logger: logger)
                    }
                }
            }
        case .create(let waiter):
            logger.trace("opening fresh connection (no connections to reuse available)")
            self.makeChannel(preference: waiter.preference).whenComplete { result in
                self.connect(result, waiter: waiter, logger: logger)
            }
        case .replace(let connection, let waiter):
            connection.cancelIdleTimeout().flatMap {
                connection.close()
            }.whenComplete { _ in
                logger.trace("opening fresh connection (replacing exising connection)",
                             metadata: ["ahc-old-connection": "\(connection)",
                                        "ahc-waiter": "\(waiter)"])
                self.makeChannel(preference: waiter.preference).whenComplete { result in
                    self.connect(result, waiter: waiter, replacing: connection, logger: logger)
                }
            }
        case .park(let connection):
            logger.trace("parking connection",
                         metadata: ["ahc-connection": "\(connection)"])
            connection.setIdleTimeout(timeout: self.configuration.maximumAllowedIdleTimeInConnectionPool,
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
            connection.setIdleTimeout(timeout: self.configuration.maximumAllowedIdleTimeInConnectionPool,
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
        let waiter = Waiter(promise: self.eventLoop.makePromise(), setupComplete: setupComplete, preference: preference)

        let action: Action = self.lock.withLock {
            self.state.acquire(waiter: waiter)
        }

        self.execute(action, logger: logger)

        return waiter.promise.futureResult
    }

    func connect(_ result: Result<Channel, Error>,
                 waiter: Waiter,
                 replacing closedConnection: Connection? = nil,
                 logger: Logger) {
        let action: Action
        switch result {
        case .success(let channel):
            logger.trace("successfully created connection",
                         metadata: ["ahc-connection": "\(channel)"])
            let connection = Connection(channel: channel, provider: self)
            action = self.lock.withLock {
                if let closedConnection = closedConnection {
                    self.state.drop(connection: closedConnection)
                }
                return self.state.offer(connection: connection)
            }

            switch action {
            case .closeAnd:
                // This happens when client was shut down during connect
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
            connection.channel.eventLoop.execute {
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

    private func makeChannel(preference: HTTPClient.EventLoopPreference) -> EventLoopFuture<Channel> {
        let eventLoop = preference.bestEventLoop ?? self.eventLoop
        let requiresTLS = self.key.scheme.requiresTLS
        let bootstrap: NIOClientTCPBootstrap
        do {
            bootstrap = try NIOClientTCPBootstrap.makeHTTPClientBootstrapBase(on: eventLoop, host: self.key.host, port: self.key.port, requiresTLS: requiresTLS, configuration: self.configuration)
        } catch {
            return eventLoop.makeFailedFuture(error)
        }

        let channel: EventLoopFuture<Channel>
        switch self.key.scheme {
        case .http, .https:
            let address = HTTPClient.resolveAddress(host: self.key.host, port: self.key.port, proxy: self.configuration.proxy)
            channel = bootstrap.connect(host: address.host, port: address.port)
        case .unix, .http_unix, .https_unix:
            channel = bootstrap.connect(unixDomainSocketPath: self.key.unixPath)
        }

        return channel.flatMap { channel in
            let requiresSSLHandler = self.configuration.proxy != nil && self.key.scheme.requiresTLS
            let handshakePromise = channel.eventLoop.makePromise(of: Void.self)

            channel.pipeline.addSSLHandlerIfNeeded(for: self.key, tlsConfiguration: self.configuration.tlsConfiguration, addSSLClient: requiresSSLHandler, handshakePromise: handshakePromise)

            return handshakePromise.futureResult.flatMap {
                channel.pipeline.addHTTPClientHandlers(leftOverBytesStrategy: .forwardBytes)
            }.flatMap {
                #if canImport(Network)
                    if #available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *), bootstrap.underlyingBootstrap is NIOTSConnectionBootstrap {
                        return channel.pipeline.addHandler(HTTPClient.NWErrorHandler(), position: .first)
                    }
                #endif
                return channel.eventLoop.makeSucceededFuture(())
            }.flatMap {
                switch self.configuration.decompression {
                case .disabled:
                    return channel.eventLoop.makeSucceededFuture(())
                case .enabled(let limit):
                    let decompressHandler = NIOHTTPResponseDecompressor(limit: limit)
                    return channel.pipeline.addHandler(decompressHandler)
                }
            }.map {
                channel
            }
        }.flatMapError { error in
            #if canImport(Network)
                var error = error
                if #available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *), bootstrap.underlyingBootstrap is NIOTSConnectionBootstrap {
                    error = HTTPClient.NWErrorHandler.translateError(error)
                }
            #endif
            return self.eventLoop.makeFailedFuture(error)
        }
    }

    /// A `Waiter` represents a request that waits for a connection when none is
    /// currently available
    ///
    /// `Waiter`s are created when `maximumConcurrentConnections` is reached
    /// and we cannot create new connections anymore.
    struct Waiter {
        /// The promise to complete once a connection is available
        let promise: EventLoopPromise<Connection>

        /// Future that will be succeeded when request timeout handler and `TaskHandler` are added to the pipeline.
        let setupComplete: EventLoopFuture<Void>

        /// The event loop preference associated to this particular request
        /// that the provider should respect
        let preference: HTTPClient.EventLoopPreference
    }
}

class IdlePoolConnectionHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = NIOAny

    let connection: Connection
    var eventSent: Bool
    let logger: Logger

    init(connection: Connection, logger: Logger) {
        self.connection = connection
        self.eventSent = false
        self.logger = logger
    }

    // this is needed to detect when remote end closes connection while connection is in the pool idling
    func channelInactive(context: ChannelHandlerContext) {
        if !self.eventSent {
            self.eventSent = true
            self.connection.remoteClosed(logger: self.logger)
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let idleEvent = event as? IdleStateHandler.IdleStateEvent, idleEvent == .write {
            if !self.eventSent {
                self.eventSent = true
                self.connection.timeout(logger: self.logger)
            }
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }
}

extension CircularBuffer {
    mutating func swap(at index: Index, with value: Element) -> Element {
        let tmp = self[index]
        self[index] = value
        return tmp
    }
}
