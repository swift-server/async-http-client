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
import Logging
import NIO
import NIOConcurrencyHelpers
import NIOHTTP1
import NIOHTTPCompression
import NIOSSL
import NIOTLS
import NIOTransportServices

extension Logger {
    private func requestInfo(_ request: HTTPClient.Request) -> Logger.Metadata.Value {
        return "\(request.method) \(request.url)"
    }

    func attachingRequestInformation(_ request: HTTPClient.Request, requestID: Int) -> Logger {
        var modified = self
        modified[metadataKey: "ahc-prev-request"] = nil
        modified[metadataKey: "ahc-request-id"] = "\(requestID)"
        return modified
    }
}

let globalRequestID = NIOAtomic<Int>.makeAtomic(value: 0)

/// HTTPClient class provides API for request execution.
///
/// Example:
///
/// ```swift
///     let client = HTTPClient(eventLoopGroupProvider: .createNew)
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
    private let stateLock = Lock()

    internal static let loggingDisabled = Logger(label: "AHC-do-not-log", factory: { _ in NoOpLogHandler() })

    /// Create an `HTTPClient` with specified `EventLoopGroup` provider and configuration.
    ///
    /// - parameters:
    ///     - eventLoopGroupProvider: Specify how `EventLoopGroup` will be created.
    ///     - configuration: Client configuration.
    public convenience init(eventLoopGroupProvider: EventLoopGroupProvider,
                            configuration: Configuration = Configuration()) {
        self.init(eventLoopGroupProvider: eventLoopGroupProvider,
                  configuration: configuration,
                  backgroundActivityLogger: HTTPClient.loggingDisabled)
    }

    /// Create an `HTTPClient` with specified `EventLoopGroup` provider and configuration.
    ///
    /// - parameters:
    ///     - eventLoopGroupProvider: Specify how `EventLoopGroup` will be created.
    ///     - configuration: Client configuration.
    public required init(eventLoopGroupProvider: EventLoopGroupProvider,
                         configuration: Configuration = Configuration(),
                         backgroundActivityLogger: Logger) {
        self.eventLoopGroupProvider = eventLoopGroupProvider
        switch self.eventLoopGroupProvider {
        case .shared(let group):
            self.eventLoopGroup = group
        case .createNew:
            #if canImport(Network)
                if #available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *) {
                    self.eventLoopGroup = NIOTSEventLoopGroup()
                } else {
                    self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
                }
            #else
                self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            #endif
        }
        self.configuration = configuration
        self.pool = ConnectionPool(configuration: configuration,
                                   backgroundActivityLogger: backgroundActivityLogger)
        self.state = .upAndRunning
    }

    deinit {
        assert(self.pool.count == 0)
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
        if let eventLoop = MultiThreadedEventLoopGroup.currentEventLoop {
            preconditionFailure("""
            BUG DETECTED: syncShutdown() must not be called when on an EventLoop.
            Calling syncShutdown() on any EventLoop can lead to deadlocks.
            Current eventLoop: \(eventLoop)
            """)
        }
        let errorStorageLock = Lock()
        var errorStorage: Error?
        let continuation = DispatchWorkItem {}
        self.shutdown(requiresCleanClose: requiresCleanClose, queue: DispatchQueue(label: "async-http-client.shutdown")) { error in
            if let error = error {
                errorStorageLock.withLock {
                    errorStorage = error
                }
            }
            continuation.perform()
        }
        continuation.wait()
        try errorStorageLock.withLock {
            if let error = errorStorage {
                throw error
            }
        }
    }

    /// Shuts down the client and event loop gracefully. This function is clearly an outlier in that it uses a completion
    /// callback instead of an EventLoopFuture. The reason for that is that NIO's EventLoopFutures will call back on an event loop.
    /// The virtue of this function is to shut the event loop down. To work around that we call back on a DispatchQueue
    /// instead.
    public func shutdown(queue: DispatchQueue = .global(), _ callback: @escaping (Error?) -> Void) {
        self.shutdown(requiresCleanClose: false, queue: queue, callback)
    }

    private func shutdownEventLoop(queue: DispatchQueue, _ callback: @escaping (Error?) -> Void) {
        self.stateLock.withLock {
            switch self.eventLoopGroupProvider {
            case .shared:
                self.state = .shutDown
                callback(nil)
            case .createNew:
                switch self.state {
                case .shuttingDown:
                    self.state = .shutDown
                    self.eventLoopGroup.shutdownGracefully(queue: queue, callback)
                case .shutDown, .upAndRunning:
                    assertionFailure("The only valid state at this point is \(State.shutDown)")
                }
            }
        }
    }

    private func shutdown(requiresCleanClose: Bool, queue: DispatchQueue, _ callback: @escaping (Error?) -> Void) {
        do {
            try self.stateLock.withLock {
                if self.state != .upAndRunning {
                    throw HTTPClientError.alreadyShutdown
                }
                self.state = .shuttingDown
            }
        } catch {
            callback(error)
            return
        }

        self.pool.close(on: self.eventLoopGroup.next()).whenComplete { result in
            var closeError: Error?
            switch result {
            case .failure(let error):
                closeError = error
            case .success(let cleanShutdown):
                if !cleanShutdown, requiresCleanClose {
                    closeError = HTTPClientError.uncleanShutdown
                }

                self.shutdownEventLoop(queue: queue) { eventLoopError in
                    // we prioritise .uncleanShutdown here
                    if let error = closeError {
                        callback(error)
                    } else {
                        callback(eventLoopError)
                    }
                }
            }
        }
    }

    /// Execute `GET` request using specified URL.
    ///
    /// - parameters:
    ///     - url: Remote URL.
    ///     - deadline: Point in time by which the request must complete.
    public func get(url: String, deadline: NIODeadline? = nil) -> EventLoopFuture<Response> {
        return self.get(url: url, deadline: deadline, logger: HTTPClient.loggingDisabled)
    }

    /// Execute `GET` request using specified URL.
    ///
    /// - parameters:
    ///     - url: Remote URL.
    ///     - deadline: Point in time by which the request must complete.
    ///     - logger: The logger to use for this request.
    public func get(url: String, deadline: NIODeadline? = nil, logger: Logger) -> EventLoopFuture<Response> {
        return self.execute(.GET, url: url, deadline: deadline, logger: logger)
    }

    /// Execute `POST` request using specified URL.
    ///
    /// - parameters:
    ///     - url: Remote URL.
    ///     - body: Request body.
    ///     - deadline: Point in time by which the request must complete.
    public func post(url: String, body: Body? = nil, deadline: NIODeadline? = nil) -> EventLoopFuture<Response> {
        return self.post(url: url, body: body, deadline: deadline, logger: HTTPClient.loggingDisabled)
    }

    /// Execute `POST` request using specified URL.
    ///
    /// - parameters:
    ///     - url: Remote URL.
    ///     - body: Request body.
    ///     - deadline: Point in time by which the request must complete.
    ///     - logger: The logger to use for this request.
    public func post(url: String, body: Body? = nil, deadline: NIODeadline? = nil, logger: Logger) -> EventLoopFuture<Response> {
        return self.execute(.POST, url: url, body: body, deadline: deadline, logger: logger)
    }

    /// Execute `PATCH` request using specified URL.
    ///
    /// - parameters:
    ///     - url: Remote URL.
    ///     - body: Request body.
    ///     - deadline: Point in time by which the request must complete.
    public func patch(url: String, body: Body? = nil, deadline: NIODeadline? = nil) -> EventLoopFuture<Response> {
        return self.patch(url: url, body: body, deadline: deadline, logger: HTTPClient.loggingDisabled)
    }

    /// Execute `PATCH` request using specified URL.
    ///
    /// - parameters:
    ///     - url: Remote URL.
    ///     - body: Request body.
    ///     - deadline: Point in time by which the request must complete.
    ///     - logger: The logger to use for this request.
    public func patch(url: String, body: Body? = nil, deadline: NIODeadline? = nil, logger: Logger) -> EventLoopFuture<Response> {
        return self.execute(.PATCH, url: url, body: body, deadline: deadline, logger: logger)
    }

    /// Execute `PUT` request using specified URL.
    ///
    /// - parameters:
    ///     - url: Remote URL.
    ///     - body: Request body.
    ///     - deadline: Point in time by which the request must complete.
    public func put(url: String, body: Body? = nil, deadline: NIODeadline? = nil) -> EventLoopFuture<Response> {
        return self.put(url: url, body: body, deadline: deadline, logger: HTTPClient.loggingDisabled)
    }

    /// Execute `PUT` request using specified URL.
    ///
    /// - parameters:
    ///     - url: Remote URL.
    ///     - body: Request body.
    ///     - deadline: Point in time by which the request must complete.
    ///     - logger: The logger to use for this request.
    public func put(url: String, body: Body? = nil, deadline: NIODeadline? = nil, logger: Logger) -> EventLoopFuture<Response> {
        return self.execute(.PUT, url: url, body: body, deadline: deadline, logger: logger)
    }

    /// Execute `DELETE` request using specified URL.
    ///
    /// - parameters:
    ///     - url: Remote URL.
    ///     - deadline: The time when the request must have been completed by.
    public func delete(url: String, deadline: NIODeadline? = nil) -> EventLoopFuture<Response> {
        return self.delete(url: url, deadline: deadline, logger: HTTPClient.loggingDisabled)
    }

    /// Execute `DELETE` request using specified URL.
    ///
    /// - parameters:
    ///     - url: Remote URL.
    ///     - deadline: The time when the request must have been completed by.
    ///     - logger: The logger to use for this request.
    public func delete(url: String, deadline: NIODeadline? = nil, logger: Logger) -> EventLoopFuture<Response> {
        return self.execute(.DELETE, url: url, deadline: deadline, logger: logger)
    }

    /// Execute arbitrary HTTP request using specified URL.
    ///
    /// - parameters:
    ///     - method: Request method.
    ///     - url: Request url.
    ///     - body: Request body.
    ///     - deadline: Point in time by which the request must complete.
    ///     - logger: The logger to use for this request.
    public func execute(_ method: HTTPMethod = .GET, url: String, body: Body? = nil, deadline: NIODeadline? = nil, logger: Logger? = nil) -> EventLoopFuture<Response> {
        do {
            let request = try Request(url: url, method: method, body: body)
            return self.execute(request: request, deadline: deadline, logger: logger ?? HTTPClient.loggingDisabled)
        } catch {
            return self.eventLoopGroup.next().makeFailedFuture(error)
        }
    }

    /// Execute arbitrary HTTP+UNIX request to a unix domain socket path, using the specified URL as the request to send to the server.
    ///
    /// - parameters:
    ///     - method: Request method.
    ///     - socketPath: The path to the unix domain socket to connect to.
    ///     - urlPath: The URL path and query that will be sent to the server.
    ///     - body: Request body.
    ///     - deadline: Point in time by which the request must complete.
    ///     - logger: The logger to use for this request.
    public func execute(_ method: HTTPMethod = .GET, socketPath: String, urlPath: String, body: Body? = nil, deadline: NIODeadline? = nil, logger: Logger? = nil) -> EventLoopFuture<Response> {
        do {
            guard let url = URL(httpURLWithSocketPath: socketPath, uri: urlPath) else {
                throw HTTPClientError.invalidURL
            }
            let request = try Request(url: url, method: method, body: body)
            return self.execute(request: request, deadline: deadline, logger: logger ?? HTTPClient.loggingDisabled)
        } catch {
            return self.eventLoopGroup.next().makeFailedFuture(error)
        }
    }

    /// Execute arbitrary HTTPS+UNIX request to a unix domain socket path over TLS, using the specified URL as the request to send to the server.
    ///
    /// - parameters:
    ///     - method: Request method.
    ///     - secureSocketPath: The path to the unix domain socket to connect to.
    ///     - urlPath: The URL path and query that will be sent to the server.
    ///     - body: Request body.
    ///     - deadline: Point in time by which the request must complete.
    ///     - logger: The logger to use for this request.
    public func execute(_ method: HTTPMethod = .GET, secureSocketPath: String, urlPath: String, body: Body? = nil, deadline: NIODeadline? = nil, logger: Logger? = nil) -> EventLoopFuture<Response> {
        do {
            guard let url = URL(httpsURLWithSocketPath: secureSocketPath, uri: urlPath) else {
                throw HTTPClientError.invalidURL
            }
            let request = try Request(url: url, method: method, body: body)
            return self.execute(request: request, deadline: deadline, logger: logger ?? HTTPClient.loggingDisabled)
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
        return self.execute(request: request, deadline: deadline, logger: HTTPClient.loggingDisabled)
    }

    /// Execute arbitrary HTTP request using specified URL.
    ///
    /// - parameters:
    ///     - request: HTTP request to execute.
    ///     - deadline: Point in time by which the request must complete.
    ///     - logger: The logger to use for this request.
    public func execute(request: Request, deadline: NIODeadline? = nil, logger: Logger) -> EventLoopFuture<Response> {
        let accumulator = ResponseAccumulator(request: request)
        return self.execute(request: request, delegate: accumulator, deadline: deadline, logger: logger).futureResult
    }

    /// Execute arbitrary HTTP request using specified URL.
    ///
    /// - parameters:
    ///     - request: HTTP request to execute.
    ///     - eventLoop: NIO Event Loop preference.
    ///     - deadline: Point in time by which the request must complete.
    public func execute(request: Request, eventLoop: EventLoopPreference, deadline: NIODeadline? = nil) -> EventLoopFuture<Response> {
        return self.execute(request: request,
                            eventLoop: eventLoop,
                            deadline: deadline,
                            logger: HTTPClient.loggingDisabled)
    }

    /// Execute arbitrary HTTP request and handle response processing using provided delegate.
    ///
    /// - parameters:
    ///     - request: HTTP request to execute.
    ///     - eventLoop: NIO Event Loop preference.
    ///     - deadline: Point in time by which the request must complete.
    ///     - logger: The logger to use for this request.
    public func execute(request: Request,
                        eventLoop eventLoopPreference: EventLoopPreference,
                        deadline: NIODeadline? = nil,
                        logger: Logger?) -> EventLoopFuture<Response> {
        let accumulator = ResponseAccumulator(request: request)
        return self.execute(request: request, delegate: accumulator, eventLoop: eventLoopPreference, deadline: deadline, logger: logger).futureResult
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
        return self.execute(request: request, delegate: delegate, deadline: deadline, logger: HTTPClient.loggingDisabled)
    }

    /// Execute arbitrary HTTP request and handle response processing using provided delegate.
    ///
    /// - parameters:
    ///     - request: HTTP request to execute.
    ///     - delegate: Delegate to process response parts.
    ///     - deadline: Point in time by which the request must complete.
    ///     - logger: The logger to use for this request.
    public func execute<Delegate: HTTPClientResponseDelegate>(request: Request,
                                                              delegate: Delegate,
                                                              deadline: NIODeadline? = nil,
                                                              logger: Logger) -> Task<Delegate.Response> {
        return self.execute(request: request, delegate: delegate, eventLoop: .indifferent, deadline: deadline, logger: logger)
    }

    /// Execute arbitrary HTTP request and handle response processing using provided delegate.
    ///
    /// - parameters:
    ///     - request: HTTP request to execute.
    ///     - delegate: Delegate to process response parts.
    ///     - eventLoop: NIO Event Loop preference.
    ///     - deadline: Point in time by which the request must complete.
    ///     - logger: The logger to use for this request.
    public func execute<Delegate: HTTPClientResponseDelegate>(request: Request,
                                                              delegate: Delegate,
                                                              eventLoop eventLoopPreference: EventLoopPreference,
                                                              deadline: NIODeadline? = nil) -> Task<Delegate.Response> {
        return self.execute(request: request,
                            delegate: delegate,
                            eventLoop: eventLoopPreference,
                            deadline: deadline,
                            logger: HTTPClient.loggingDisabled)
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
                                                              deadline: NIODeadline? = nil,
                                                              logger originalLogger: Logger?) -> Task<Delegate.Response> {
        let logger = (originalLogger ?? HTTPClient.loggingDisabled).attachingRequestInformation(request, requestID: globalRequestID.add(1))
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
        logger.trace("selected EventLoop for task given the preference",
                     metadata: ["ahc-eventloop": "\(taskEL)",
                                "ahc-el-preference": "\(eventLoopPreference)"])

        let failedTask: Task<Delegate.Response>? = self.stateLock.withLock {
            switch state {
            case .upAndRunning:
                return nil
            case .shuttingDown, .shutDown:
                logger.debug("client is shutting down, failing request")
                return Task<Delegate.Response>.failedTask(eventLoop: taskEL,
                                                          error: HTTPClientError.alreadyShutdown,
                                                          logger: logger)
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

        let task = Task<Delegate.Response>(eventLoop: taskEL, logger: logger)
        let setupComplete = taskEL.makePromise(of: Void.self)
        let connection = self.pool.getConnection(request,
                                                 preference: eventLoopPreference,
                                                 taskEventLoop: taskEL,
                                                 deadline: deadline,
                                                 setupComplete: setupComplete.futureResult,
                                                 logger: logger)

        let taskHandler = TaskHandler(task: task,
                                      kind: request.kind,
                                      delegate: delegate,
                                      redirectHandler: redirectHandler,
                                      ignoreUncleanSSLShutdown: self.configuration.ignoreUncleanSSLShutdown,
                                      logger: logger)

        connection.flatMap { connection -> EventLoopFuture<Void> in
            logger.debug("got connection for request",
                         metadata: ["ahc-connection": "\(connection)",
                                    "ahc-request": "\(request.method) \(request.url)",
                                    "ahc-channel-el": "\(connection.channel.eventLoop)",
                                    "ahc-task-el": "\(taskEL)"])

            let channel = connection.channel
            let future: EventLoopFuture<Void>
            if let timeout = self.resolve(timeout: self.configuration.timeout.read, deadline: deadline) {
                future = channel.pipeline.addHandler(IdleStateHandler(readTimeout: timeout))
            } else {
                future = channel.eventLoop.makeSucceededFuture(())
            }

            return future.flatMap {
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
                connection.release(closing: true, logger: logger)
                return channel.eventLoop.makeFailedFuture(error)
            }
        }.always { _ in
            setupComplete.succeed(())
        }.whenFailure { error in
            taskHandler.callOutToDelegateFireAndForget { task in
                delegate.didReceiveError(task: task, error)
            }
            task.promise.fail(error)
        }

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
        public var tlsConfiguration: Optional<TLSConfiguration>
        /// Enables following 3xx redirects automatically, defaults to `RedirectConfiguration()`.
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
        public var maximumAllowedIdleTimeInConnectionPool: Optional<TimeAmount>
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
            self.init(tlsConfiguration: TLSConfiguration.forClient(certificateVerification: certificateVerification),
                      redirectConfiguration: redirectConfiguration,
                      timeout: timeout,
                      maximumAllowedIdleTimeInConnectionPool: maximumAllowedIdleTimeInConnectionPool,
                      proxy: proxy,
                      ignoreUncleanSSLShutdown: ignoreUncleanSSLShutdown,
                      decompression: decompression)
        }

        public init(certificateVerification: CertificateVerification,
                    redirectConfiguration: RedirectConfiguration? = nil,
                    timeout: Timeout = Timeout(),
                    maximumAllowedIdleTimeInConnectionPool: TimeAmount = .seconds(60),
                    proxy: Proxy? = nil,
                    ignoreUncleanSSLShutdown: Bool = false,
                    decompression: Decompression = .disabled,
                    backgroundActivityLogger: Logger?) {
            self.init(tlsConfiguration: TLSConfiguration.forClient(certificateVerification: certificateVerification),
                      redirectConfiguration: redirectConfiguration,
                      timeout: timeout,
                      maximumAllowedIdleTimeInConnectionPool: maximumAllowedIdleTimeInConnectionPool,
                      proxy: proxy,
                      ignoreUncleanSSLShutdown: ignoreUncleanSSLShutdown,
                      decompression: decompression)
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

    func addSSLHandlerIfNeeded(for key: ConnectionPool.Key, tlsConfiguration: TLSConfiguration?, addSSLClient: Bool, handshakePromise: EventLoopPromise<Void>) {
        guard key.scheme.requiresTLS else {
            handshakePromise.succeed(())
            return
        }

        do {
            let handlers: [ChannelHandler]
            if addSSLClient {
                let tlsConfiguration = tlsConfiguration ?? TLSConfiguration.forClient()
                let context = try NIOSSLContext(configuration: tlsConfiguration)
                handlers = [
                    try NIOSSLClientHandler(context: context, serverHostname: (key.host.isIPAddress || key.host.isEmpty) ? nil : key.host),
                    TLSEventsHandler(completionPromise: handshakePromise),
                ]
            } else {
                handlers = [TLSEventsHandler(completionPromise: handshakePromise)]
            }
            self.addHandlers(handlers).cascadeFailure(to: handshakePromise)
        } catch {
            handshakePromise.fail(error)
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
        case missingSocketPath
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
        case traceRequestWithBody
        case invalidHeaderFieldNames([String])
        case bodyLengthMismatch
        case writeAfterRequestSent
        case incompatibleHeaders
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
    /// URL does not contain a socketPath as a host for http(s)+unix shemes.
    public static let missingSocketPath = HTTPClientError(code: .missingSocketPath)
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
    /// Unclean shutdown.
    public static let uncleanShutdown = HTTPClientError(code: .uncleanShutdown)
    /// A body was sent in a request with method TRACE.
    public static let traceRequestWithBody = HTTPClientError(code: .traceRequestWithBody)
    /// Header field names contain invalid characters.
    public static func invalidHeaderFieldNames(_ names: [String]) -> HTTPClientError { return HTTPClientError(code: .invalidHeaderFieldNames(names)) }
    /// Body length is not equal to `Content-Length`.
    public static let bodyLengthMismatch = HTTPClientError(code: .bodyLengthMismatch)
    /// Body part was written after request was fully sent.
    public static let writeAfterRequestSent = HTTPClientError(code: .writeAfterRequestSent)
    /// Incompatible headers specified, for example `Transfer-Encoding` and `Content-Length`.
    public static let incompatibleHeaders = HTTPClientError(code: .incompatibleHeaders)
}
