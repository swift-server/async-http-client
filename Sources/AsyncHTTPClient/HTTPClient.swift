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
import Tracing

extension Logger {
    private func requestInfo(_ request: HTTPClient.Request) -> Logger.Metadata.Value {
        "\(request.method) \(request.url)"
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
///     HTTPClient.shared.get(url: "https://swift.org", deadline: .now() + .seconds(1)).whenComplete { result in
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
public final class HTTPClient: Sendable {
    /// The `EventLoopGroup` in use by this ``HTTPClient``.
    ///
    /// All HTTP transactions will occur on loops owned by this group.
    public let eventLoopGroup: EventLoopGroup
    let poolManager: HTTPConnectionPool.Manager

    @usableFromInline
    let configuration: Configuration

    /// Shared thread pool used for file IO. It is lazily created on first access of ``Task/fileIOThreadPool``.
    private let fileIOThreadPool: NIOLockedValueBox<NIOThreadPool?>

    private let state: NIOLockedValueBox<State>
    private let canBeShutDown: Bool

    /// Tracer configured for this HTTPClient at configuration time.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public var tracer: (any Tracer)? {
        configuration.tracing.tracer
    }

    /// Access to tracing configuration in order to get configured attribute keys etc.
    @usableFromInline
    package var tracing: TracingConfiguration {
        self.configuration.tracing
    }

    static let loggingDisabled = Logger(label: "AHC-do-not-log", factory: { _ in SwiftLogNoOpLogHandler() })

    /// Create an ``HTTPClient`` with specified `EventLoopGroup` provider and configuration.
    ///
    /// - parameters:
    ///     - eventLoopGroupProvider: Specify how `EventLoopGroup` will be created.
    ///     - configuration: Client configuration.
    public convenience init(
        eventLoopGroupProvider: EventLoopGroupProvider,
        configuration: Configuration = Configuration()
    ) {
        self.init(
            eventLoopGroupProvider: eventLoopGroupProvider,
            configuration: configuration,
            backgroundActivityLogger: HTTPClient.loggingDisabled
        )
    }

    /// Create an ``HTTPClient`` with specified `EventLoopGroup`  and configuration.
    ///
    /// - parameters:
    ///     - eventLoopGroup: Specify how `EventLoopGroup` will be created.
    ///     - configuration: Client configuration.
    public convenience init(
        eventLoopGroup: EventLoopGroup = HTTPClient.defaultEventLoopGroup,
        configuration: Configuration = Configuration()
    ) {
        self.init(
            eventLoopGroupProvider: .shared(eventLoopGroup),
            configuration: configuration,
            backgroundActivityLogger: HTTPClient.loggingDisabled
        )
    }

    /// Create an ``HTTPClient`` with specified `EventLoopGroup` provider and configuration.
    ///
    /// - parameters:
    ///     - eventLoopGroupProvider: Specify how `EventLoopGroup` will be created.
    ///     - configuration: Client configuration.
    ///     - backgroundActivityLogger: The logger to use for background activity logs.
    public convenience init(
        eventLoopGroupProvider: EventLoopGroupProvider,
        configuration: Configuration = Configuration(),
        backgroundActivityLogger: Logger
    ) {
        let eventLoopGroup: any EventLoopGroup

        switch eventLoopGroupProvider {
        case .shared(let group):
            eventLoopGroup = group
        default:  // handle `.createNew` without a deprecation warning
            eventLoopGroup = HTTPClient.defaultEventLoopGroup
        }

        self.init(
            eventLoopGroup: eventLoopGroup,
            configuration: configuration,
            backgroundActivityLogger: backgroundActivityLogger
        )
    }

    /// Create an ``HTTPClient`` with specified `EventLoopGroup` and configuration.
    ///
    /// - parameters:
    ///     - eventLoopGroup: The `EventLoopGroup` that the ``HTTPClient`` will use.
    ///     - configuration: Client configuration.
    ///     - backgroundActivityLogger: The `Logger` that will be used to log background any activity that's not associated with a request.
    public convenience init(
        eventLoopGroup: any EventLoopGroup = HTTPClient.defaultEventLoopGroup,
        configuration: Configuration = Configuration(),
        backgroundActivityLogger: Logger
    ) {
        self.init(
            eventLoopGroup: eventLoopGroup,
            configuration: configuration,
            backgroundActivityLogger: backgroundActivityLogger,
            canBeShutDown: true
        )
    }

    internal required init(
        eventLoopGroup: EventLoopGroup,
        configuration: Configuration = Configuration(),
        backgroundActivityLogger: Logger,
        canBeShutDown: Bool
    ) {
        self.canBeShutDown = canBeShutDown
        self.eventLoopGroup = eventLoopGroup
        self.configuration = configuration
        self.poolManager = HTTPConnectionPool.Manager(
            eventLoopGroup: self.eventLoopGroup,
            configuration: self.configuration,
            backgroundActivityLogger: backgroundActivityLogger
        )
        self.state = NIOLockedValueBox(.upAndRunning)
        self.fileIOThreadPool = NIOLockedValueBox(nil)
    }

    deinit {
        debugOnly {
            // We want to crash only in debug mode.
            self.state.withLockedValue { state in
                switch state {
                case .shutDown:
                    break
                case .shuttingDown:
                    preconditionFailure(
                        """
                        This state should be totally unreachable. While the HTTPClient is shutting down a \
                        reference cycle should exist, that prevents it from deinit.
                        """
                    )
                case .upAndRunning:
                    preconditionFailure(
                        """
                        Client not shut down before the deinit. Please call client.shutdown() when no \
                        longer needed. Otherwise memory will leak.
                        """
                    )
                }
            }
        }
    }

    /// Shuts down the client and `EventLoopGroup` if it was created by the client.
    ///
    /// This method blocks the thread indefinitely, prefer using ``shutdown()-96ayw``.
    @available(*, noasync, message: "syncShutdown() can block indefinitely, prefer shutdown()", renamed: "shutdown()")
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
    func syncShutdown(requiresCleanClose: Bool) throws {
        if let eventLoop = MultiThreadedEventLoopGroup.currentEventLoop {
            preconditionFailure(
                """
                BUG DETECTED: syncShutdown() must not be called when on an EventLoop.
                Calling syncShutdown() on any EventLoop can lead to deadlocks.
                Current eventLoop: \(eventLoop)
                """
            )
        }

        final class ShutdownError: @unchecked Sendable {
            // @unchecked because error is protected by lock.

            // Stores whether the shutdown has happened or not.
            private let lock: ConditionLock<Bool>
            private var error: Error?

            init() {
                self.error = nil
                self.lock = ConditionLock(value: false)
            }

            func didShutdown(_ error: (any Error)?) {
                self.lock.lock(whenValue: false)
                defer {
                    self.lock.unlock(withValue: true)
                }
                self.error = error
            }

            func blockUntilShutdown() -> (any Error)? {
                self.lock.lock(whenValue: true)
                defer {
                    self.lock.unlock(withValue: true)
                }
                return self.error
            }
        }

        let shutdownError = ShutdownError()

        self.shutdown(
            requiresCleanClose: requiresCleanClose,
            queue: DispatchQueue(label: "async-http-client.shutdown")
        ) { error in
            shutdownError.didShutdown(error)
        }

        let error = shutdownError.blockUntilShutdown()

        if let error = error {
            throw error
        }
    }

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

    /// Shuts down the ``HTTPClient`` and releases its resources.
    public func shutdown() -> EventLoopFuture<Void> {
        let promise = self.eventLoopGroup.any().makePromise(of: Void.self)
        self.shutdown(queue: .global()) { error in
            if let error = error {
                promise.fail(error)
            } else {
                promise.succeed(())
            }
        }
        return promise.futureResult
    }

    private func shutdown(requiresCleanClose: Bool, queue: DispatchQueue, _ callback: @escaping ShutdownCallback) {
        guard self.canBeShutDown else {
            queue.async {
                callback(HTTPClientError.shutdownUnsupported)
            }
            return
        }
        do {
            try self.state.withLockedValue { state in
                guard case .upAndRunning = state else {
                    throw HTTPClientError.alreadyShutdown
                }
                state = .shuttingDown(requiresCleanClose: requiresCleanClose, callback: callback)
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
                let (callback, uncleanError) = self.state.withLockedValue {
                    (state: inout HTTPClient.State) -> (ShutdownCallback, Error?) in
                    guard case .shuttingDown(let requiresClean, callback: let callback) = state else {
                        preconditionFailure("Why did the pool manager shut down, if it was not instructed to")
                    }

                    let error: Error? = (requiresClean && unclean) ? HTTPClientError.uncleanShutdown : nil
                    state = .shutDown
                    return (callback, error)
                }
                queue.async {
                    callback(uncleanError)
                }
            }
        }
    }

    @Sendable
    private func makeOrGetFileIOThreadPool() -> NIOThreadPool {
        self.fileIOThreadPool.withLockedValue { pool in
            guard let pool else {
                return NIOThreadPool.singleton
            }
            return pool
        }
    }

    /// Execute `GET` request using specified URL.
    ///
    /// - parameters:
    ///     - url: Remote URL.
    ///     - deadline: Point in time by which the request must complete.
    public func get(url: String, deadline: NIODeadline? = nil) -> EventLoopFuture<Response> {
        self.get(url: url, deadline: deadline, logger: HTTPClient.loggingDisabled)
    }

    /// Execute `GET` request using specified URL.
    ///
    /// - parameters:
    ///     - url: Remote URL.
    ///     - deadline: Point in time by which the request must complete.
    ///     - logger: The logger to use for this request.
    public func get(url: String, deadline: NIODeadline? = nil, logger: Logger) -> EventLoopFuture<Response> {
        self.execute(.GET, url: url, deadline: deadline, logger: logger)
    }

    /// Execute `POST` request using specified URL.
    ///
    /// - parameters:
    ///     - url: Remote URL.
    ///     - body: Request body.
    ///     - deadline: Point in time by which the request must complete.
    public func post(url: String, body: Body? = nil, deadline: NIODeadline? = nil) -> EventLoopFuture<Response> {
        self.post(url: url, body: body, deadline: deadline, logger: HTTPClient.loggingDisabled)
    }

    /// Execute `POST` request using specified URL.
    ///
    /// - parameters:
    ///     - url: Remote URL.
    ///     - body: Request body.
    ///     - deadline: Point in time by which the request must complete.
    ///     - logger: The logger to use for this request.
    public func post(
        url: String,
        body: Body? = nil,
        deadline: NIODeadline? = nil,
        logger: Logger
    ) -> EventLoopFuture<Response> {
        self.execute(.POST, url: url, body: body, deadline: deadline, logger: logger)
    }

    /// Execute `PATCH` request using specified URL.
    ///
    /// - parameters:
    ///     - url: Remote URL.
    ///     - body: Request body.
    ///     - deadline: Point in time by which the request must complete.
    public func patch(url: String, body: Body? = nil, deadline: NIODeadline? = nil) -> EventLoopFuture<Response> {
        self.patch(url: url, body: body, deadline: deadline, logger: HTTPClient.loggingDisabled)
    }

    /// Execute `PATCH` request using specified URL.
    ///
    /// - parameters:
    ///     - url: Remote URL.
    ///     - body: Request body.
    ///     - deadline: Point in time by which the request must complete.
    ///     - logger: The logger to use for this request.
    public func patch(
        url: String,
        body: Body? = nil,
        deadline: NIODeadline? = nil,
        logger: Logger
    ) -> EventLoopFuture<Response> {
        self.execute(.PATCH, url: url, body: body, deadline: deadline, logger: logger)
    }

    /// Execute `PUT` request using specified URL.
    ///
    /// - parameters:
    ///     - url: Remote URL.
    ///     - body: Request body.
    ///     - deadline: Point in time by which the request must complete.
    public func put(url: String, body: Body? = nil, deadline: NIODeadline? = nil) -> EventLoopFuture<Response> {
        self.put(url: url, body: body, deadline: deadline, logger: HTTPClient.loggingDisabled)
    }

    /// Execute `PUT` request using specified URL.
    ///
    /// - parameters:
    ///     - url: Remote URL.
    ///     - body: Request body.
    ///     - deadline: Point in time by which the request must complete.
    ///     - logger: The logger to use for this request.
    public func put(
        url: String,
        body: Body? = nil,
        deadline: NIODeadline? = nil,
        logger: Logger
    ) -> EventLoopFuture<Response> {
        self.execute(.PUT, url: url, body: body, deadline: deadline, logger: logger)
    }

    /// Execute `DELETE` request using specified URL.
    ///
    /// - parameters:
    ///     - url: Remote URL.
    ///     - deadline: The time when the request must have been completed by.
    public func delete(url: String, deadline: NIODeadline? = nil) -> EventLoopFuture<Response> {
        self.delete(url: url, deadline: deadline, logger: HTTPClient.loggingDisabled)
    }

    /// Execute `DELETE` request using specified URL.
    ///
    /// - parameters:
    ///     - url: Remote URL.
    ///     - deadline: The time when the request must have been completed by.
    ///     - logger: The logger to use for this request.
    public func delete(url: String, deadline: NIODeadline? = nil, logger: Logger) -> EventLoopFuture<Response> {
        self.execute(.DELETE, url: url, deadline: deadline, logger: logger)
    }

    /// Execute arbitrary HTTP request using specified URL.
    ///
    /// - parameters:
    ///     - method: Request method.
    ///     - url: Request url.
    ///     - body: Request body.
    ///     - deadline: Point in time by which the request must complete.
    ///     - logger: The logger to use for this request.
    public func execute(
        _ method: HTTPMethod = .GET,
        url: String,
        body: Body? = nil,
        deadline: NIODeadline? = nil,
        logger: Logger? = nil
    ) -> EventLoopFuture<Response> {
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
    public func execute(
        _ method: HTTPMethod = .GET,
        socketPath: String,
        urlPath: String,
        body: Body? = nil,
        deadline: NIODeadline? = nil,
        logger: Logger? = nil
    ) -> EventLoopFuture<Response> {
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
    public func execute(
        _ method: HTTPMethod = .GET,
        secureSocketPath: String,
        urlPath: String,
        body: Body? = nil,
        deadline: NIODeadline? = nil,
        logger: Logger? = nil
    ) -> EventLoopFuture<Response> {
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
        self.execute(request: request, deadline: deadline, logger: HTTPClient.loggingDisabled)
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
    public func execute(
        request: Request,
        eventLoop: EventLoopPreference,
        deadline: NIODeadline? = nil
    ) -> EventLoopFuture<Response> {
        self.execute(
            request: request,
            eventLoop: eventLoop,
            deadline: deadline,
            logger: HTTPClient.loggingDisabled
        )
    }

    /// Execute arbitrary HTTP request and handle response processing using provided delegate.
    ///
    /// - parameters:
    ///     - request: HTTP request to execute.
    ///     - eventLoopPreference: NIO Event Loop preference.
    ///     - deadline: Point in time by which the request must complete.
    ///     - logger: The logger to use for this request.
    public func execute(
        request: Request,
        eventLoop eventLoopPreference: EventLoopPreference,
        deadline: NIODeadline? = nil,
        logger: Logger?
    ) -> EventLoopFuture<Response> {
        let accumulator = ResponseAccumulator(request: request)
        return self.execute(
            request: request,
            delegate: accumulator,
            eventLoop: eventLoopPreference,
            deadline: deadline,
            logger: logger
        ).futureResult
    }

    /// Execute arbitrary HTTP request and handle response processing using provided delegate.
    ///
    /// - parameters:
    ///     - request: HTTP request to execute.
    ///     - delegate: Delegate to process response parts.
    ///     - deadline: Point in time by which the request must complete.
    public func execute<Delegate: HTTPClientResponseDelegate>(
        request: Request,
        delegate: Delegate,
        deadline: NIODeadline? = nil
    ) -> Task<Delegate.Response> {
        self.execute(request: request, delegate: delegate, deadline: deadline, logger: HTTPClient.loggingDisabled)
    }

    /// Execute arbitrary HTTP request and handle response processing using provided delegate.
    ///
    /// - parameters:
    ///     - request: HTTP request to execute.
    ///     - delegate: Delegate to process response parts.
    ///     - deadline: Point in time by which the request must complete.
    ///     - logger: The logger to use for this request.
    public func execute<Delegate: HTTPClientResponseDelegate>(
        request: Request,
        delegate: Delegate,
        deadline: NIODeadline? = nil,
        logger: Logger
    ) -> Task<Delegate.Response> {
        self.execute(request: request, delegate: delegate, eventLoop: .indifferent, deadline: deadline, logger: logger)
    }

    /// Execute arbitrary HTTP request and handle response processing using provided delegate.
    ///
    /// - parameters:
    ///     - request: HTTP request to execute.
    ///     - delegate: Delegate to process response parts.
    ///     - eventLoopPreference: NIO Event Loop preference.
    ///     - deadline: Point in time by which the request must complete.
    public func execute<Delegate: HTTPClientResponseDelegate>(
        request: Request,
        delegate: Delegate,
        eventLoop eventLoopPreference: EventLoopPreference,
        deadline: NIODeadline? = nil
    ) -> Task<Delegate.Response> {
        self.execute(
            request: request,
            delegate: delegate,
            eventLoop: eventLoopPreference,
            deadline: deadline,
            logger: HTTPClient.loggingDisabled
        )
    }

    /// Execute arbitrary HTTP request and handle response processing using provided delegate.
    ///
    /// - parameters:
    ///     - request: HTTP request to execute.
    ///     - delegate: Delegate to process response parts.
    ///     - eventLoopPreference: NIO Event Loop preference.
    ///     - deadline: Point in time by which the request must complete.
    ///     - logger: The logger to use for this request.
    public func execute<Delegate: HTTPClientResponseDelegate>(
        request: Request,
        delegate: Delegate,
        eventLoop eventLoopPreference: EventLoopPreference,
        deadline: NIODeadline? = nil,
        logger: Logger?
    ) -> Task<Delegate.Response> {
        self._execute(
            request: request,
            delegate: delegate,
            eventLoop: eventLoopPreference,
            deadline: deadline,
            logger: logger,
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
        let logger = (originalLogger ?? HTTPClient.loggingDisabled).attachingRequestInformation(
            request,
            requestID: globalRequestID.wrappingIncrementThenLoad(ordering: .relaxed)
        )

        let taskEL: EventLoop
        switch eventLoopPreference.preference {
        case .indifferent:
            // if possible we want a connection on the current `EventLoop`
            taskEL = self.eventLoopGroup.any()
        case .delegate(on: let eventLoop):
            precondition(
                self.eventLoopGroup.makeIterator().contains { $0 === eventLoop },
                "Provided EventLoop must be part of clients EventLoopGroup."
            )
            taskEL = eventLoop
        case .delegateAndChannel(on: let eventLoop):
            precondition(
                self.eventLoopGroup.makeIterator().contains { $0 === eventLoop },
                "Provided EventLoop must be part of clients EventLoopGroup."
            )
            taskEL = eventLoop
        case .testOnly_exact(_, delegateOn: let delegateEL):
            taskEL = delegateEL
        }

        logger.trace(
            "selected EventLoop for task given the preference",
            metadata: [
                "ahc-eventloop": "\(taskEL)",
                "ahc-el-preference": "\(eventLoopPreference)",
            ]
        )

        let failedTask: Task<Delegate.Response>? = self.state.withLockedValue { state -> (Task<Delegate.Response>?) in
            switch state {
            case .upAndRunning:
                return nil
            case .shuttingDown, .shutDown:
                logger.debug("client is shutting down, failing request")
                return Task<Delegate.Response>.failedTask(
                    eventLoop: taskEL,
                    error: HTTPClientError.alreadyShutdown,
                    logger: logger,
                    tracing: tracing,
                    makeOrGetFileIOThreadPool: self.makeOrGetFileIOThreadPool
                )
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

        let task: HTTPClient.Task<Delegate.Response> =
            Task<Delegate.Response>(
                eventLoop: taskEL,
                logger: logger,
                tracing: self.tracing,
                makeOrGetFileIOThreadPool: self.makeOrGetFileIOThreadPool
            )

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

            if let deadline = deadline {
                let deadlineSchedule = taskEL.scheduleTask(deadline: deadline) {
                    requestBag.deadlineExceeded()
                }

                task.promise.futureResult.whenComplete { _ in
                    deadlineSchedule.cancel()
                }
            }

            self.poolManager.executeRequest(requestBag)
        } catch {
            delegate.didReceiveError(task: task, error)
            task.failInternal(with: error)
        }

        return task
    }

    /// ``HTTPClient`` configuration.
    public struct Configuration {
        /// TLS configuration, defaults to `TLSConfiguration.makeClientConfiguration()`.
        public var tlsConfiguration: Optional<TLSConfiguration>

        /// Sometimes it can be useful to connect to one host e.g. `x.example.com` but
        /// request and validate the certificate chain as if we would connect to `y.example.com`.
        /// ``dnsOverride`` allows to do just that by mapping host names which we will request and validate the certificate chain, to a different
        /// host name which will be used to actually connect to.
        ///
        /// **Example:** if ``dnsOverride`` is set  to `["example.com": "localhost"]` and we execute a request with a
        /// `url` of `https://example.com/`, the ``HTTPClient`` will actually open a connection to `localhost` instead of `example.com`.
        /// ``HTTPClient`` will still request certificates from the server for `example.com` and validate them as if we would connect to `example.com`.
        public var dnsOverride: [String: String] = [:]

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
        @available(
            *,
            deprecated,
            message:
                "AsyncHTTPClient now correctly supports handling unexpected SSL connection drops. This property is ignored"
        )
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

        /// The maximum number of times each connection can be used before it is replaced with a new one. Use `nil` (the default)
        /// if no limit should be applied to each connection.
        ///
        /// - Precondition: The value must be greater than zero.
        public var maximumUsesPerConnection: Int? {
            willSet {
                if let newValue = newValue, newValue <= 0 {
                    fatalError("maximumUsesPerConnection must be greater than zero or nil")
                }
            }
        }

        /// Whether ``HTTPClient`` will use Multipath TCP or not
        /// By default, don't use it
        public var enableMultipath: Bool

        /// A method with access to the HTTP/1 connection channel that is called when creating the connection.
        public var http1_1ConnectionDebugInitializer: (@Sendable (Channel) -> EventLoopFuture<Void>)?

        /// A method with access to the HTTP/2 connection channel that is called when creating the connection.
        public var http2ConnectionDebugInitializer: (@Sendable (Channel) -> EventLoopFuture<Void>)?

        /// A method with access to the HTTP/2 stream channel that is called when creating the stream.
        public var http2StreamChannelDebugInitializer: (@Sendable (Channel) -> EventLoopFuture<Void>)?

        /// Configuration how distributed traces are created and handled.
        public var tracing: TracingConfiguration = .init()

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
            self.enableMultipath = false
        }

        public init(
            tlsConfiguration: TLSConfiguration? = nil,
            redirectConfiguration: RedirectConfiguration? = nil,
            timeout: Timeout = Timeout(),
            proxy: Proxy? = nil,
            ignoreUncleanSSLShutdown: Bool = false,
            decompression: Decompression = .disabled
        ) {
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

        public init(
            certificateVerification: CertificateVerification,
            redirectConfiguration: RedirectConfiguration? = nil,
            timeout: Timeout = Timeout(),
            maximumAllowedIdleTimeInConnectionPool: TimeAmount = .seconds(60),
            proxy: Proxy? = nil,
            ignoreUncleanSSLShutdown: Bool = false,
            decompression: Decompression = .disabled
        ) {
            var tlsConfig = TLSConfiguration.makeClientConfiguration()
            tlsConfig.certificateVerification = certificateVerification
            self.init(
                tlsConfiguration: tlsConfig,
                redirectConfiguration: redirectConfiguration,
                timeout: timeout,
                connectionPool: ConnectionPool(idleTimeout: maximumAllowedIdleTimeInConnectionPool),
                proxy: proxy,
                ignoreUncleanSSLShutdown: ignoreUncleanSSLShutdown,
                decompression: decompression
            )
        }

        public init(
            certificateVerification: CertificateVerification,
            redirectConfiguration: RedirectConfiguration? = nil,
            timeout: Timeout = Timeout(),
            connectionPool: TimeAmount = .seconds(60),
            proxy: Proxy? = nil,
            ignoreUncleanSSLShutdown: Bool = false,
            decompression: Decompression = .disabled,
            backgroundActivityLogger: Logger?
        ) {
            var tlsConfig = TLSConfiguration.makeClientConfiguration()
            tlsConfig.certificateVerification = certificateVerification
            self.init(
                tlsConfiguration: tlsConfig,
                redirectConfiguration: redirectConfiguration,
                timeout: timeout,
                connectionPool: ConnectionPool(idleTimeout: connectionPool),
                proxy: proxy,
                ignoreUncleanSSLShutdown: ignoreUncleanSSLShutdown,
                decompression: decompression
            )
        }

        public init(
            certificateVerification: CertificateVerification,
            redirectConfiguration: RedirectConfiguration? = nil,
            timeout: Timeout = Timeout(),
            proxy: Proxy? = nil,
            ignoreUncleanSSLShutdown: Bool = false,
            decompression: Decompression = .disabled
        ) {
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

        public init(
            tlsConfiguration: TLSConfiguration? = nil,
            redirectConfiguration: RedirectConfiguration? = nil,
            timeout: Timeout = Timeout(),
            connectionPool: ConnectionPool = ConnectionPool(),
            proxy: Proxy? = nil,
            ignoreUncleanSSLShutdown: Bool = false,
            decompression: Decompression = .disabled,
            http1_1ConnectionDebugInitializer: (@Sendable (Channel) -> EventLoopFuture<Void>)? = nil,
            http2ConnectionDebugInitializer: (@Sendable (Channel) -> EventLoopFuture<Void>)? = nil,
            http2StreamChannelDebugInitializer: (@Sendable (Channel) -> EventLoopFuture<Void>)? = nil
        ) {
            self.init(
                tlsConfiguration: tlsConfiguration,
                redirectConfiguration: redirectConfiguration,
                timeout: timeout,
                connectionPool: connectionPool,
                proxy: proxy,
                ignoreUncleanSSLShutdown: ignoreUncleanSSLShutdown,
                decompression: decompression
            )
            self.http1_1ConnectionDebugInitializer = http1_1ConnectionDebugInitializer
            self.http2ConnectionDebugInitializer = http2ConnectionDebugInitializer
            self.http2StreamChannelDebugInitializer = http2StreamChannelDebugInitializer
        }

        public init(
            tlsConfiguration: TLSConfiguration? = nil,
            redirectConfiguration: RedirectConfiguration? = nil,
            timeout: Timeout = Timeout(),
            connectionPool: ConnectionPool = ConnectionPool(),
            proxy: Proxy? = nil,
            ignoreUncleanSSLShutdown: Bool = false,
            decompression: Decompression = .disabled,
            http1_1ConnectionDebugInitializer: (@Sendable (Channel) -> EventLoopFuture<Void>)? = nil,
            http2ConnectionDebugInitializer: (@Sendable (Channel) -> EventLoopFuture<Void>)? = nil,
            http2StreamChannelDebugInitializer: (@Sendable (Channel) -> EventLoopFuture<Void>)? = nil,
            tracing: TracingConfiguration = .init()
        ) {
            self.init(
                tlsConfiguration: tlsConfiguration,
                redirectConfiguration: redirectConfiguration,
                timeout: timeout,
                connectionPool: connectionPool,
                proxy: proxy,
                ignoreUncleanSSLShutdown: ignoreUncleanSSLShutdown,
                decompression: decompression
            )
            self.http1_1ConnectionDebugInitializer = http1_1ConnectionDebugInitializer
            self.http2ConnectionDebugInitializer = http2ConnectionDebugInitializer
            self.http2StreamChannelDebugInitializer = http2StreamChannelDebugInitializer
            self.tracing = tracing
        }
    }

    public struct TracingConfiguration: Sendable {

        @usableFromInline
        var _tracer: Optional<any Sendable>  // erasure trick so we don't have to make Configuration @available

        /// Tracer that should be used by the HTTPClient.
        ///
        /// This is selected at configuration creation time, and if no tracer is passed explicitly,
        /// (including `nil` in order to disable traces), the default global bootstrapped tracer will
        /// be stored in this property, and used for all subsequent requests made by this client.
        @inlinable
        @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
        public var tracer: (any Tracer)? {
            get {
                guard let _tracer else {
                    return nil
                }
                return _tracer as! (any Tracer)?
            }
            set {
                self._tracer = newValue
            }
        }

        // TODO: Open up customization of keys we use?
        /// Configuration for tracing attributes set by the HTTPClient.
        @usableFromInline
        package var attributeKeys: AttributeKeys

        public init() {
            if #available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *) {
                self._tracer = InstrumentationSystem.tracer
            } else {
                self._tracer = nil
            }
            self.attributeKeys = .init()
        }

        /// Span attribute keys that the HTTPClient should set automatically.
        /// This struct allows the configuration of the attribute names (keys) which will be used for the apropriate values.
        @usableFromInline
        package struct AttributeKeys: Sendable {
            @usableFromInline package var requestMethod: String = "http.request.method"
            @usableFromInline package var requestBodySize: String = "http.request.body.size"

            @usableFromInline package var responseBodySize: String = "http.response.body.size"
            @usableFromInline package var responseStatusCode: String = "http.status_code"

            @usableFromInline package var httpFlavor: String = "http.flavor"

            @usableFromInline package init() {}
        }
    }

    /// Specifies how `EventLoopGroup` will be created and establishes lifecycle ownership.
    public enum EventLoopGroupProvider {
        /// `EventLoopGroup` will be provided by the user. Owner of this group is responsible for its lifecycle.
        case shared(EventLoopGroup)
        /// The original intention of this was that ``HTTPClient`` would create and own its own `EventLoopGroup` to
        /// facilitate use in programs that are not already using SwiftNIO.
        /// Since https://github.com/apple/swift-nio/pull/2471 however, SwiftNIO does provide a global, shared singleton
        /// `EventLoopGroup`s that we can use. ``HTTPClient`` is no longer able to create & own its own
        /// `EventLoopGroup` which solves a whole host of issues around shutdown.
        @available(*, deprecated, renamed: "singleton", message: "Please use the singleton EventLoopGroup explicitly")
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
            EventLoopPreference(.delegate(on: eventLoop))
        }

        /// The delegate and the `Channel` will be run on the specified EventLoop.
        ///
        /// Use this for use-cases where you prefer a new connection to be established over re-using an existing
        /// connection that might be on a different `EventLoop`.
        public static func delegateAndChannel(on eventLoop: EventLoop) -> EventLoopPreference {
            EventLoopPreference(.delegateAndChannel(on: eventLoop))
        }
    }

    /// Specifies decompression settings.
    public enum Decompression: Sendable {
        /// Decompression is disabled.
        case disabled
        /// Decompression is enabled.
        case enabled(limit: NIOHTTPDecompression.DecompressionLimit)
    }

    typealias ShutdownCallback = @Sendable (Error?) -> Void

    enum State {
        case upAndRunning
        case shuttingDown(requiresCleanClose: Bool, callback: ShutdownCallback)
        case shutDown
    }
}

extension HTTPClient.EventLoopGroupProvider {
    /// Shares ``HTTPClient/defaultEventLoopGroup`` which is a singleton `EventLoopGroup` suitable for the platform.
    public static var singleton: Self {
        .shared(HTTPClient.defaultEventLoopGroup)
    }
}

extension HTTPClient {
    /// Returns the default `EventLoopGroup` singleton, automatically selecting the best for the platform.
    ///
    /// This will select the concrete `EventLoopGroup` depending which platform this is running on.
    public static var defaultEventLoopGroup: EventLoopGroup {
        #if canImport(Network)
        if #available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *) {
            return NIOTSEventLoopGroup.singleton
        } else {
            return MultiThreadedEventLoopGroup.singleton
        }
        #else
        return MultiThreadedEventLoopGroup.singleton
        #endif
    }
}

extension HTTPClient.Configuration: Sendable {}

extension HTTPClient.EventLoopGroupProvider: Sendable {}
extension HTTPClient.EventLoopPreference: Sendable {}

extension HTTPClient.Configuration {
    /// Timeout configuration.
    public struct Timeout: Sendable {
        /// Specifies connect timeout. If no connect timeout is given, a default 10 seconds timeout will be applied.
        public var connect: TimeAmount?
        /// Specifies read timeout.
        public var read: TimeAmount?
        /// Specifies the maximum amount of time without bytes being written by the client before closing the connection.
        public var write: TimeAmount?

        /// Internal connection creation timeout. Defaults the connect timeout to always contain a value.
        var connectionCreationTimeout: TimeAmount {
            self.connect ?? .seconds(10)
        }

        /// Create timeout.
        ///
        /// - parameters:
        ///     - connect: `connect` timeout. Will default to 10 seconds, if no value is provided.
        ///     - read: `read` timeout.
        public init(
            connect: TimeAmount? = nil,
            read: TimeAmount? = nil
        ) {
            self.connect = connect
            self.read = read
        }

        /// Create timeout.
        ///
        /// - parameters:
        ///     - connect: `connect` timeout. Will default to 10 seconds, if no value is provided.
        ///     - read: `read` timeout.
        ///     - write: `write` timeout.
        public init(
            connect: TimeAmount? = nil,
            read: TimeAmount? = nil,
            write: TimeAmount
        ) {
            self.connect = connect
            self.read = read
            self.write = write
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
        public static func follow(max: Int, allowCycles: Bool) -> RedirectConfiguration {
            .init(configuration: .follow(max: max, allowCycles: allowCycles))
        }
    }

    /// Connection pool configuration.
    public struct ConnectionPool: Hashable, Sendable {
        /// Specifies amount of time connections are kept idle in the pool. After this time has passed without a new
        /// request the connections are closed.
        public var idleTimeout: TimeAmount = .seconds(60)

        /// The maximum number of connections that are kept alive in the connection pool per host. If requests with
        /// an explicit eventLoopRequirement are sent, this number might be exceeded due to overflow connections.
        public var concurrentHTTP1ConnectionsPerHostSoftLimit: Int = 8

        /// If true, ``HTTPClient`` will try to create new connections on connection failure with an exponential backoff.
        /// Requests will only fail after the ``HTTPClient/Configuration/Timeout-swift.struct/connect`` timeout exceeded.
        /// If false, all requests that have no assigned connection will fail immediately after a connection could not be established.
        /// Defaults to `true`.
        /// - warning: We highly recommend leaving this on.
        /// It is very common that connections establishment is flaky at scale.
        /// ``HTTPClient`` will automatically mitigate these kind of issues if this flag is turned on.
        public var retryConnectionEstablishment: Bool = true

        /// The number of pre-warmed HTTP/1 connections to maintain.
        ///
        /// When set to a number greater than zero, any HTTP/1 connection pool created will attempt to maintain
        /// at least this number of "extra" idle connections, above the connections currently in use, up to the
        /// limit of ``concurrentHTTP1ConnectionsPerHostSoftLimit``.
        ///
        /// These connections will not be made while the pool is idle: only once the first connection is made
        /// to a host will the others be opened. In addition, to manage the connection creation rate and
        /// avoid flooding servers, prewarmed connection creation will be done one-at-a-time.
        public var preWarmedHTTP1ConnectionCount: Int = 0

        public init() {}

        public init(idleTimeout: TimeAmount) {
            self.idleTimeout = idleTimeout
        }

        public init(idleTimeout: TimeAmount, concurrentHTTP1ConnectionsPerHostSoftLimit: Int) {
            self.idleTimeout = idleTimeout
            self.concurrentHTTP1ConnectionsPerHostSoftLimit = concurrentHTTP1ConnectionsPerHostSoftLimit
        }
    }

    public struct HTTPVersion: Sendable, Hashable {
        enum Configuration {
            case http1Only
            case automatic
        }

        /// We will only use HTTP/1, even if the server would supports HTTP/2
        public static let http1Only: Self = .init(configuration: .http1Only)

        /// HTTP/2 is used if we connect to a server with HTTPS and the server supports HTTP/2, otherwise we use HTTP/1
        public static let automatic: Self = .init(configuration: .automatic)

        var configuration: Configuration
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
        case writeTimeout
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
        case invalidHeaderFieldValues([String])
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
        case shutdownUnsupported
    }

    private var code: Code

    private init(code: Code) {
        self.code = code
    }

    public var description: String {
        "HTTPClientError.\(String(describing: self.code))"
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
        case .writeTimeout:
            return "Write timeout"
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
        case .invalidHeaderFieldValues:
            return "Invalid header field values"
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
        case .shutdownUnsupported:
            return "The global singleton HTTP client cannot be shut down"
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
    public static func unsupportedScheme(_ scheme: String) -> HTTPClientError {
        HTTPClientError(code: .unsupportedScheme(scheme))
    }
    /// Request timed out while waiting for response.
    public static let readTimeout = HTTPClientError(code: .readTimeout)
    /// Request timed out.
    public static let writeTimeout = HTTPClientError(code: .writeTimeout)
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
    public static func invalidHeaderFieldNames(_ names: [String]) -> HTTPClientError {
        HTTPClientError(code: .invalidHeaderFieldNames(names))
    }
    /// Header field values contain invalid characters.
    public static func invalidHeaderFieldValues(_ values: [String]) -> HTTPClientError {
        HTTPClientError(code: .invalidHeaderFieldValues(values))
    }
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
        HTTPClientError(code: .serverOfferedUnsupportedApplicationProtocol(proto))
    }

    /// The globally shared singleton ``HTTPClient`` cannot be shut down.
    public static var shutdownUnsupported: HTTPClientError {
        HTTPClientError(code: .shutdownUnsupported)
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

    @available(
        *,
        deprecated,
        message:
            "AsyncHTTPClient now correctly supports informational headers. For this reason `httpEndReceivedAfterHeadWith1xx` will not be thrown anymore."
    )
    public static let httpEndReceivedAfterHeadWith1xx = HTTPClientError(code: .httpEndReceivedAfterHeadWith1xx)
}
