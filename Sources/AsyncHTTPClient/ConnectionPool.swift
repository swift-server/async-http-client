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
import NIO
import NIOConcurrencyHelpers
import NIOHTTP1
import NIOTLS

/// A connection pool that manages and creates new connections to hosts respecting the specified preferences
///
/// - Note: All `internal` methods of this class are thread safe
final class ConnectionPool {
    /// The configuration used to bootstrap new HTTP connections
    private let configuration: HTTPClient.Configuration

    /// The main data structure used by the `ConnectionPool` to retreive and create connections associated
    /// to a given `Key` .
    ///
    /// - Warning: This property should be accessed with proper synchronization, see `connectionProvidersLock`
    private var providers: [Key: HTTP1ConnectionProvider] = [:]

    /// The lock used by the connection pool used to ensure correct synchronization of accesses to `_connectionProviders`
    ///
    /// - Warning: This lock should always be acquired *before* `HTTP1ConnectionProvider`s `stateLock` if used in combination with it.
    private let lock = Lock()

    init(configuration: HTTPClient.Configuration) {
        self.configuration = configuration
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
    /// is used to determine if there already exists an associated `HTTP1ConnectionProvider` in `connectionProviders`.
    /// If there is, the connection provider then takes care of leasing a new connection. If a connection provider doesn't exist, it is created.
    func getConnection(for request: HTTPClient.Request, preference: HTTPClient.EventLoopPreference, on eventLoop: EventLoop, deadline: NIODeadline?) -> EventLoopFuture<Connection> {
        let key = Key(request)

        let provider: HTTP1ConnectionProvider = self.lock.withLock {
            if let existing = self.providers[key], existing.isActive {
                return existing
            } else {
                let http1Provider = HTTP1ConnectionProvider(key: key, eventLoop: eventLoop, configuration: self.configuration, pool: self)
                self.providers[key] = http1Provider
                return http1Provider
            }
        }

        return provider.getConnection(preference: preference)
    }

    func release(_ connection: Connection) {
        let connectionProvider = self.lock.withLock {
            self.providers[connection.key]
        }

        if let connectionProvider = connectionProvider {
            connectionProvider.release(connection: connection)
        }
    }

    func delete(_ provider: HTTP1ConnectionProvider) {
        self.lock.withLockVoid {
            self.providers[provider.key] = nil
        }
    }

    func close(on eventLoop: EventLoop) -> EventLoopFuture<Void> {
        let providers = self.lock.withLock {
            self.providers.values
        }

        return EventLoopFuture.andAllComplete(providers.map { $0.close(on: eventLoop) }, on: eventLoop)
    }

    var connectionProviderCount: Int {
        return self.lock.withLock {
            self.providers.count
        }
    }

    /// Used by the `ConnectionPool` to index its `HTTP1ConnectionProvider`s
    ///
    /// A key is initialized from a `URL`, it uses the components to derive a hashed value
    /// used by the `connectionProviders` dictionary to allow retrieving and creating
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
                self.unixPath = request.url.baseURL?.path ?? request.url.path
            default:
                fatalError("HTTPClient.Request scheme should already be a valid one")
            }
            self.port = request.port
            self.host = request.host
        }

        var scheme: Scheme
        var host: String
        var port: Int
        var unixPath: String = ""

        enum Scheme: Hashable {
            case http
            case https
            case unix
        }
    }

    /// A `Connection` represents a `Channel` in the context of the connection pool
    ///
    /// In the `ConnectionPool`, each `Channel` belongs to a given `HTTP1ConnectionProvider`
    /// and has a certain "lease state" (see the `isLeased` property).
    /// The role of `Connection` is to model this by storing a `Channel` alongside its associated properties
    /// so that they can be passed around together.
    ///
    /// - Warning: `Connection` properties are not thread-safe and should be used with proper synchronization
    class Connection: CustomStringConvertible {
        /// The connection pool this `Connection` belongs to.
        ///
        /// This enables calling methods like `release()` directly on a `Connection` instead of
        /// calling `pool.release(connection)`. This gives a more object oriented feel to the API
        /// and can avoid having to keep explicit references to the pool at call site.
        private let pool: ConnectionPool

        /// The `Key` of the `HTTP1ConnectionProvider` this `Connection` belongs to
        ///
        /// This lets `ConnectionPool` know the relationship between `Connection`s and `HTTP1ConnectionProvider`s
        let key: Key

        /// The `Channel` of this `Connection`
        ///
        /// - Warning: Requests that lease connections from the `ConnectionPool` are responsible
        /// for removing the specific handlers they added to the `Channel` pipeline before releasing it to the pool.
        let channel: Channel

        /// Indicates that this connection is about to close
        var isClosing: Bool = false

        init(key: Key, channel: Channel, pool: ConnectionPool) {
            self.key = key
            self.channel = channel
            self.pool = pool
        }

        var description: String {
            return "Connection { channel: \(self.channel) }"
        }

        /// Convenience property indicating wether the underlying `Channel` is active or not
        var isActiveEstimation: Bool {
            return self.channel.isActive && !self.isClosing
        }

        /// Release this `Connection` to its associated `HTTP1ConnectionProvider` in the parent `ConnectionPool`
        ///
        /// - Warning: This only releases the connection and doesn't take care of cleaning handlers in the `Channel` pipeline.
        func release() {
            self.pool.release(self)
        }

        func close() {
            self.channel.close(promise: nil)
        }

        func cancelIdleTimeout() -> EventLoopFuture<Connection> {
            return self.channel.eventLoop.flatSubmit {
                self.removeHandler(IdleStateHandler.self).flatMap { () -> EventLoopFuture<Bool> in
                    self.channel.pipeline.handler(type: IdlePoolConnectionHandler.self).flatMap { idleHandler in
                        self.channel.pipeline.removeHandler(idleHandler).flatMapError { _ in
                            self.channel.eventLoop.makeSucceededFuture(())
                        }.map {
                            idleHandler.hasNotSentClose && self.channel.isActive
                        }
                    }.flatMapError { error in
                        // These handlers are only added on connection release, they are not added
                        // when a connection is made to be instantly leased, so we ignore this error
                        if let channelError = error as? ChannelPipelineError, channelError == .notFound {
                            return self.channel.eventLoop.makeSucceededFuture(self.channel.isActive)
                        } else {
                            return self.channel.eventLoop.makeFailedFuture(error)
                        }
                    }
                }.flatMap { channelIsUsable in
                    if channelIsUsable {
                        return self.channel.eventLoop.makeSucceededFuture(self)
                    } else {
                        return self.channel.eventLoop.makeFailedFuture(InactiveChannelError())
                    }
                }
            }
        }

        struct InactiveChannelError: Error {}
    }

    /// A connection provider of `HTTP/1.1` connections with a given `Key` (host, scheme, port)
    ///
    /// On top of enabling connection reuse this provider it also facilitates the creation
    /// of concurrent requests as it has built-in politeness regarding the maximum number
    /// of concurrent requests to the server.
    class HTTP1ConnectionProvider: CustomStringConvertible {
        enum Action {
            case lease(Connection, Waiter)
            case create(Waiter)
            case delete
            case none
        }

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

        /// The maximum number of concurrent connections to a given (host, scheme, port)
        private let maximumConcurrentConnections: Int = 8

        private var active: Bool = true

        /// Opened connections that are available
        var availableConnections: CircularBuffer<Connection> = .init(initialCapacity: 8)

        /// Consumers that weren't able to get a new connection without exceeding
        /// `maximumConcurrentConnections` get a `Future<Connection>`
        /// whose associated promise is stored in `Waiter`. The promise is completed
        /// as soon as possible by the provider, in FIFO order.
        var waiters: CircularBuffer<Waiter> = .init(initialCapacity: 8)

        /// Number of opened or opening connections, used to keep track of all connections and enforcing `maximumConcurrentConnections` limit.
        var openedConnectionsCount: Int = 0

        /// Creates a new `HTTP1ConnectionProvider`
        ///
        /// - parameters:
        ///     - key: The `Key` (host, scheme, port) this provider is associated to
        ///     - configuration: The client configuration used globally by all requests
        ///     - initialConnection: The initial connection the pool initializes this provider with
        ///     - pool: The pool this provider belongs to
        init(key: ConnectionPool.Key, eventLoop: EventLoop, configuration: HTTPClient.Configuration, pool: ConnectionPool) {
            self.eventLoop = eventLoop
            self.configuration = configuration
            self.key = key
            self.pool = pool
        }

        deinit {
            assert(self.waiters.isEmpty)
            assert(self.availableConnections.isEmpty)
            assert(self.openedConnectionsCount == 0)
        }

        var description: String {
            return "HTTP1ConnectionProvider { key: \(self.key) }"
        }

        var isActive: Bool {
            return self.lock.withLock {
                self.active
            }
        }

        func execute(_ action: Action) {
            switch action {
            case .lease(let connection, let waiter):
                // check if we can vend this connection to caller
                connection.cancelIdleTimeout().flatMapError { error in
                    // if connection is already inactive, we create a new one.
                    if error is Connection.InactiveChannelError {
                        self.lock.withLockVoid {
                            self.openedConnectionsCount += 1
                        }
                        return self.makeConnection(on: waiter.preference.bestEventLoop ?? self.eventLoop)
                    }
                    return connection.channel.eventLoop.makeFailedFuture(error)
                }
                .cascade(to: waiter.promise)
            case .create(let waiter):
                self.makeConnection(on: waiter.preference.bestEventLoop ?? self.eventLoop).cascade(to: waiter.promise)
            case .delete:
                self.pool.delete(self)
            case .none:
                break
            }
        }

        func getConnection(preference: HTTPClient.EventLoopPreference) -> EventLoopFuture<Connection> {
            let waiter = Waiter(promise: self.eventLoop.makePromise(), preference: preference)

            let action: Action = self.lock.withLock {
                if let connection = self.availableConnections.popFirst() {
                    return .lease(connection, waiter)
                } else if self.openedConnectionsCount < self.maximumConcurrentConnections {
                    self.openedConnectionsCount += 1
                    return .create(waiter)
                } else {
                    self.waiters.append(waiter)
                    return .none
                }
            }

            self.execute(action)

            return waiter.promise.futureResult
        }

        func release(connection: Connection) {
            let action: Action = self.lock.withLock {
                if connection.isActiveEstimation { // If connection is alive, we can give to a next waiter
                    if let waiter = self.waiters.popFirst() {
                        return .lease(connection, waiter)
                    } else {
                        self.availableConnections.append(connection)
                        return .none
                    }
                } else {
                    if let waiter = self.waiters.popFirst() {
                        self.openedConnectionsCount += 1
                        return .create(waiter)
                    }

                    return .none
                }
            }

            // This is needed to start a new stack, otherwise, since this is called on a previous
            // future completion handler chain, it will be growing indefinitely until the connection is closed.
            // We might revisit this when https://github.com/apple/swift-nio/issues/970 is resolved.
            connection.channel.eventLoop.execute {
                self.execute(action)
            }
        }

        func delete(connection: Connection) {
            let action: Action = self.lock.withLock {
                self.openedConnectionsCount -= 1
                self.availableConnections.removeAll { $0 === connection }

                if self.openedConnectionsCount == 0 {
                    self.active = false
                    return .delete
                }

                return .none
            }

            self.execute(action)
        }

        private func processNextWaiter() {
            let action: Action = self.lock.withLock {
                if let waiter = self.waiters.popFirst() {
                    self.openedConnectionsCount += 1
                    return .create(waiter)
                } else if self.openedConnectionsCount == 0 {
                    self.active = false
                    return .delete
                }
                return .none
            }

            self.execute(action)
        }

        private func makeConnection(on eventLoop: EventLoop) -> EventLoopFuture<Connection> {
            let handshakePromise = eventLoop.makePromise(of: Void.self)
            let bootstrap = ClientBootstrap.makeHTTPClientBootstrapBase(group: eventLoop, host: self.key.host, port: self.key.port, configuration: self.configuration)
            let address = HTTPClient.resolveAddress(host: self.key.host, port: self.key.port, proxy: self.configuration.proxy)

            let channel: EventLoopFuture<Channel>
            switch self.key.scheme {
            case .http, .https:
                channel = bootstrap.connect(host: address.host, port: address.port)
            case .unix:
                channel = bootstrap.connect(unixDomainSocketPath: self.key.unixPath)
            }

            return channel.flatMap { channel -> EventLoopFuture<Connection> in
                channel.pipeline.addSSLHandlerIfNeeded(for: self.key, tlsConfiguration: self.configuration.tlsConfiguration, handshakePromise: handshakePromise)
                return handshakePromise.futureResult.flatMap {
                    channel.pipeline.addHTTPClientHandlers(leftOverBytesStrategy: .forwardBytes)
                }.map {
                    let connection = Connection(key: self.key, channel: channel, pool: self.pool)

                    channel.closeFuture.whenComplete { _ in
                        self.delete(connection: connection)
                    }

                    return connection
                }
            }.flatMapError { error in
                // This promise may not have been completed if we reach this so we fail it to avoid any leak
                handshakePromise.fail(error)

                // since we failed to create a connection, we need to decrease opened connection count
                self.lock.withLockVoid {
                    self.openedConnectionsCount -= 1
                }

                // there is no connection here anymore, we need to bootstrap next waiter
                self.processNextWaiter()
                return self.eventLoop.makeFailedFuture(error)
            }
        }

        func close(on eventLoop: EventLoop) -> EventLoopFuture<Void> {
            let waiters: CircularBuffer<Waiter> = self.lock.withLock {
                let copy = self.waiters
                self.waiters.removeAll()
                return copy
            }

            waiters.forEach { $0.promise.fail(HTTPClientError.cancelled) }

            let connections: CircularBuffer<Connection> = self.lock.withLock {
                let copy = self.availableConnections
                self.availableConnections.removeAll()
                return copy
            }

            connections.forEach { $0.close() }

            return EventLoopFuture.andAllComplete(connections.map { $0.channel.closeFuture }, on: eventLoop)
        }

        private func resolvePreference(_ preference: HTTPClient.EventLoopPreference) -> (EventLoop, Bool) {
            switch preference.preference {
            case .indifferent:
                return (self.eventLoop, false)
            case .delegate(let el):
                return (el, false)
            case .delegateAndChannel(let el), .testOnly_exact(let el, _):
                return (el, true)
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

            /// The event loop preference associated to this particular request
            /// that the provider should respect
            let preference: HTTPClient.EventLoopPreference
        }
    }
}
