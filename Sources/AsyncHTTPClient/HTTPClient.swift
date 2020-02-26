//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the AsyncHTTPClient project authors
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
import NIOSSL
import NIOTLS

/// HTTPClient class provides API for request execution.
///
/// Example:
///
/// ```swift
///     let client = HTTPClient(eventLoopGroupProvider = .createNew)
///     client.get(url: "https://swift.org", deadline: .now() + .seconds(1)).whenComplete { result in
///         switch result {
///         case .failure(let error):
///             // process error
///         case .success(let response):
///             if let response.status == .ok {
///                 // handle response
///             } else {
///                 // handle remote error
///             }
///         }
///     }
/// ```
///
/// It is important to close the client instance, for example in a defer statement, after use to cleanly shutdown the underlying NIO `EventLoopGroup`:
///
/// ```swift
///     try client.syncShutdown()
/// ```
public class HTTPClient {
    public let eventLoopGroup: EventLoopGroup
    let eventLoopGroupProvider: EventLoopGroupProvider
    let configuration: Configuration
    let pool: ConnectionPool
    var state: State
    private var tasks = [UUID: TaskProtocol]()
    private let stateLock = Lock()

    /// Create an `HTTPClient` with specified `EventLoopGroup` provider and configuration.
    ///
    /// - parameters:
    ///     - eventLoopGroupProvider: Specify how `EventLoopGroup` will be created.
    ///     - configuration: Client configuration.
    public init(eventLoopGroupProvider: EventLoopGroupProvider, configuration: Configuration = Configuration()) {
        self.eventLoopGroupProvider = eventLoopGroupProvider
        switch self.eventLoopGroupProvider {
        case .shared(let group):
            self.eventLoopGroup = group
        case .createNew:
            self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        }
        self.configuration = configuration
        self.pool = ConnectionPool(configuration: configuration)
        self.state = .upAndRunning
    }

    deinit {
        assert(self.pool.connectionProviderCount == 0)
        assert(self.state == .shutDown, "Client not shut down before the deinit. Please call client.syncShutdown() when no longer needed.")
    }

    /// Shuts down the client and `EventLoopGroup` if it was created by the client.
    public func syncShutdown() throws {
        try self.syncShutdown(requiresCleanClose: false)
    }

    /// Shuts down the client and `EventLoopGroup` if it was created by the client.
    ///
    /// - parameters:
    ///     - requiresCleanClose: Determine if the client should throw when it is shutdown in a non-clean state
    ///
    /// - Note:
    /// The `requiresCleanClose` will let the client do additional checks about its internal consistency on shutdown and
    /// throw the appropriate error if needed. For instance, if its internal connection pool has any non-released connections,
    /// this indicate shutdown was called too early before tasks were completed or explicitly canceled.
    /// In general, setting this parameter to `true` should make it easier and faster to catch related programming errors.
    internal func syncShutdown(requiresCleanClose: Bool) throws {
        var closeError: Error?

        let tasks = try self.stateLock.withLock { () -> Dictionary<UUID, TaskProtocol>.Values in
            if self.state != .upAndRunning {
                throw HTTPClientError.alreadyShutdown
            }
            self.state = .shuttingDown
            return self.tasks.values
        }

        self.pool.prepareForClose()

        if !tasks.isEmpty, requiresCleanClose {
            closeError = HTTPClientError.uncleanShutdown
        }

        for task in tasks {
            task.cancel()
        }

        try? EventLoopFuture.andAllComplete((tasks.map { $0.completion }), on: self.eventLoopGroup.next()).wait()

        self.pool.syncClose()

        do {
            try self.stateLock.withLock {
                switch self.eventLoopGroupProvider {
                case .shared:
                    self.state = .shutDown
                    return
                case .createNew:
                    switch self.state {
                    case .shuttingDown:
                        self.state = .shutDown
                        try self.eventLoopGroup.syncShutdownGracefully()
                    case .shutDown, .upAndRunning:
                        assertionFailure("The only valid state at this point is \(State.shutDown)")
                    }
                }
            }
        } catch {
            if closeError == nil {
                closeError = error
            }
        }

        if let closeError = closeError {
            throw closeError
        }
    }

    /// Execute `GET` request using specified URL.
    ///
    /// - parameters:
    ///     - url: Remote URL.
    ///     - deadline: Point in time by which the request must complete.
    public func get(url: String, deadline: NIODeadline? = nil) -> EventLoopFuture<Response> {
        do {
            let request = try Request(url: url, method: .GET)
            return self.execute(request: request, deadline: deadline)
        } catch {
            return self.eventLoopGroup.next().makeFailedFuture(error)
        }
    }

    /// Execute `POST` request using specified URL.
    ///
    /// - parameters:
    ///     - url: Remote URL.
    ///     - body: Request body.
    ///     - deadline: Point in time by which the request must complete.
    public func post(url: String, body: Body? = nil, deadline: NIODeadline? = nil) -> EventLoopFuture<Response> {
        do {
            let request = try HTTPClient.Request(url: url, method: .POST, body: body)
            return self.execute(request: request, deadline: deadline)
        } catch {
            return self.eventLoopGroup.next().makeFailedFuture(error)
        }
    }

    /// Execute `PATCH` request using specified URL.
    ///
    /// - parameters:
    ///     - url: Remote URL.
    ///     - body: Request body.
    ///     - deadline: Point in time by which the request must complete.
    public func patch(url: String, body: Body? = nil, deadline: NIODeadline? = nil) -> EventLoopFuture<Response> {
        do {
            let request = try HTTPClient.Request(url: url, method: .PATCH, body: body)
            return self.execute(request: request, deadline: deadline)
        } catch {
            return self.eventLoopGroup.next().makeFailedFuture(error)
        }
    }

    /// Execute `PUT` request using specified URL.
    ///
    /// - parameters:
    ///     - url: Remote URL.
    ///     - body: Request body.
    ///     - deadline: Point in time by which the request must complete.
    public func put(url: String, body: Body? = nil, deadline: NIODeadline? = nil) -> EventLoopFuture<Response> {
        do {
            let request = try HTTPClient.Request(url: url, method: .PUT, body: body)
            return self.execute(request: request, deadline: deadline)
        } catch {
            return self.eventLoopGroup.next().makeFailedFuture(error)
        }
    }

    /// Execute `DELETE` request using specified URL.
    ///
    /// - parameters:
    ///     - url: Remote URL.
    ///     - deadline: The time when the request must have been completed by.
    public func delete(url: String, deadline: NIODeadline? = nil) -> EventLoopFuture<Response> {
        do {
            let request = try Request(url: url, method: .DELETE)
            return self.execute(request: request, deadline: deadline)
        } catch {
            return self.eventLoopGroup.next().makeFailedFuture(error)
        }
    }

    /// Execute arbitrary HTTP request using specified URL.
    ///
    /// - parameters:
    ///     - request: HTTP request to execute.
    ///     - deadline: Point in time by which the request must complete.
    public func execute(request: Request, deadline: NIODeadline? = nil) -> EventLoopFuture<Response> {
        let accumulator = ResponseAccumulator(request: request)
        return self.execute(request: request, delegate: accumulator, deadline: deadline).futureResult
    }

    /// Execute arbitrary HTTP request using specified URL.
    ///
    /// - parameters:
    ///     - request: HTTP request to execute.
    ///     - eventLoop: NIO Event Loop preference.
    ///     - deadline: Point in time by which the request must complete.
    public func execute(request: Request, eventLoop: EventLoopPreference, deadline: NIODeadline? = nil) -> EventLoopFuture<Response> {
        let accumulator = ResponseAccumulator(request: request)
        return self.execute(request: request, delegate: accumulator, eventLoop: eventLoop, deadline: deadline).futureResult
    }

    /// Execute arbitrary HTTP request and handle response processing using provided delegate.
    ///
    /// - parameters:
    ///     - request: HTTP request to execute.
    ///     - delegate: Delegate to process response parts.
    ///     - deadline: Point in time by which the request must complete.
    public func execute<Delegate: HTTPClientResponseDelegate>(request: Request,
                                                              delegate: Delegate,
                                                              deadline: NIODeadline? = nil) -> Task<Delegate.Response> {
        return self.execute(request: request, delegate: delegate, eventLoop: .indifferent, deadline: deadline)
    }

    /// Execute arbitrary HTTP request and handle response processing using provided delegate.
    ///
    /// - parameters:
    ///     - request: HTTP request to execute.
    ///     - delegate: Delegate to process response parts.
    ///     - eventLoop: NIO Event Loop preference.
    ///     - deadline: Point in time by which the request must complete.
    public func execute<Delegate: HTTPClientResponseDelegate>(request: Request,
                                                              delegate: Delegate,
                                                              eventLoop eventLoopPreference: EventLoopPreference,
                                                              deadline: NIODeadline? = nil) -> Task<Delegate.Response> {
        let taskEL: EventLoop
        switch eventLoopPreference.preference {
        case .indifferent:
            taskEL = self.pool.associatedEventLoop(for: ConnectionPool.Key(request)) ?? self.eventLoopGroup.next()
        case .delegate(on: let eventLoop):
            precondition(self.eventLoopGroup.makeIterator().contains { $0 === eventLoop }, "Provided EventLoop must be part of clients EventLoopGroup.")
            taskEL = eventLoop
        case .delegateAndChannel(on: let eventLoop):
            precondition(self.eventLoopGroup.makeIterator().contains { $0 === eventLoop }, "Provided EventLoop must be part of clients EventLoopGroup.")
            taskEL = eventLoop
        case .testOnly_exact(_, delegateOn: let delegateEL):
            taskEL = delegateEL
        }

        let failedTask: Task<Delegate.Response>? = self.stateLock.withLock {
            switch state {
            case .upAndRunning:
                return nil
            case .shuttingDown, .shutDown:
                return Task<Delegate.Response>.failedTask(eventLoop: taskEL, error: HTTPClientError.alreadyShutdown)
            }
        }

        if let failedTask = failedTask {
            return failedTask
        }

        let redirectHandler: RedirectHandler<Delegate.Response>?
        switch self.configuration.redirectConfiguration.configuration {
        case .follow(let max, let allowCycles):
            var request = request
            if request.redirectState == nil {
                request.redirectState = .init(count: max, visited: allowCycles ? nil : Set())
            }
            redirectHandler = RedirectHandler<Delegate.Response>(request: request) { newRequest in
                self.execute(request: newRequest,
                             delegate: delegate,
                             eventLoop: eventLoopPreference,
                             deadline: deadline)
            }
        case .disallow:
            redirectHandler = nil
        }

        let task = Task<Delegate.Response>(eventLoop: taskEL, poolingTimeout: self.configuration.maximumAllowedIdleTimeInConnectionPool)
        self.stateLock.withLock {
            self.tasks[task.id] = task
        }
        let promise = task.promise

        promise.futureResult.whenComplete { _ in
            self.stateLock.withLock {
                self.tasks[task.id] = nil
            }
        }

        let connection = self.pool.getConnection(for: request, preference: eventLoopPreference, on: taskEL, deadline: deadline)

        connection.flatMap { connection -> EventLoopFuture<Void> in
            let channel = connection.channel

            return connection.removeHandler(IdleStateHandler.self).flatMap {
                connection.removeHandler(IdlePoolConnectionHandler.self)
            }.flatMap {
                switch self.configuration.decompression {
                case .disabled:
                    return channel.eventLoop.makeSucceededFuture(())
                case .enabled(let limit):
                    let decompressHandler = NIOHTTPResponseDecompressor(limit: limit)
                    return channel.pipeline.addHandler(decompressHandler)
                }
            }.flatMap {
                if let timeout = self.resolve(timeout: self.configuration.timeout.read, deadline: deadline) {
                    return channel.pipeline.addHandler(IdleStateHandler(readTimeout: timeout))
                } else {
                    return channel.eventLoop.makeSucceededFuture(())
                }
            }.flatMap {
                let taskHandler = TaskHandler(task: task,
                                              kind: request.kind,
                                              delegate: delegate,
                                              redirectHandler: redirectHandler,
                                              ignoreUncleanSSLShutdown: self.configuration.ignoreUncleanSSLShutdown)
                return channel.pipeline.addHandler(taskHandler)
            }.flatMap {
                task.setConnection(connection)

                let isCancelled = task.lock.withLock {
                    task.cancelled
                }

                if !isCancelled {
                    return channel.writeAndFlush(request).flatMapError { _ in
                        // At this point the `TaskHandler` will already be present
                        // to handle the failure and pass it to the `promise`
                        channel.eventLoop.makeSucceededFuture(())
                    }
                } else {
                    return channel.eventLoop.makeSucceededFuture(())
                }
            }.flatMapError { error in
                connection.release()
                return channel.eventLoop.makeFailedFuture(error)
            }
        }.cascadeFailure(to: promise)

        return task
    }

    private func resolve(timeout: TimeAmount?, deadline: NIODeadline?) -> TimeAmount? {
        switch (timeout, deadline) {
        case (.some(let timeout), .some(let deadline)):
            return min(timeout, deadline - .now())
        case (.some(let timeout), .none):
            return timeout
        case (.none, .some(let deadline)):
            return deadline - .now()
        case (.none, .none):
            return nil
        }
    }

    static func resolveAddress(host: String, port: Int, proxy: Configuration.Proxy?) -> (host: String, port: Int) {
        switch proxy {
        case .none:
            return (host, port)
        case .some(let proxy):
            return (proxy.host, proxy.port)
        }
    }

    /// `HTTPClient` configuration.
    public struct Configuration {
        /// TLS configuration, defaults to `TLSConfiguration.forClient()`.
        public var tlsConfiguration: TLSConfiguration?
        /// Enables following 3xx redirects automatically, defaults to `false`.
        ///
        /// Following redirects are supported:
        ///  - `301: Moved Permanently`
        ///  - `302: Found`
        ///  - `303: See Other`
        ///  - `304: Not Modified`
        ///  - `305: Use Proxy`
        ///  - `307: Temporary Redirect`
        ///  - `308: Permanent Redirect`
        public var redirectConfiguration: RedirectConfiguration
        /// Default client timeout, defaults to no timeouts.
        public var timeout: Timeout
        /// Timeout of pooled connections
        public var maximumAllowedIdleTimeInConnectionPool: TimeAmount?
        /// Upstream proxy, defaults to no proxy.
        public var proxy: Proxy?
        /// Enables automatic body decompression. Supported algorithms are gzip and deflate.
        public var decompression: Decompression
        /// Ignore TLS unclean shutdown error, defaults to `false`.
        public var ignoreUncleanSSLShutdown: Bool

        public init(tlsConfiguration: TLSConfiguration? = nil,
                    redirectConfiguration: RedirectConfiguration? = nil,
                    timeout: Timeout = Timeout(),
                    maximumAllowedIdleTimeInConnectionPool: TimeAmount,
                    proxy: Proxy? = nil,
                    ignoreUncleanSSLShutdown: Bool = false,
                    decompression: Decompression = .disabled) {
            self.tlsConfiguration = tlsConfiguration
            self.redirectConfiguration = redirectConfiguration ?? RedirectConfiguration()
            self.timeout = timeout
            self.maximumAllowedIdleTimeInConnectionPool = maximumAllowedIdleTimeInConnectionPool
            self.proxy = proxy
            self.ignoreUncleanSSLShutdown = ignoreUncleanSSLShutdown
            self.decompression = decompression
        }

        public init(tlsConfiguration: TLSConfiguration? = nil,
                    redirectConfiguration: RedirectConfiguration? = nil,
                    timeout: Timeout = Timeout(),
                    proxy: Proxy? = nil,
                    ignoreUncleanSSLShutdown: Bool = false,
                    decompression: Decompression = .disabled) {
            self.init(
                tlsConfiguration: tlsConfiguration,
                redirectConfiguration: redirectConfiguration,
                timeout: timeout,
                maximumAllowedIdleTimeInConnectionPool: .seconds(60),
                proxy: proxy,
                ignoreUncleanSSLShutdown: ignoreUncleanSSLShutdown,
                decompression: decompression
            )
        }

        public init(certificateVerification: CertificateVerification,
                    redirectConfiguration: RedirectConfiguration? = nil,
                    timeout: Timeout = Timeout(),
                    maximumAllowedIdleTimeInConnectionPool: TimeAmount = .seconds(60),
                    proxy: Proxy? = nil,
                    ignoreUncleanSSLShutdown: Bool = false,
                    decompression: Decompression = .disabled) {
            self.tlsConfiguration = TLSConfiguration.forClient(certificateVerification: certificateVerification)
            self.redirectConfiguration = redirectConfiguration ?? RedirectConfiguration()
            self.timeout = timeout
            self.maximumAllowedIdleTimeInConnectionPool = maximumAllowedIdleTimeInConnectionPool
            self.proxy = proxy
            self.ignoreUncleanSSLShutdown = ignoreUncleanSSLShutdown
            self.decompression = decompression
        }

        public init(certificateVerification: CertificateVerification,
                    redirectConfiguration: RedirectConfiguration? = nil,
                    timeout: Timeout = Timeout(),
                    proxy: Proxy? = nil,
                    ignoreUncleanSSLShutdown: Bool = false,
                    decompression: Decompression = .disabled) {
            self.init(
                certificateVerification: certificateVerification,
                redirectConfiguration: redirectConfiguration,
                timeout: timeout,
                maximumAllowedIdleTimeInConnectionPool: .seconds(60),
                proxy: proxy,
                ignoreUncleanSSLShutdown: ignoreUncleanSSLShutdown,
                decompression: decompression
            )
        }
    }

    /// Specifies how `EventLoopGroup` will be created and establishes lifecycle ownership.
    public enum EventLoopGroupProvider {
        /// `EventLoopGroup` will be provided by the user. Owner of this group is responsible for its lifecycle.
        case shared(EventLoopGroup)
        /// `EventLoopGroup` will be created by the client. When `syncShutdown` is called, created `EventLoopGroup` will be shut down as well.
        case createNew
    }

    /// Specifies how the library will treat event loop passed by the user.
    public struct EventLoopPreference {
        enum Preference {
            /// Event Loop will be selected by the library.
            case indifferent
            /// The delegate will be run on the specified EventLoop (and the Channel if possible).
            case delegate(on: EventLoop)
            /// The delegate and the `Channel` will be run on the specified EventLoop.
            case delegateAndChannel(on: EventLoop)

            case testOnly_exact(channelOn: EventLoop, delegateOn: EventLoop)
        }

        var preference: Preference

        init(_ preference: Preference) {
            self.preference = preference
        }

        /// Event Loop will be selected by the library.
        public static let indifferent = EventLoopPreference(.indifferent)

        /// The delegate will be run on the specified EventLoop (and the Channel if possible).
        ///
        /// This will call the configured delegate on `eventLoop` and will try to use a `Channel` on the same
        /// `EventLoop` but will not establish a new network connection just to satisfy the `EventLoop` preference if
        /// another existing connection on a different `EventLoop` is readily available from a connection pool.
        public static func delegate(on eventLoop: EventLoop) -> EventLoopPreference {
            return EventLoopPreference(.delegate(on: eventLoop))
        }

        /// The delegate and the `Channel` will be run on the specified EventLoop.
        ///
        /// Use this for use-cases where you prefer a new connection to be established over re-using an existing
        /// connection that might be on a different `EventLoop`.
        public static func delegateAndChannel(on eventLoop: EventLoop) -> EventLoopPreference {
            return EventLoopPreference(.delegateAndChannel(on: eventLoop))
        }

        var bestEventLoop: EventLoop? {
            switch self.preference {
            case .delegate(on: let el):
                return el
            case .delegateAndChannel(on: let el):
                return el
            case .testOnly_exact(channelOn: let el, delegateOn: _):
                return el
            case .indifferent:
                return nil
            }
        }
    }

    /// Specifies decompression settings.
    public enum Decompression {
        /// Decompression is disabled.
        case disabled
        /// Decompression is enabled.
        case enabled(limit: NIOHTTPDecompression.DecompressionLimit)
    }

    enum State {
        case upAndRunning
        case shuttingDown
        case shutDown
    }
}

extension HTTPClient.Configuration {
    /// Timeout configuration
    public struct Timeout {
        /// Specifies connect timeout.
        public var connect: TimeAmount?
        /// Specifies read timeout.
        public var read: TimeAmount?

        /// Create timeout.
        ///
        /// - parameters:
        ///     - connect: `connect` timeout.
        ///     - read: `read` timeout.
        public init(connect: TimeAmount? = nil, read: TimeAmount? = nil) {
            self.connect = connect
            self.read = read
        }
    }

    /// Specifies redirect processing settings.
    public struct RedirectConfiguration {
        enum Configuration {
            /// Redirects are not followed.
            case disallow
            /// Redirects are followed with a specified limit.
            case follow(max: Int, allowCycles: Bool)
        }

        var configuration: Configuration

        init() {
            self.configuration = .follow(max: 5, allowCycles: false)
        }

        init(configuration: Configuration) {
            self.configuration = configuration
        }

        /// Redirects are not followed.
        public static let disallow = RedirectConfiguration(configuration: .disallow)

        /// Redirects are followed with a specified limit.
        ///
        /// - parameters:
        ///     - max: The maximum number of allowed redirects.
        ///     - allowCycles: Whether cycles are allowed.
        ///
        /// - warning: Cycle detection will keep all visited URLs in memory which means a malicious server could use this as a denial-of-service vector.
        public static func follow(max: Int, allowCycles: Bool) -> RedirectConfiguration { return .init(configuration: .follow(max: max, allowCycles: allowCycles)) }
    }
}

extension ChannelPipeline {
    func addProxyHandler(host: String, port: Int, authorization: HTTPClient.Authorization?) -> EventLoopFuture<Void> {
        let encoder = HTTPRequestEncoder()
        let decoder = ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .forwardBytes))
        let handler = HTTPClientProxyHandler(host: host, port: port, authorization: authorization) { channel in
            let encoderRemovePromise = self.eventLoop.next().makePromise(of: Void.self)
            channel.pipeline.removeHandler(encoder, promise: encoderRemovePromise)
            return encoderRemovePromise.futureResult.flatMap {
                channel.pipeline.removeHandler(decoder)
            }
        }
        return addHandlers([encoder, decoder, handler])
    }

    func addSSLHandlerIfNeeded(for key: ConnectionPool.Key, tlsConfiguration: TLSConfiguration?, handshakePromise: EventLoopPromise<Void>) -> EventLoopFuture<Void> {
        guard key.scheme == .https else {
            handshakePromise.succeed(())
            return self.eventLoop.makeSucceededFuture(())
        }

        do {
            let tlsConfiguration = tlsConfiguration ?? TLSConfiguration.forClient()
            let context = try NIOSSLContext(configuration: tlsConfiguration)
            let handlers: [ChannelHandler] = [
                try NIOSSLClientHandler(context: context, serverHostname: key.host.isIPAddress ? nil : key.host),
                TLSEventsHandler(completionPromise: handshakePromise),
            ]

            return self.addHandlers(handlers)
        } catch {
            return self.eventLoop.makeFailedFuture(error)
        }
    }
}

class TLSEventsHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = NIOAny

    var completionPromise: EventLoopPromise<Void>?

    init(completionPromise: EventLoopPromise<Void>) {
        self.completionPromise = completionPromise
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let tlsEvent = event as? TLSUserEvent {
            switch tlsEvent {
            case .handshakeCompleted:
                self.completionPromise?.succeed(())
                self.completionPromise = nil
                context.pipeline.removeHandler(self, promise: nil)
            case .shutdownCompleted:
                break
            }
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if let sslError = error as? NIOSSLError {
            switch sslError {
            case .handshakeFailed:
                self.completionPromise?.fail(error)
                self.completionPromise = nil
                context.pipeline.removeHandler(self, promise: nil)
            default:
                break
            }
        }
        context.fireErrorCaught(error)
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        struct NoResult: Error {}
        self.completionPromise?.fail(NoResult())
    }
}

/// Possible client errors.
public struct HTTPClientError: Error, Equatable, CustomStringConvertible {
    private enum Code: Equatable {
        case invalidURL
        case emptyHost
        case alreadyShutdown
        case emptyScheme
        case unsupportedScheme(String)
        case readTimeout
        case remoteConnectionClosed
        case cancelled
        case identityCodingIncorrectlyPresent
        case chunkedSpecifiedMultipleTimes
        case invalidProxyResponse
        case contentLengthMissing
        case proxyAuthenticationRequired
        case redirectLimitReached
        case redirectCycleDetected
        case uncleanShutdown
    }

    private var code: Code

    private init(code: Code) {
        self.code = code
    }

    public var description: String {
        return "HTTPClientError.\(String(describing: self.code))"
    }

    /// URL provided is invalid.
    public static let invalidURL = HTTPClientError(code: .invalidURL)
    /// URL does not contain host.
    public static let emptyHost = HTTPClientError(code: .emptyHost)
    /// Client is shutdown and cannot be used for new requests.
    public static let alreadyShutdown = HTTPClientError(code: .alreadyShutdown)
    /// URL does not contain scheme.
    public static let emptyScheme = HTTPClientError(code: .emptyScheme)
    /// Provided URL scheme is not supported, supported schemes are: `http` and `https`
    public static func unsupportedScheme(_ scheme: String) -> HTTPClientError { return HTTPClientError(code: .unsupportedScheme(scheme)) }
    /// Request timed out.
    public static let readTimeout = HTTPClientError(code: .readTimeout)
    /// Remote connection was closed unexpectedly.
    public static let remoteConnectionClosed = HTTPClientError(code: .remoteConnectionClosed)
    /// Request was cancelled.
    public static let cancelled = HTTPClientError(code: .cancelled)
    /// Request contains invalid identity encoding.
    public static let identityCodingIncorrectlyPresent = HTTPClientError(code: .identityCodingIncorrectlyPresent)
    /// Request contains multiple chunks definitions.
    public static let chunkedSpecifiedMultipleTimes = HTTPClientError(code: .chunkedSpecifiedMultipleTimes)
    /// Proxy response was invalid.
    public static let invalidProxyResponse = HTTPClientError(code: .invalidProxyResponse)
    /// Request does not contain `Content-Length` header.
    public static let contentLengthMissing = HTTPClientError(code: .contentLengthMissing)
    /// Proxy Authentication Required.
    public static let proxyAuthenticationRequired = HTTPClientError(code: .proxyAuthenticationRequired)
    /// Redirect Limit reached.
    public static let redirectLimitReached = HTTPClientError(code: .redirectLimitReached)
    /// Redirect Cycle detected.
    public static let redirectCycleDetected = HTTPClientError(code: .redirectCycleDetected)
    /// Unclean shutdown
    public static let uncleanShutdown = HTTPClientError(code: .uncleanShutdown)
}
