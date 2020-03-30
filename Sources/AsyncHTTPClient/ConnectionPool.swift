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
import NIOSSL
import NIOTransportServices
import NIOTLS

/// A connection pool that manages and creates new connections to hosts respecting the specified preferences
///
/// - Note: All `internal` methods of this class are thread safe
final class ConnectionPool {
    /// The configuration used to bootstrap new HTTP connections
    private let configuration: HTTPClient.Configuration

    /// The main data structure used by the `ConnectionPool` to retreive and create connections associated
    /// to a given `Key` .
    /// - Warning: This property should be accessed with proper synchronization, see `connectionProvidersLock`
    private var connectionProviders: [Key: HTTP1ConnectionProvider] = [:]

    /// The lock used by the connection pool used to ensure correct synchronization of accesses to `_connectionProviders`
    ///
    ///
    /// - Warning: This lock should always be acquired *before* `HTTP1ConnectionProvider`s `stateLock` if used in combination with it.
    private let connectionProvidersLock = Lock()

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
        return self.connectionProvidersLock.withLock {
            self.connectionProviders[key]?.eventLoop
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

        let provider: HTTP1ConnectionProvider = self.connectionProvidersLock.withLock {
            if let existing = self.connectionProviders[key] {
                existing.stateLock.withLock {
                    existing.state.pending += 1
                }
                return existing
            } else {
                let http1Provider = HTTP1ConnectionProvider(key: key, eventLoop: eventLoop, configuration: self.configuration, parentPool: self)
                self.connectionProviders[key] = http1Provider
                http1Provider.stateLock.withLock {
                    http1Provider.state.pending += 1
                }
                return http1Provider
            }
        }

        return provider.getConnection(preference: preference)
    }

    func release(_ connection: Connection) {
        let connectionProvider = self.connectionProvidersLock.withLock {
            self.connectionProviders[connection.key]
        }
        if let connectionProvider = connectionProvider {
            connectionProvider.release(connection: connection)
        }
    }

    func prepareForClose(on eventLoop: EventLoop) -> EventLoopFuture<Void> {
        let connectionProviders = self.connectionProvidersLock.withLock {
            self.connectionProviders.values
        }

        return EventLoopFuture<Void>.andAllComplete(connectionProviders.map { $0.prepareForClose() }, on: eventLoop)
    }

    func close(on eventLoop: EventLoop) -> EventLoopFuture<Void> {
        let connectionProviders = self.connectionProvidersLock.withLock {
            self.connectionProviders.values
        }

        return EventLoopFuture.andAllComplete(connectionProviders.map { $0.close() }, on: eventLoop).map {
            self.connectionProvidersLock.withLock {
                assert(self.connectionProviders.count == 0, "left-overs: \(self.connectionProviders)")
            }
        }
    }

    var connectionProviderCount: Int {
        return self.connectionProvidersLock.withLock {
            self.connectionProviders.count
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
        init(key: Key, channel: Channel, parentPool: ConnectionPool) {
            self.key = key
            self.channel = channel
            self.parentPool = parentPool
            self.closePromise = channel.eventLoop.makePromise(of: Void.self)
            self.closeFuture = self.closePromise.futureResult
        }

        /// Release this `Connection` to its associated `HTTP1ConnectionProvider` in the parent `ConnectionPool`
        ///
        /// This is exactly equivalent to calling `.release(theProvider)` on `ConnectionPool`
        ///
        /// - Warning: This only releases the connection and doesn't take care of cleaning handlers in the
        ///  `Channel` pipeline.
        func release() {
            self.parentPool.release(self)
        }

        func close() -> EventLoopFuture<Void> {
            self.channel.close(promise: nil)
            return self.closeFuture
        }

        var description: String {
            return "Connection { channel: \(self.channel) }"
        }

        /// The connection pool this `Connection` belongs to.
        ///
        /// This enables calling methods like `release()` directly on a `Connection` instead of
        /// calling `pool.release(connection)`. This gives a more object oriented feel to the API
        /// and can avoid having to keep explicit references to the pool at call site.
        let parentPool: ConnectionPool

        /// The `Key` of the `HTTP1ConnectionProvider` this `Connection` belongs to
        ///
        /// This lets `ConnectionPool` know the relationship between `Connection`s and `HTTP1ConnectionProvider`s
        fileprivate let key: Key

        /// The `Channel` of this `Connection`
        ///
        /// - Warning: Requests that lease connections from the `ConnectionPool` are responsible
        /// for removing the specific handlers they added to the `Channel` pipeline before releasing it to the pool.
        let channel: Channel

        /// Wether the connection is currently leased or not
        var isLeased: Bool = false

        /// Indicates that this connection is about to close
        var isClosing: Bool = false

        /// Indicates wether the usual close callback should be run or not, this allows customizing what happens
        /// on close in some cases such as for the `.replaceConnection` action
        ///
        /// - Warning: This should be accessed under the `stateLock` of `HTTP1ConnectionProvider`
        fileprivate var mustRunDefaultCloseCallback: Bool = true

        /// Convenience property indicating wether the underlying `Channel` is active or not
        var isActiveEstimation: Bool {
            return self.channel.isActive
        }

        fileprivate var closePromise: EventLoopPromise<Void>

        var closeFuture: EventLoopFuture<Void>

        func removeIdleConnectionHandlersForLease() -> EventLoopFuture<Connection> {
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
        /// The default `EventLoop` for this provider
        ///
        /// The default event loop is used to create futures and is used
        /// when creating `Channel`s for requests for which the
        /// `EventLoopPreference` is set to `.indifferent`
        let eventLoop: EventLoop

        /// The client configuration used to bootstrap new requests
        private let configuration: HTTPClient.Configuration

        /// The key associated with this provider
        private let key: ConnectionPool.Key

        /// The `State` of this provider
        ///
        /// This property holds data structures representing the current state of the provider
        /// - Warning: This type isn't thread safe and should be accessed with proper
        /// synchronization (see the `stateLock` property)
        fileprivate var state: State

        /// The lock used to access and modify the `state` property
        ///
        /// - Warning: This lock should always be acquired *after* `ConnectionPool`s `connectionProvidersLock` if used in combination with it.
        fileprivate let stateLock = Lock()

        /// The maximum number of concurrent connections to a given (host, scheme, port)
        private let maximumConcurrentConnections: Int = 8

        /// The pool this provider belongs to
        private let parentPool: ConnectionPool

        /// Creates a new `HTTP1ConnectionProvider`
        ///
        /// - parameters:
        ///     - key: The `Key` (host, scheme, port) this provider is associated to
        ///     - configuration: The client configuration used globally by all requests
        ///     - initialConnection: The initial connection the pool initializes this provider with
        ///     - parentPool: The pool this provider belongs to
        init(key: ConnectionPool.Key, eventLoop: EventLoop, configuration: HTTPClient.Configuration, parentPool: ConnectionPool) {
            self.eventLoop = eventLoop
            self.configuration = configuration
            self.key = key
            self.parentPool = parentPool
            self.state = State(eventLoop: eventLoop, parentPool: parentPool, key: key)
        }

        deinit {
            assert(self.state.activity == .closed, "Non closed on deinit")
            assert(self.state.availableConnections.isEmpty, "Available connections should be empty before deinit")
            assert(self.state.leased == 0, "All leased connections should have been returned before deinit")
            assert(self.state.waiters.count == 0, "Waiters on deinit: \(self.state.waiters)")
        }

        var description: String {
            return "HTTP1ConnectionProvider { key: \(self.key), state: \(self.state) }"
        }

        func getConnection(preference: HTTPClient.EventLoopPreference) -> EventLoopFuture<Connection> {
            self.activityPrecondition(expected: [.opened])
            let action = self.stateLock.withLock { self.state.connectionAction(for: preference) }
            switch action {
            case .leaseConnection(let connection):
                return connection.removeIdleConnectionHandlersForLease().flatMapError { _ in
                    connection.closeFuture.flatMap { // We ensure close actions are run first
                        let defaultEventLoop = self.stateLock.withLock {
                            self.state.defaultEventLoop
                        }
                        return self.makeConnection(on: preference.bestEventLoop ?? defaultEventLoop)
                    }
                }
            case .makeConnection(let eventLoop):
                return self.makeConnection(on: eventLoop)
            case .leaseFutureConnection(let futureConnection):
                return futureConnection
            }
        }

        func release(connection: Connection) {
            self.activityPrecondition(expected: [.opened, .closing])
            let action = self.parentPool.connectionProvidersLock.withLock {
                self.stateLock.withLock { self.state.releaseAction(for: connection) }
            }
            switch action {
            case .succeed(let promise):
                promise.succeed(connection)

            case .makeConnectionAndComplete(let eventLoop, let promise):
                self.makeConnection(on: eventLoop).cascade(to: promise)

            case .replaceConnection(let eventLoop, let promise):
                connection.close().flatMap {
                    self.makeConnection(on: eventLoop)
                }.whenComplete { result in
                    switch result {
                    case .success(let connection):
                        promise.succeed(connection)
                    case .failure(let error):
                        promise.fail(error)
                    }
                }

            case .none:
                break
            }
        }

        private func makeConnection(on eventLoop: EventLoop) -> EventLoopFuture<Connection> {
            self.activityPrecondition(expected: [.opened])
            let address = HTTPClient.resolveAddress(host: self.key.host, port: self.key.port, proxy: self.configuration.proxy)
            let bootstrap : NIOClientTCPBootstrap
            do {
                bootstrap = try NIOClientTCPBootstrap.makeHTTPClientBootstrapBase(on: eventLoop, host: key.host, port: key.port, requiresTLS: self.key.scheme == .https, configuration: self.configuration)
            } catch {
                return eventLoop.makeFailedFuture(error)
            }

            let channel: EventLoopFuture<Channel>
            switch self.key.scheme {
            case .http, .https:
                channel = bootstrap.connect(host: address.host, port: address.port)
            case .unix:
                channel = bootstrap.connect(unixDomainSocketPath: self.key.unixPath)
            }

            return channel.flatMap { channel -> EventLoopFuture<ConnectionPool.Connection> in
                
                channel.pipeline.addHTTPClientHandlers(leftOverBytesStrategy: .forwardBytes).map {
                    let connection = Connection(key: self.key, channel: channel, parentPool: self.parentPool)
                    connection.isLeased = true
                    return connection
                }
            }.map { connection in
                self.configureCloseCallback(of: connection)
                return connection
            }.flatMapError { error in
                let action = self.parentPool.connectionProvidersLock.withLock {
                    self.stateLock.withLock {
                        self.state.failedConnectionAction()
                    }
                }
                switch action {
                case .makeConnectionAndComplete(let el, let promise):
                    self.makeConnection(on: el).cascade(to: promise)
                case .none:
                    break
                }
                return self.eventLoop.makeFailedFuture(error)
            }
        }

        /// Adds a callback on connection close that asks the `state` what to do about this
        ///
        /// The callback informs the state about the event, and the state returns a
        /// `ClosedConnectionRemoveAction` which instructs it about what it should do.
        private func configureCloseCallback(of connection: Connection) {
            connection.channel.closeFuture.whenComplete { result in
                let action: HTTP1ConnectionProvider.State.ClosedConnectionRemoveAction? = self.parentPool.connectionProvidersLock.withLock {
                    self.stateLock.withLock {
                        guard connection.mustRunDefaultCloseCallback else {
                            return nil
                        }
                        switch result {
                        case .success:
                            return self.state.removeClosedConnection(connection)

                        case .failure(let error):
                            preconditionFailure("Connection close future failed with error: \(error)")
                        }
                    }
                }

                if let action = action {
                    switch action {
                    case .makeConnectionAndComplete(let el, let promise):
                        self.makeConnection(on: el).cascade(to: promise)
                    case .none:
                        break
                    }
                }

                connection.closePromise.succeed(())
            }
        }

        /// Removes and fails all `waiters`, remove existing `availableConnections` and sets `state.activity` to `.closing`
        func prepareForClose() -> EventLoopFuture<Void> {
            let (waitersFutures, closeFutures) = self.stateLock.withLock { () -> ([EventLoopFuture<Connection>], [EventLoopFuture<Void>]) in
                // Fail waiters
                let waitersCopy = self.state.waiters
                self.state.waiters.removeAll()
                let waitersPromises = waitersCopy.map { $0.promise }
                let waitersFutures = waitersPromises.map { $0.futureResult }
                waitersPromises.forEach { $0.fail(HTTPClientError.cancelled) }
                let closeFutures = self.state.availableConnections.map { $0.close() }
                return (waitersFutures, closeFutures)
            }

            return EventLoopFuture<Connection>.andAllComplete(waitersFutures, on: self.eventLoop)
                .flatMap {
                    EventLoopFuture<Void>.andAllComplete(closeFutures, on: self.eventLoop)
                }
                .map { _ in
                    self.stateLock.withLock {
                        if self.state.leased == 0, self.state.availableConnections.isEmpty {
                            self.state.activity = .closed
                        } else {
                            self.state.activity = .closing
                        }
                    }
                }
        }

        func close() -> EventLoopFuture<Void> {
            let availableConnections = self.stateLock.withLock { () -> CircularBuffer<ConnectionPool.Connection> in
                assert(self.state.activity == .closing)
                return self.state.availableConnections
            }

            return EventLoopFuture<Void>.andAllComplete(availableConnections.map { $0.close() }, on: self.eventLoop)
        }

        private func activityPrecondition(expected: Set<State.Activity>) {
            self.stateLock.withLock {
                precondition(expected.contains(self.state.activity), "Attempting to use HTTP1ConnectionProvider with unexpected state: \(self.state.activity) (expected: \(expected))")
            }
        }

        fileprivate struct State {
            /// The default `EventLoop` to use for this `HTTP1ConnectionProvider`
            let defaultEventLoop: EventLoop

            /// The maximum number of connections to a certain (host, scheme, port) tuple.
            private let maximumConcurrentConnections: Int = 8

            /// Opened connections that are available
            fileprivate var availableConnections: CircularBuffer<Connection> = .init(initialCapacity: 8)

            /// The number of currently leased connections
            fileprivate var leased: Int = 0 {
                didSet {
                    assert((0...self.maximumConcurrentConnections).contains(self.leased), "Invalid number of leased connections (\(self.leased))")
                }
            }

            /// Consumers that weren't able to get a new connection without exceeding
            /// `maximumConcurrentConnections` get a `Future<Connection>`
            /// whose associated promise is stored in `Waiter`. The promise is completed
            /// as soon as possible by the provider, in FIFO order.
            fileprivate var waiters: CircularBuffer<Waiter> = .init(initialCapacity: 8)

            fileprivate var activity: Activity = .opened

            fileprivate var pending: Int = 0 {
                didSet {
                    assert(self.pending >= 0)
                }
            }

            private let parentPool: ConnectionPool

            private let key: Key

            fileprivate init(eventLoop: EventLoop, parentPool: ConnectionPool, key: Key) {
                self.defaultEventLoop = eventLoop
                self.parentPool = parentPool
                self.key = key
            }

            fileprivate mutating func connectionAction(for preference: HTTPClient.EventLoopPreference) -> ConnectionGetAction {
                self.pending -= 1
                let (channelEL, requiresSpecifiedEL) = self.resolvePreference(preference)
                if self.leased < self.maximumConcurrentConnections {
                    self.leased += 1
                    if let connection = availableConnections.swapWithFirstAndRemove(where: { $0.channel.eventLoop === channelEL }) {
                        connection.isLeased = true
                        return .leaseConnection(connection)
                    } else {
                        if requiresSpecifiedEL {
                            return .makeConnection(channelEL)
                        } else if let existingConnection = availableConnections.popFirst() {
                            return .leaseConnection(existingConnection)
                        } else {
                            return .makeConnection(self.defaultEventLoop)
                        }
                    }
                } else {
                    let promise = channelEL.makePromise(of: Connection.self)
                    self.waiters.append(Waiter(promise: promise, preference: preference))
                    return .leaseFutureConnection(promise.futureResult)
                }
            }

            fileprivate mutating func releaseAction(for connection: Connection) -> ConnectionReleaseAction {
                if let firstWaiter = self.waiters.popFirst() {
                    let (channelEL, requiresSpecifiedEL) = self.resolvePreference(firstWaiter.preference)

                    guard connection.isActiveEstimation, !connection.isClosing else {
                        return .makeConnectionAndComplete(channelEL, firstWaiter.promise)
                    }

                    if connection.channel.eventLoop === channelEL {
                        return .succeed(firstWaiter.promise)
                    } else {
                        if requiresSpecifiedEL {
                            connection.mustRunDefaultCloseCallback = false
                            return .replaceConnection(channelEL, firstWaiter.promise)
                        } else {
                            return .makeConnectionAndComplete(channelEL, firstWaiter.promise)
                        }
                    }

                } else {
                    connection.isLeased = false
                    self.leased -= 1
                    if connection.isActiveEstimation, !connection.isClosing {
                        self.availableConnections.append(connection)
                    }

                    if self.providerMustClose() {
                        self.removeFromPool()
                    }

                    return .none
                }
            }

            fileprivate mutating func removeClosedConnection(_ connection: Connection) -> ClosedConnectionRemoveAction {
                if connection.isLeased {
                    if let firstWaiter = self.waiters.popFirst() {
                        let (el, _) = self.resolvePreference(firstWaiter.preference)
                        return .makeConnectionAndComplete(el, firstWaiter.promise)
                    }
                } else {
                    self.availableConnections.swapWithFirstAndRemove(where: { $0 === connection })
                }

                if self.providerMustClose() {
                    self.removeFromPool()
                }

                return .none
            }

            fileprivate mutating func failedConnectionAction() -> ClosedConnectionRemoveAction {
                if let firstWaiter = self.waiters.popFirst() {
                    let (el, _) = self.resolvePreference(firstWaiter.preference)
                    return .makeConnectionAndComplete(el, firstWaiter.promise)
                } else {
                    self.leased -= 1
                    if self.providerMustClose() {
                        self.removeFromPool()
                    }
                    return .none
                }
            }

            private func providerMustClose() -> Bool {
                return self.pending == 0 && self.activity != .closed && self.leased == 0 && self.availableConnections.isEmpty && self.waiters.isEmpty
            }

            /// - Warning: This should always be called from a critical section protected by `.connectionProvidersLock`
            fileprivate mutating func removeFromPool() {
                assert(self.parentPool.connectionProviders[self.key] != nil)
                self.parentPool.connectionProviders[self.key] = nil
                assert(self.activity != .closed)
                self.activity = .closed
            }

            private func resolvePreference(_ preference: HTTPClient.EventLoopPreference) -> (EventLoop, Bool) {
                switch preference.preference {
                case .indifferent:
                    return (self.defaultEventLoop, false)
                case .delegate(let el):
                    return (el, false)
                case .delegateAndChannel(let el), .testOnly_exact(let el, _):
                    return (el, true)
                }
            }

            fileprivate enum ConnectionGetAction {
                case leaseConnection(Connection)
                case makeConnection(EventLoop)
                case leaseFutureConnection(EventLoopFuture<Connection>)
            }

            fileprivate enum ConnectionReleaseAction {
                case succeed(EventLoopPromise<Connection>)
                case makeConnectionAndComplete(EventLoop, EventLoopPromise<Connection>)
                case replaceConnection(EventLoop, EventLoopPromise<Connection>)
                case none
            }

            fileprivate enum ClosedConnectionRemoveAction {
                case none
                case makeConnectionAndComplete(EventLoop, EventLoopPromise<Connection>)
            }

            /// A `Waiter` represents a request that waits for a connection when none is
            /// currently available
            ///
            /// `Waiter`s are created when `maximumConcurrentConnections` is reached
            /// and we cannot create new connections anymore.
            fileprivate struct Waiter {
                /// The promise to complete once a connection is available
                let promise: EventLoopPromise<Connection>

                /// The event loop preference associated to this particular request
                /// that the provider should respect
                let preference: HTTPClient.EventLoopPreference
            }

            enum Activity: Hashable, CustomStringConvertible {
                case opened
                case closing
                case closed

                var description: String {
                    switch self {
                    case .opened:
                        return "opened"
                    case .closing:
                        return "closing"
                    case .closed:
                        return "closed"
                    }
                }
            }
        }
    }
}
