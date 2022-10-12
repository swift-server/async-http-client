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

import Atomics
import Foundation
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOHTTPCompression
import NIOPosix
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

let globalRequestID = ManagedAtomic(0)

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
    /// The `EventLoopGroup` in use by this ``HTTPClient``.
    ///
    /// All HTTP transactions will occur on loops owned by this group.
    public let eventLoopGroup: EventLoopGroup
    let eventLoopGroupProvider: EventLoopGroupProvider
    let configuration: Configuration
    let poolManager: HTTPConnectionPool.Manager

    /// Shared thread pool used for file IO. It is lazily created on first access of ``Task/fileIOThreadPool``.
    private var fileIOThreadPool: NIOThreadPool?
    private let fileIOThreadPoolLock = NIOLock()

    private var state: State
    private let stateLock = NIOLock()

    internal static let loggingDisabled = Logger(label: "AHC-do-not-log", factory: { _ in SwiftLogNoOpLogHandler() })

    /// Create an ``HTTPClient`` with specified `EventLoopGroup` provider and configuration.
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

    /// Create an ``HTTPClient`` with specified `EventLoopGroup` provider and configuration.
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
        self.poolManager = HTTPConnectionPool.Manager(
            eventLoopGroup: self.eventLoopGroup,
            configuration: self.configuration,
            backgroundActivityLogger: backgroundActivityLogger
        )
        self.state = .upAndRunning
    }

    deinit {
        debugOnly {
            // We want to crash only in debug mode.
            switch self.state {
            case .shutDown:
                break
            case .shuttingDown:
                preconditionFailure("""
                This state should be totally unreachable. While the HTTPClient is shutting down a \
                reference cycle should exist, that prevents it from deinit.
                """)
            case .upAndRunning:
                preconditionFailure("""
                Client not shut down before the deinit. Please call client.syncShutdown() when no \
                longer needed. Otherwise memory will leak.
                """)
            }
        }
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
        let errorStorageLock = NIOLock()
        let errorStorage: UnsafeMutableTransferBox<Error?> = .init(nil)
        let continuation = DispatchWorkItem {}
        self.shutdown(requiresCleanClose: requiresCleanClose, queue: DispatchQueue(label: "async-http-client.shutdown")) { error in
            if let error = error {
                errorStorageLock.withLock {
                    errorStorage.wrappedValue = error
                }
            }
            continuation.perform()
        }
        continuation.wait()
        try errorStorageLock.withLock {
            if let error = errorStorage.wrappedValue {
                throw error
            }
        }
    }

    #if swift(>=5.6)
    /// Shuts down the client and event loop gracefully.
    ///
    /// This function is clearly an outlier in that it uses a completion
    /// callback instead of an EventLoopFuture. The reason for that is that NIO's EventLoopFutures will call back on an event loop.
    /// The virtue of this function is to shut the event loop down. To work around that we call back on a DispatchQueue
    /// instead.
    @preconcurrency public func shutdown(
        queue: DispatchQueue = .global(),
        _ callback: @Sendable @escaping (Error?) -> Void
    ) {
        self.shutdown(requiresCleanClose: false, queue: queue, callback)
    }
    #else
    /// Shuts down the client and event loop gracefully.
    ///
    /// This function is clearly an outlier in that it uses a completion
    /// callback instead of an EventLoopFuture. The reason for that is that NIO's EventLoopFutures will call back on an event loop.
    /// The virtue of this function is to shut the event loop down. To work around that we call back on a DispatchQueue
    /// instead.
    public func shutdown(queue: DispatchQueue = .global(), _ callback: @escaping (Error?) -> Void) {
        self.shutdown(requiresCleanClose: false, queue: queue, callback)
    }
    #endif

    /// Shuts down the ``HTTPClient`` and releases its resources.
    ///
    /// - note: You cannot use this method if you sharted the ``HTTPClient`` with
    ///         ``init(eventLoopGroupProvider: .createNew)`` because that will shut down the ``EventLoopGroup`` the
    ///         returned future would run in.
    public func shutdown() -> EventLoopFuture<Void> {
        switch self.eventLoopGroupProvider {
        case .shared(let group):
            let promise = group.any().makePromise(of: Void.self)
            self.shutdown(queue: .global()) { error in
                if let error = error {
                    promise.fail(error)
                } else {
                    promise.succeed(())
                }
            }
            return promise.futureResult
        case .createNew:
            preconditionFailure("Cannot use the shutdown() method which returns a future when owning the EventLoopGroup. Please use the one of the other shutdown methods.")
        }
    }

    private func shutdownEventLoop(queue: DispatchQueue, _ callback: @escaping ShutdownCallback) {
        self.stateLock.withLock {
            switch self.eventLoopGroupProvider {
            case .shared:
                self.state = .shutDown
                queue.async {
                    callback(nil)
                }
            case .createNew:
                switch self.state {
                case .shuttingDown:
                    self.state = .shutDown
                    self.eventLoopGroup.shutdownGracefully(queue: queue, callback)
                case .shutDown, .upAndRunning:
                    assertionFailure("The only valid state at this point is \(String(describing: State.shuttingDown))")
                }
            }
        }
    }

    private func shutdownFileIOThreadPool(queue: DispatchQueue, _ callback: @escaping ShutdownCallback) {
        self.fileIOThreadPoolLock.withLock {
            guard let fileIOThreadPool = fileIOThreadPool else {
                callback(nil)
                return
            }
            fileIOThreadPool.shutdownGracefully(queue: queue, callback)
        }
    }

    private func shutdown(requiresCleanClose: Bool, queue: DispatchQueue, _ callback: @escaping ShutdownCallback) {
        do {
            try self.stateLock.withLock {
                guard case .upAndRunning = self.state else {
                    throw HTTPClientError.alreadyShutdown
                }
                self.state = .shuttingDown(requiresCleanClose: requiresCleanClose, callback: callback)
            }
        } catch {
            callback(error)
            return
        }

        let promise = self.eventLoopGroup.any().makePromise(of: Bool.self)
        self.poolManager.shutdown(promise: promise)
        promise.futureResult.whenComplete { result in
            switch result {
            case .failure:
                preconditionFailure("Shutting down the connection pool must not fail, ever.")
            case .success(let unclean):
                let (callback, uncleanError) = self.stateLock.withLock { () -> (ShutdownCallback, Error?) in
                    guard case .shuttingDown(let requiresClean, callback: let callback) = self.state else {
                        preconditionFailure("Why did the pool manager shut down, if it was not instructed to")
                    }

                    let error: Error? = (requiresClean && unclean) ? HTTPClientError.uncleanShutdown : nil
                    return (callback, error)
                }
                self.shutdownFileIOThreadPool(queue: queue) { ioThreadPoolError in
                    self.shutdownEventLoop(queue: queue) { error in
                        let reportedError = error ?? ioThreadPoolError ?? uncleanError
                        callback(reportedError)
                    }
                }
            }
        }
    }

    private func makeOrGetFileIOThreadPool() -> NIOThreadPool {
        self.fileIOThreadPoolLock.withLock {
            guard let fileIOThreadPool = fileIOThreadPool else {
                let fileIOThreadPool = NIOThreadPool(numberOfThreads: System.coreCount)
                fileIOThreadPool.start()
                self.fileIOThreadPool = fileIOThreadPool
                return fileIOThreadPool
            }
            return fileIOThreadPool
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
            return self.eventLoopGroup.any().makeFailedFuture(error)
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
            return self.eventLoopGroup.any().makeFailedFuture(error)
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
            return self.eventLoopGroup.any().makeFailedFuture(error)
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
    ///     - logger: The logger to use for this request.
    public func execute<Delegate: HTTPClientResponseDelegate>(
        request: Request,
        delegate: Delegate,
        eventLoop eventLoopPreference: EventLoopPreference,
        deadline: NIODeadline? = nil,
        logger originalLogger: Logger?
    ) -> Task<Delegate.Response> {
        self._execute(
            request: request,
            delegate: delegate,
            eventLoop: eventLoopPreference,
            deadline: deadline,
            logger: originalLogger,
            redirectState: RedirectState(
                self.configuration.redirectConfiguration.mode,
                initialURL: request.url.absoluteString
            )
        )
    }

    /// Execute arbitrary HTTP request and handle response processing using provided delegate.
    ///
    /// - parameters:
    ///     - request: HTTP request to execute.
    ///     - delegate: Delegate to process response parts.
    ///     - eventLoop: NIO Event Loop preference.
    ///     - deadline: Point in time by which the request must complete.
    ///     - logger: The logger to use for this request.
    func _execute<Delegate: HTTPClientResponseDelegate>(
        request: Request,
        delegate: Delegate,
        eventLoop eventLoopPreference: EventLoopPreference,
        deadline: NIODeadline? = nil,
        logger originalLogger: Logger?,
        redirectState: RedirectState?
    ) -> Task<Delegate.Response> {
        let logger = (originalLogger ?? HTTPClient.loggingDisabled).attachingRequestInformation(request, requestID: globalRequestID.wrappingIncrementThenLoad(ordering: .relaxed))
        let taskEL: EventLoop
        switch eventLoopPreference.preference {
        case .indifferent:
            // if possible we want a connection on the current `EventLoop`
            taskEL = self.eventLoopGroup.any()
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
                                                          logger: logger,
                                                          makeOrGetFileIOThreadPool: self.makeOrGetFileIOThreadPool)
            }
        }

        if let failedTask = failedTask {
            return failedTask
        }

        let redirectHandler: RedirectHandler<Delegate.Response>? = {
            guard let redirectState = redirectState else { return nil }

            return .init(request: request, redirectState: redirectState) { newRequest, newRedirectState in
                self._execute(
                    request: newRequest,
                    delegate: delegate,
                    eventLoop: eventLoopPreference,
                    deadline: deadline,
                    logger: logger,
                    redirectState: newRedirectState
                )
            }
        }()

        let task = Task<Delegate.Response>(eventLoop: taskEL, logger: logger, makeOrGetFileIOThreadPool: self.makeOrGetFileIOThreadPool)
        do {
            let requestBag = try RequestBag(
                request: request,
                eventLoopPreference: eventLoopPreference,
                task: task,
                redirectHandler: redirectHandler,
                connectionDeadline: .now() + (self.configuration.timeout.connectionCreationTimeout),
                requestOptions: .fromClientConfiguration(self.configuration),
                delegate: delegate
            )

            var deadlineSchedule: Scheduled<Void>?
            if let deadline = deadline {
                deadlineSchedule = taskEL.scheduleTask(deadline: deadline) {
                    requestBag.deadlineExceeded()
                }

                task.promise.futureResult.whenComplete { _ in
                    deadlineSchedule?.cancel()
                }
            }

            self.poolManager.executeRequest(requestBag)
        } catch {
            task.fail(with: error, delegateType: Delegate.self)
        }

        return task
    }

    /// ``HTTPClient`` configuration.
    public struct Configuration {
        /// TLS configuration, defaults to `TLSConfiguration.makeClientConfiguration()`.
        public var tlsConfiguration: Optional<TLSConfiguration>
        /// Enables following 3xx redirects automatically.
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
        /// Default client timeout, defaults to no ``Timeout-swift.struct/read`` timeout
        /// and 10 seconds ``Timeout-swift.struct/connect`` timeout.
        public var timeout: Timeout
        /// Connection pool configuration.
        public var connectionPool: ConnectionPool
        /// Upstream proxy, defaults to no proxy.
        public var proxy: Proxy?
        /// Enables automatic body decompression. Supported algorithms are gzip and deflate.
        public var decompression: Decompression
        /// Ignore TLS unclean shutdown error, defaults to `false`.
        @available(*, deprecated, message: "AsyncHTTPClient now correctly supports handling unexpected SSL connection drops. This property is ignored")
        public var ignoreUncleanSSLShutdown: Bool {
            get { false }
            set {}
        }

        /// What HTTP versions to use.
        ///
        /// Set to ``HTTPVersion-swift.struct/automatic`` by default which will use HTTP/2 if run over https and the server supports it, otherwise HTTP/1
        public var httpVersion: HTTPVersion

        /// Whether ``HTTPClient`` will let Network.framework sit in the `.waiting` state awaiting new network changes, or fail immediately. Defaults to `true`,
        /// which is the recommended setting. Only set this to `false` when attempting to trigger a particular error path.
        public var networkFrameworkWaitForConnectivity: Bool

        public init(
            tlsConfiguration: TLSConfiguration? = nil,
            redirectConfiguration: RedirectConfiguration? = nil,
            timeout: Timeout = Timeout(),
            connectionPool: ConnectionPool = ConnectionPool(),
            proxy: Proxy? = nil,
            ignoreUncleanSSLShutdown: Bool = false,
            decompression: Decompression = .disabled
        ) {
            self.tlsConfiguration = tlsConfiguration
            self.redirectConfiguration = redirectConfiguration ?? RedirectConfiguration()
            self.timeout = timeout
            self.connectionPool = connectionPool
            self.proxy = proxy
            self.decompression = decompression
            self.httpVersion = .automatic
            self.networkFrameworkWaitForConnectivity = true
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
                connectionPool: ConnectionPool(),
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
            var tlsConfig = TLSConfiguration.makeClientConfiguration()
            tlsConfig.certificateVerification = certificateVerification
            self.init(tlsConfiguration: tlsConfig,
                      redirectConfiguration: redirectConfiguration,
                      timeout: timeout,
                      connectionPool: ConnectionPool(),
                      proxy: proxy,
                      ignoreUncleanSSLShutdown: ignoreUncleanSSLShutdown,
                      decompression: decompression)
        }

        public init(certificateVerification: CertificateVerification,
                    redirectConfiguration: RedirectConfiguration? = nil,
                    timeout: Timeout = Timeout(),
                    connectionPool: TimeAmount = .seconds(60),
                    proxy: Proxy? = nil,
                    ignoreUncleanSSLShutdown: Bool = false,
                    decompression: Decompression = .disabled,
                    backgroundActivityLogger: Logger?) {
            var tlsConfig = TLSConfiguration.makeClientConfiguration()
            tlsConfig.certificateVerification = certificateVerification
            self.init(tlsConfiguration: tlsConfig,
                      redirectConfiguration: redirectConfiguration,
                      timeout: timeout,
                      connectionPool: ConnectionPool(),
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
        /// `EventLoopGroup` will be created by the client. When ``HTTPClient/syncShutdown()`` is called, the created `EventLoopGroup` will be shut down as well.
        case createNew
    }

    /// Specifies how the library will treat the event loop passed by the user.
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
    }

    /// Specifies decompression settings.
    public enum Decompression: Sendable {
        /// Decompression is disabled.
        case disabled
        /// Decompression is enabled.
        case enabled(limit: NIOHTTPDecompression.DecompressionLimit)
    }

    #if swift(>=5.6)
    typealias ShutdownCallback = @Sendable (Error?) -> Void
    #else
    typealias ShutdownCallback = (Error?) -> Void
    #endif

    enum State {
        case upAndRunning
        case shuttingDown(requiresCleanClose: Bool, callback: ShutdownCallback)
        case shutDown
    }
}

#if swift(>=5.7)
extension HTTPClient.Configuration: Sendable {}
#endif

#if swift(>=5.6)
extension HTTPClient.EventLoopGroupProvider: Sendable {}
extension HTTPClient.EventLoopPreference: Sendable {}
#endif

// HTTPClient is thread-safe because its shared mutable state is protected through a lock
extension HTTPClient: @unchecked Sendable {}

extension HTTPClient.Configuration {
    /// Timeout configuration.
    public struct Timeout: Sendable {
        /// Specifies connect timeout. If no connect timeout is given, a default 30 seconds timeout will applied.
        public var connect: TimeAmount?
        /// Specifies read timeout.
        public var read: TimeAmount?

        /// internal connection creation timeout. Defaults the connect timeout to always contain a value.
        var connectionCreationTimeout: TimeAmount {
            self.connect ?? .seconds(10)
        }

        /// Create timeout.
        ///
        /// - parameters:
        ///     - connect: `connect` timeout. Will default to 10 seconds, if no value is provided.
        ///     - read: `read` timeout.
        public init(connect: TimeAmount? = nil, read: TimeAmount? = nil) {
            self.connect = connect
            self.read = read
        }
    }

    /// Specifies redirect processing settings.
    public struct RedirectConfiguration: Sendable {
        enum Mode {
            /// Redirects are not followed.
            case disallow
            /// Redirects are followed with a specified limit.
            case follow(max: Int, allowCycles: Bool)
        }

        var mode: Mode

        init() {
            self.mode = .follow(max: 5, allowCycles: false)
        }

        init(configuration: Mode) {
            self.mode = configuration
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

    /// Connection pool configuration.
    public struct ConnectionPool: Hashable, Sendable {
        /// Specifies amount of time connections are kept idle in the pool. After this time has passed without a new
        /// request the connections are closed.
        public var idleTimeout: TimeAmount

        /// The maximum number of connections that are kept alive in the connection pool per host. If requests with
        /// an explicit eventLoopRequirement are sent, this number might be exceeded due to overflow connections.
        public var concurrentHTTP1ConnectionsPerHostSoftLimit: Int

        /// If true, ``HTTPClient`` will try to create new connections on connection failure with an exponential backoff.
        /// Requests will only fail after the ``HTTPClient/Configuration/Timeout-swift.struct/connect`` timeout exceeded.
        /// If false, all requests that have no assigned connection will fail immediately after a connection could not be established.
        /// Defaults to `true`.
        /// - warning: We highly recommend leaving this on.
        /// It is very common that connections establishment is flaky at scale.
        /// ``HTTPClient`` will automatically mitigate these kind of issues if this flag is turned on.
        var retryConnectionEstablishment: Bool

        public init(idleTimeout: TimeAmount = .seconds(60)) {
            self.init(idleTimeout: idleTimeout, concurrentHTTP1ConnectionsPerHostSoftLimit: 8)
        }

        public init(idleTimeout: TimeAmount, concurrentHTTP1ConnectionsPerHostSoftLimit: Int) {
            self.idleTimeout = idleTimeout
            self.concurrentHTTP1ConnectionsPerHostSoftLimit = concurrentHTTP1ConnectionsPerHostSoftLimit
            self.retryConnectionEstablishment = true
        }
    }

    public struct HTTPVersion: Sendable, Hashable {
        internal enum Configuration {
            case http1Only
            case automatic
        }

        /// We will only use HTTP/1, even if the server would supports HTTP/2
        public static let http1Only: Self = .init(configuration: .http1Only)

        /// HTTP/2 is used if we connect to a server with HTTPS and the server supports HTTP/2, otherwise we use HTTP/1
        public static let automatic: Self = .init(configuration: .automatic)

        internal var configuration: Configuration
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
        @available(*, deprecated, message: "AsyncHTTPClient now silently corrects this invalid header.")
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
        @available(*, deprecated, message: "AsyncHTTPClient now silently corrects invalid headers.")
        case incompatibleHeaders
        case connectTimeout
        case socksHandshakeTimeout
        case httpProxyHandshakeTimeout
        case tlsHandshakeTimeout
        case serverOfferedUnsupportedApplicationProtocol(String)
        case requestStreamCancelled
        case getConnectionFromPoolTimeout
        case deadlineExceeded
        case httpEndReceivedAfterHeadWith1xx
    }

    private var code: Code

    private init(code: Code) {
        self.code = code
    }

    public var description: String {
        return "HTTPClientError.\(String(describing: self.code))"
    }

    /// Short description of the error that can be used in case a bounded set of error descriptions is expected, e.g. to
    /// include in metric labels. For this reason the description must not contain associated values.
    public var shortDescription: String {
        // When adding new cases here, do *not* include dynamic (associated) values in the description.
        switch self.code {
        case .invalidURL:
            return "Invalid URL"
        case .emptyHost:
            return "Empty host"
        case .missingSocketPath:
            return "Missing socket path"
        case .alreadyShutdown:
            return "Already shutdown"
        case .emptyScheme:
            return "Empty scheme"
        case .unsupportedScheme:
            return "Unsupported scheme"
        case .readTimeout:
            return "Read timeout"
        case .remoteConnectionClosed:
            return "Remote connection closed"
        case .cancelled:
            return "Cancelled"
        case .identityCodingIncorrectlyPresent:
            return "Identity coding incorrectly present"
        case .chunkedSpecifiedMultipleTimes:
            return "Chunked specified multiple times"
        case .invalidProxyResponse:
            return "Invalid proxy response"
        case .contentLengthMissing:
            return "Content length missing"
        case .proxyAuthenticationRequired:
            return "Proxy authentication required"
        case .redirectLimitReached:
            return "Redirect limit reached"
        case .redirectCycleDetected:
            return "Redirect cycle detected"
        case .uncleanShutdown:
            return "Unclean shutdown"
        case .traceRequestWithBody:
            return "Trace request with body"
        case .invalidHeaderFieldNames:
            return "Invalid header field names"
        case .bodyLengthMismatch:
            return "Body length mismatch"
        case .writeAfterRequestSent:
            return "Write after request sent"
        case .incompatibleHeaders:
            return "Incompatible headers"
        case .connectTimeout:
            return "Connect timeout"
        case .socksHandshakeTimeout:
            return "SOCKS handshake timeout"
        case .httpProxyHandshakeTimeout:
            return "HTTP proxy handshake timeout"
        case .tlsHandshakeTimeout:
            return "TLS handshake timeout"
        case .serverOfferedUnsupportedApplicationProtocol:
            return "Server offered unsupported application protocol"
        case .requestStreamCancelled:
            return "Request stream cancelled"
        case .getConnectionFromPoolTimeout:
            return "Get connection from pool timeout"
        case .deadlineExceeded:
            return "Deadline exceeded"
        case .httpEndReceivedAfterHeadWith1xx:
            return "HTTP end received after head with 1xx"
        }
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
    @available(*, deprecated, message: "AsyncHTTPClient now silently corrects this invalid header.")
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
    @available(*, deprecated, message: "AsyncHTTPClient now silently corrects invalid headers.")
    public static let incompatibleHeaders = HTTPClientError(code: .incompatibleHeaders)
    /// Creating a new tcp connection timed out
    public static let connectTimeout = HTTPClientError(code: .connectTimeout)
    /// The socks handshake timed out.
    public static let socksHandshakeTimeout = HTTPClientError(code: .socksHandshakeTimeout)
    /// The http proxy connection creation timed out.
    public static let httpProxyHandshakeTimeout = HTTPClientError(code: .httpProxyHandshakeTimeout)
    /// The tls handshake timed out.
    public static let tlsHandshakeTimeout = HTTPClientError(code: .tlsHandshakeTimeout)
    /// The remote server only offered an unsupported application protocol
    public static func serverOfferedUnsupportedApplicationProtocol(_ proto: String) -> HTTPClientError {
        return HTTPClientError(code: .serverOfferedUnsupportedApplicationProtocol(proto))
    }

    /// The request deadline was exceeded. The request was cancelled because of this.
    public static let deadlineExceeded = HTTPClientError(code: .deadlineExceeded)

    /// The remote server responded with a status code >= 300, before the full request was sent. The request stream
    /// was therefore cancelled
    public static let requestStreamCancelled = HTTPClientError(code: .requestStreamCancelled)

    /// Aquiring a HTTP connection from the connection pool timed out.
    ///
    /// This can have multiple reasons:
    ///  - A connection could not be created within the timout period.
    ///  - Tasks are not processed fast enough on the existing connections, to process all waiters in time
    public static let getConnectionFromPoolTimeout = HTTPClientError(code: .getConnectionFromPoolTimeout)

    @available(*, deprecated, message: "AsyncHTTPClient now correctly supports informational headers. For this reason `httpEndReceivedAfterHeadWith1xx` will not be thrown anymore.")
    public static let httpEndReceivedAfterHeadWith1xx = HTTPClientError(code: .httpEndReceivedAfterHeadWith1xx)
}
