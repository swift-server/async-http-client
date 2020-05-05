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
    /// is used to determine if there already exists an associated `HTTP1ConnectionProvider` in `providers`.
    /// If there is, the connection provider then takes care of leasing a new connection. If a connection provider doesn't exist, it is created.
    func getConnection(for request: HTTPClient.Request, preference: HTTPClient.EventLoopPreference, on eventLoop: EventLoop, deadline: NIODeadline?) -> EventLoopFuture<Connection> {
        let key = Key(request)

        let provider: HTTP1ConnectionProvider = self.lock.withLock {
            if let existing = self.providers[key], existing.enqueue() {
                return existing
            } else {
                let provider = HTTP1ConnectionProvider(key: key, eventLoop: eventLoop, configuration: self.configuration, pool: self)
                self.providers[key] = provider
                return provider
            }
        }

        return provider.getConnection(preference: preference)
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
}

/// A `Connection` represents a `Channel` in the context of the connection pool
///
/// In the `ConnectionPool`, each `Channel` belongs to a given `HTTP1ConnectionProvider`
/// and has a certain "lease state" (see the `inUse` property).
/// The role of `Connection` is to model this by storing a `Channel` alongside its associated properties
/// so that they can be passed around together and correct provider can be identified when connection is released.
class Connection: CustomStringConvertible {
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

    /// This indicates if connection is going to be or is used for a request.
    private var inUse: NIOAtomic<Bool>

    /// This indicates that connection is going to be closed.
    private var closing: NIOAtomic<Bool>

    init(channel: Channel, provider: HTTP1ConnectionProvider) {
        self.channel = channel
        self.provider = provider
        self.inUse = NIOAtomic.makeAtomic(value: true)
        self.closing = NIOAtomic.makeAtomic(value: false)
    }

    deinit {
        assert(!self.inUse.load())
    }

    var description: String {
        return "Connection { channel: \(self.channel) }"
    }

    /// Convenience property indicating wether the underlying `Channel` is active or not.
    var isActiveEstimation: Bool {
        return !self.isClosing && self.channel.isActive
    }

    var isClosing: Bool {
        get {
            return self.closing.load()
        }
        set {
            self.closing.store(newValue)
        }
    }

    var isInUse: Bool {
        get {
            return self.inUse.load()
        }
        set {
            return self.inUse.store(newValue)
        }
    }

    func lease() {
        self.inUse.store(true)
    }

    /// Release this `Connection` to its associated `HTTP1ConnectionProvider`.
    ///
    /// - Warning: This only releases the connection and doesn't take care of cleaning handlers in the `Channel` pipeline.
    func release() {
        assert(self.channel.eventLoop.inEventLoop)
        assert(self.inUse.load())

        self.inUse.store(false)
        self.provider.release(connection: self, inPool: false)
    }

    /// Called when channel exceeds idle time in pool.
    func timeout() {
        assert(self.channel.eventLoop.inEventLoop)

        // We can get timeout and inUse = true when we decided to lease the connection, but this action is not executed yet.
        // In this case we can ignore timeout notification. If connection was not in use, we release it from the pool, increasing
        // available capacity
        if !self.inUse.load() {
            self.closing.store(true)
            self.provider.release(connection: self, inPool: true)
            self.channel.close(promise: nil)
        }
    }

    /// Called when channel goes inactive while in the pool.
    func remoteClosed() {
        assert(self.channel.eventLoop.inEventLoop)

        // Connection can be closed remotely while we wait for `.lease` action to complete. If this
        // happens, we have no other choice but to mark connection as `closing`. If this connection is not in use,
        // the have to release it as well
        self.closing.store(true)
        if !self.inUse.load() {
            self.provider.release(connection: self, inPool: true)
        }
    }

    /// Called from `HTTP1ConnectionProvider.close` when client is shutting down.
    func close() -> EventLoopFuture<Void> {
        assert(!self.inUse.load())

        self.closing.store(true)
        return self.channel.close()
    }

    /// Sets idle timeout handler and channel inactivity listener.
    func setIdleTimeout(timeout: TimeAmount?) {
        _ = self.channel.pipeline.addHandler(IdleStateHandler(writeTimeout: timeout)).flatMap { _ in
            self.channel.pipeline.addHandler(IdlePoolConnectionHandler(connection: self))
        }
    }

    /// Removes idle timeout handler and channel inactivity listener
    func cancelIdleTimeout() -> EventLoopFuture<Void> {
        return self.removeHandler(IdleStateHandler.self).flatMap { _ in
            self.removeHandler(IdlePoolConnectionHandler.self)
        }
    }
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
        case replace(Connection, Waiter)
        case deleteProvider
        case park(Connection)
        case none
        case fail(Waiter, Error)
        indirect case parkAnd(Connection, Action)
    }

    struct ConnectionsState {
        enum State {
            case active
            case closed
        }

        private let maximumConcurrentConnections: Int
        private let eventLoop: EventLoop

        var state: State = .active

        /// Opened connections that are available
        var availableConnections: CircularBuffer<Connection> = .init(initialCapacity: 8)

        /// Consumers that weren't able to get a new connection without exceeding
        /// `maximumConcurrentConnections` get a `Future<Connection>`
        /// whose associated promise is stored in `Waiter`. The promise is completed
        /// as soon as possible by the provider, in FIFO order.
        var waiters: CircularBuffer<Waiter> = .init(initialCapacity: 8)

        /// Number of opened or opening connections, used to keep track of all connections and enforcing `maximumConcurrentConnections` limit.
        var openedConnectionsCount: Int = 0

        /// Number of enqueued requests, used to track if it is safe to delete the provider.
        var pending: Int = 1

        init(maximumConcurrentConnections: Int = 8, eventLoop: EventLoop) {
            self.maximumConcurrentConnections = maximumConcurrentConnections
            self.eventLoop = eventLoop
        }

        mutating func enqueue() -> Bool {
            switch self.state {
            case .active:
                self.pending += 1
                return true
            case .closed:
                return false
            }
        }

        mutating func acquire(waiter: Waiter) -> Action {
            switch self.state {
            case .active:
                self.pending -= 1

                let (eventLoop, required) = self.resolvePreference(waiter.preference)
                if required {
                    // If there is an opened connection on the same EL - use it
                    if let found = self.availableConnections.firstIndex(where: { $0.channel.eventLoop === eventLoop }) {
                        let connection = self.availableConnections.remove(at: found)
                        connection.lease()
                        return .lease(connection, waiter)
                    }

                    // If we can create additional connection, create
                    if self.openedConnectionsCount < self.maximumConcurrentConnections {
                        self.openedConnectionsCount += 1
                        return .create(waiter)
                    }

                    // If we cannot create additional connection, but there is one in the pool, replace it
                    if let connection = self.availableConnections.popFirst() {
                        return .replace(connection, waiter)
                    }

                    self.waiters.append(waiter)
                    return .none
                } else if let connection = self.availableConnections.popFirst() {
                    connection.lease()
                    return .lease(connection, waiter)
                } else if self.openedConnectionsCount < self.maximumConcurrentConnections {
                    self.openedConnectionsCount += 1
                    return .create(waiter)
                } else {
                    self.waiters.append(waiter)
                    return .none
                }
            case .closed:
                return .fail(waiter, ProviderClosedError())
            }
        }

        mutating func release(connection: Connection, inPool: Bool) -> Action {
            switch self.state {
            case .active:
                if connection.isActiveEstimation { // If connection is alive, we can offer it to a next waiter
                    if let waiter = self.waiters.popFirst() {
                        let (eventLoop, required) = self.resolvePreference(waiter.preference)

                        // If returned connection is on same EL or we do not require special EL - lease it
                        if connection.channel.eventLoop === eventLoop || !required {
                            connection.lease()
                            return .lease(connection, waiter)
                        }

                        // If there is an opened connection on the same loop, lease it and park returned
                        if let found = self.availableConnections.firstIndex(where: { $0.channel.eventLoop === eventLoop }) {
                            let replacement = self.availableConnections.swap(at: found, with: connection)
                            replacement.lease()
                            return .parkAnd(connection, .lease(replacement, waiter))
                        }

                        // If we can create new connection - do it
                        if self.openedConnectionsCount < self.maximumConcurrentConnections {
                            self.availableConnections.append(connection)
                            self.openedConnectionsCount += 1
                            return .parkAnd(connection, .create(waiter))
                        }

                        // If we cannot create new connections, we will have to replace returned connection with a new one on the required loop
                        return .replace(connection, waiter)
                    } else { // or park, if there are no waiters
                        self.availableConnections.append(connection)
                        return .park(connection)
                    }
                } else { // if connection is not alive, we delete it and process the next waiter
                    // this connections is now gone, we will either create new connection or do nothing
                    assert(!connection.isInUse)

                    self.openedConnectionsCount -= 1

                    if let waiter = self.waiters.popFirst() {
                        let (eventLoop, required) = self.resolvePreference(waiter.preference)

                        // If specific EL is required, we have only two options - find open one or create a new one
                        if required, let found = self.availableConnections.firstIndex(where: { $0.channel.eventLoop === eventLoop }) {
                            let connection = self.availableConnections.remove(at: found)
                            connection.lease()
                            return .lease(connection, waiter)
                        } else if !required, let connection = self.availableConnections.popFirst() {
                            connection.lease()
                            return .lease(connection, waiter)
                        } else {
                            self.openedConnectionsCount += 1
                            return .create(waiter)
                        }
                    }

                    if inPool {
                        self.availableConnections.removeAll { $0 === connection }
                    }

                    // if capacity is at max and the are no waiters and no in-flight requests for connection, we are closing this provider
                    if self.openedConnectionsCount == 0, self.pending == 0 {
                        // deactivate and remove
                        self.state = .closed
                        return .deleteProvider
                    }

                    return .none
                }
            case .closed:
                assertionFailure("should not happen")
                return .none
            }
        }

        mutating func processNextWaiter() -> Action {
            switch self.state {
            case .active:
                self.openedConnectionsCount -= 1

                if let waiter = self.waiters.popFirst() {
                    let (eventLoop, required) = self.resolvePreference(waiter.preference)

                    // If specific EL is required, we have only two options - find open one or create a new one
                    if required, let found = self.availableConnections.firstIndex(where: { $0.channel.eventLoop === eventLoop }) {
                        let connection = self.availableConnections.remove(at: found)
                        connection.lease()
                        return .lease(connection, waiter)
                    } else if !required, let connection = self.availableConnections.popFirst() {
                        connection.lease()
                        return .lease(connection, waiter)
                    } else {
                        self.openedConnectionsCount += 1
                        return .create(waiter)
                    }
                }

                // if capacity is at max and the are no waiters and no in-flight requests for connection, we are closing this provider
                if self.openedConnectionsCount == 0, self.pending == 0 {
                    // deactivate and remove
                    self.state = .closed
                    return .deleteProvider
                }

                return .none
            case .closed:
                assertionFailure("should not happen")
                return .none
            }
        }

        mutating func close() -> (CircularBuffer<Waiter>, CircularBuffer<Connection>)? {
            switch self.state {
            case .active:
                let waiters = self.waiters
                self.waiters.removeAll()

                let connections = self.availableConnections
                self.availableConnections.removeAll()

                return (waiters, connections)
            case .closed:
                return nil
            }
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
    }

    struct ProviderClosedError: Error {}

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

    var state: ConnectionsState

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
        self.state = .init(eventLoop: eventLoop)
    }

    deinit {
        assert(self.state.waiters.isEmpty)
        assert(self.state.availableConnections.isEmpty)
        assert(self.state.openedConnectionsCount == 0)
        assert(self.state.pending == 0)
    }

    var description: String {
        return "HTTP1ConnectionProvider { key: \(self.key) }"
    }

    private func execute(_ action: Action) {
        switch action {
        case .lease(let connection, let waiter):
            // if connection is became inactive, we create a new one.
            connection.cancelIdleTimeout().whenComplete { _ in
                if connection.isActiveEstimation {
                    waiter.promise.succeed(connection)
                } else {
                    connection.isInUse = false
                    self.makeConnection(on: waiter.preference.bestEventLoop ?? self.eventLoop).cascade(to: waiter.promise)
                }
            }
        case .create(let waiter):
            self.makeConnection(on: waiter.preference.bestEventLoop ?? self.eventLoop).cascade(to: waiter.promise)
        case .replace(let connection, let waiter):
            connection.cancelIdleTimeout().whenComplete {
                _ in connection.channel.close(promise: nil)
            }
            self.makeConnection(on: waiter.preference.bestEventLoop ?? self.eventLoop).cascade(to: waiter.promise)
        case .park(let connection):
            connection.setIdleTimeout(timeout: self.configuration.maximumAllowedIdleTimeInConnectionPool)
        case .deleteProvider:
            self.pool.delete(self)
        case .none:
            break
        case .parkAnd(let connection, let action):
            connection.setIdleTimeout(timeout: self.configuration.maximumAllowedIdleTimeInConnectionPool)
            self.execute(action)
        case .fail(let waiter, let error):
            waiter.promise.fail(error)
        }
    }

    /// This function is needed to ensure that there is no race between getting a provider from map, and shutting it down when there are no requests processed by it.
    func enqueue() -> Bool {
        return self.lock.withLock {
            self.state.enqueue()
        }
    }

    func getConnection(preference: HTTPClient.EventLoopPreference) -> EventLoopFuture<Connection> {
        let waiter = Waiter(promise: self.eventLoop.makePromise(), preference: preference)

        let action: Action = self.lock.withLock {
            self.state.acquire(waiter: waiter)
        }

        self.execute(action)

        return waiter.promise.futureResult
    }

    func release(connection: Connection, inPool: Bool = false) {
        let action: Action = self.lock.withLock {
            self.state.release(connection: connection, inPool: inPool)
        }

        switch action {
        case .none:
            break
        case .park, .deleteProvider:
            // Since both `.park` and `.deleteProvider` are terminal in terms of execution,
            // we can execute them immediately
            self.execute(action)
        default:
            // This is needed to start a new stack, otherwise, since this is called on a previous
            // future completion handler chain, it will be growing indefinitely until the connection is closed.
            // We might revisit this when https://github.com/apple/swift-nio/issues/970 is resolved.
            connection.channel.eventLoop.execute {
                self.execute(action)
            }
        }
    }

    func processNextWaiter() {
        let action: Action = self.lock.withLock {
            self.state.processNextWaiter()
        }

        self.execute(action)
    }

    func close(on eventLoop: EventLoop) -> EventLoopFuture<Void> {
        if let (waiters, connections) = self.lock.withLock({ self.state.close() }) {
            waiters.forEach { $0.promise.fail(HTTPClientError.cancelled) }
            return EventLoopFuture.andAllComplete(connections.map { $0.close() }, on: eventLoop)
        }
        return self.eventLoop.makeSucceededFuture(())
    }

    private func makeConnection(on eventLoop: EventLoop) -> EventLoopFuture<Connection> {
        let requiresTLS = self.key.scheme == .https
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
        case .unix:
            channel = bootstrap.connect(unixDomainSocketPath: self.key.unixPath)
        }

        return channel.flatMap { channel in
            let requiresSSLHandler = self.configuration.proxy != nil && self.key.scheme == .https
            let handshakePromise = eventLoop.makePromise(of: Void.self)

            channel.pipeline.addSSLHandlerIfNeeded(for: self.key, tlsConfiguration: self.configuration.tlsConfiguration, addSSLClient: requiresSSLHandler, handshakePromise: handshakePromise)

            return handshakePromise.futureResult.flatMap {
                channel.pipeline.addHTTPClientHandlers(leftOverBytesStrategy: .forwardBytes)
            }.flatMap {
                #if canImport(Network)
                    if #available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *), bootstrap.underlyingBootstrap is NIOTSConnectionBootstrap {
                        return channel.pipeline.addHandler(HTTPClient.NWErrorHandler(), position: .first)
                    }
                #endif
                return eventLoop.makeSucceededFuture(())
            }.map {
                Connection(channel: channel, provider: self)
            }
        }.flatMapError { error in
            #if canImport(Network)
                var error = error
                if #available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *), bootstrap.underlyingBootstrap is NIOTSConnectionBootstrap {
                    error = HTTPClient.NWErrorHandler.translateError(error)
                }
            #endif

            // there is no connection here anymore, we need to bootstrap next waiter
            self.processNextWaiter()
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

        /// The event loop preference associated to this particular request
        /// that the provider should respect
        let preference: HTTPClient.EventLoopPreference
    }
}

class IdlePoolConnectionHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = NIOAny

    let connection: Connection
    var eventSent: Bool

    init(connection: Connection) {
        self.connection = connection
        self.eventSent = false
    }

    // this is needed to detect when remote end closes connection while connection is in the pool idling
    func channelInactive(context: ChannelHandlerContext) {
        if !self.eventSent {
            self.eventSent = true
            self.connection.remoteClosed()
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let idleEvent = event as? IdleStateHandler.IdleStateEvent, idleEvent == .write {
            if !self.eventSent {
                self.eventSent = true
                self.connection.timeout()
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
