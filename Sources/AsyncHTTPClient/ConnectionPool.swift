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
    func getConnection(for request: HTTPClient.Request, preference: HTTPClient.EventLoopPreference, on eventLoop: EventLoop, deadline: NIODeadline?, setupComplete: EventLoopFuture<Void>) -> EventLoopFuture<Connection> {
        let key = Key(request)

        let provider: HTTP1ConnectionProvider = self.lock.withLock {
            if let existing = self.providers[key], existing.enqueue() {
                return existing
            } else {
                // Connection provider will be created with `pending = 1`
                let provider = HTTP1ConnectionProvider(key: key, eventLoop: eventLoop, configuration: self.configuration, pool: self)
                self.providers[key] = provider
                return provider
            }
        }

        return provider.getConnection(preference: preference, setupComplete: setupComplete)
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
    func release(closing: Bool) {
        assert(self.channel.eventLoop.inEventLoop)
        self.provider.release(connection: self, closing: closing)
    }

    /// Called when channel exceeds idle time in pool.
    func timeout() {
        assert(self.channel.eventLoop.inEventLoop)
        self.provider.timeout(connection: self)
    }

    /// Called when channel goes inactive while in the pool.
    func remoteClosed() {
        assert(self.channel.eventLoop.inEventLoop)
        self.provider.remoteClosed(connection: self)
    }

    func cancel() -> EventLoopFuture<Void> {
        return self.channel.triggerUserOutboundEvent(TaskCancelEvent())
    }

    /// Called from `HTTP1ConnectionProvider.close` when client is shutting down.
    func close() -> EventLoopFuture<Void> {
        return self.channel.close()
    }

    /// Sets idle timeout handler and channel inactivity listener.
    func setIdleTimeout(timeout: TimeAmount?) {
        _ = self.channel.pipeline.addHandler(IdleStateHandler(writeTimeout: timeout), position: .first).flatMap { _ in
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

    var closePromise: EventLoopPromise<Void>

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
        self.closePromise = eventLoop.makePromise()
        self.state = .init(eventLoop: eventLoop)
    }

    deinit {
        self.state.assertInvariants()
    }

    private func execute(_ action: Action) {
        switch action {
        case .lease(let connection, let waiter):
            // if connection is became inactive, we create a new one.
            connection.cancelIdleTimeout().whenComplete { _ in
                if connection.isActiveEstimation {
                    waiter.promise.succeed(connection)
                } else {
                    self.makeChannel(preference: waiter.preference).whenComplete { result in
                        self.connect(result, waiter: waiter, replacing: connection)
                    }
                }
            }
        case .create(let waiter):
            self.makeChannel(preference: waiter.preference).whenComplete { result in
                self.connect(result, waiter: waiter)
            }
        case .replace(let connection, let waiter):
            connection.cancelIdleTimeout().flatMap {
                connection.close()
            }.whenComplete { _ in
                self.makeChannel(preference: waiter.preference).whenComplete { result in
                    self.connect(result, waiter: waiter, replacing: connection)
                }
            }
        case .park(let connection):
            connection.setIdleTimeout(timeout: self.configuration.maximumAllowedIdleTimeInConnectionPool)
        case .closeProvider:
            self.closeAndDelete()
        case .none:
            break
        case .parkAnd(let connection, let action):
            connection.setIdleTimeout(timeout: self.configuration.maximumAllowedIdleTimeInConnectionPool)
            self.execute(action)
        case .closeAnd(let connection, let action):
            connection.channel.close(promise: nil)
            self.execute(action)
        case .cancel(let connection, let close):
            connection.cancel().whenComplete { _ in
                if close {
                    self.closeAndDelete()
                }
            }
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

    func getConnection(preference: HTTPClient.EventLoopPreference, setupComplete: EventLoopFuture<Void>) -> EventLoopFuture<Connection> {
        let waiter = Waiter(promise: self.eventLoop.makePromise(), setupComplete: setupComplete, preference: preference)

        let action: Action = self.lock.withLock {
            self.state.acquire(waiter: waiter)
        }

        self.execute(action)

        return waiter.promise.futureResult
    }

    func connect(_ result: Result<Channel, Error>, waiter: Waiter, replacing closedConnection: Connection? = nil) {
        let action: Action
        switch result {
        case .success(let channel):
            let connection = Connection(channel: channel, provider: self)
            action = self.lock.withLock {
                if let closedConnection = closedConnection {
                    self.state.drop(connection: closedConnection)
                }
                return self.state.offer(connection: connection)
            }
            waiter.promise.succeed(connection)
        case .failure(let error):
            action = self.lock.withLock {
                self.state.connectFailed()
            }
            waiter.promise.fail(error)
        }
        waiter.setupComplete.whenComplete { _ in
            self.execute(action)
        }
    }

    func release(connection: Connection, closing: Bool) {
        let action: Action = self.lock.withLock {
            self.state.release(connection: connection, closing: closing)
        }

        switch action {
        case .none:
            break
        case .park, .closeProvider:
            // Since both `.park` and `.deleteProvider` are terminal in terms of execution,
            // we can execute them immediately
            self.execute(action)
        case .cancel, .closeAnd, .create, .fail, .lease, .parkAnd, .replace:
            // This is needed to start a new stack, otherwise, since this is called on a previous
            // future completion handler chain, it will be growing indefinitely until the connection is closed.
            // We might revisit this when https://github.com/apple/swift-nio/issues/970 is resolved.
            connection.channel.eventLoop.execute {
                self.execute(action)
            }
        }
    }

    func remoteClosed(connection: Connection) {
        let action: Action = self.lock.withLock {
            self.state.remoteClosed(connection: connection)
        }

        self.execute(action)
    }

    func timeout(connection: Connection) {
        let action: Action = self.lock.withLock {
            self.state.timeout(connection: connection)
        }

        self.execute(action)
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
