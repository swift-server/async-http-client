//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2021 Apple Inc. and the AsyncHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Logging
import NIOCore
import NIOHTTP1
import Tracing

import struct Foundation.URL

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension HTTPClient {
    /// Execute arbitrary HTTP requests.
    ///
    /// - Parameters:
    ///   - request: HTTP request to execute.
    ///   - deadline: Point in time by which the request must complete.
    ///   - logger: The logger to use for this request.
    ///
    /// - warning: This method may violates Structured Concurrency because it returns a `HTTPClientResponse` that needs to be
    ///            streamed by the user. This means the request, the connection and other resources are still alive when the request returns.
    ///
    /// - Returns: The response to the request. Note that the `body` of the response may not yet have been fully received.
    public func execute(
        _ request: HTTPClientRequest,
        deadline: NIODeadline,
        logger: Logger? = nil
    ) async throws -> HTTPClientResponse {
        try await withRequestSpan(request) {
            try await self.executeAndFollowRedirectsIfNeeded(
                request,
                deadline: deadline,
                logger: logger ?? Self.loggingDisabled,
                redirectState: RedirectState(self.configuration.redirectConfiguration.mode, initialURL: request.url)
            )
        }
    }
}

// MARK: Connivence methods

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension HTTPClient {
    /// Execute arbitrary HTTP requests.
    ///
    /// - Parameters:
    ///   - request: HTTP request to execute.
    ///   - timeout: time the the request has to complete.
    ///   - logger: The logger to use for this request.
    ///
    /// - warning: This method may violates Structured Concurrency because it returns a `HTTPClientResponse` that needs to be
    ///            streamed by the user. This means the request, the connection and other resources are still alive when the request returns.
    ///
    /// - Returns: The response to the request. Note that the `body` of the response may not yet have been fully received.
    public func execute(
        _ request: HTTPClientRequest,
        timeout: TimeAmount,
        logger: Logger? = nil
    ) async throws -> HTTPClientResponse {
        try await self.execute(
            request,
            deadline: .now() + timeout,
            logger: logger
        )
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension HTTPClient {
    /// - warning: This method may violates Structured Concurrency because it returns a `HTTPClientResponse` that needs to be
    ///            streamed by the user. This means the request, the connection and other resources are still alive when the request returns.
    private func executeAndFollowRedirectsIfNeeded(
        _ request: HTTPClientRequest,
        deadline: NIODeadline,
        logger: Logger,
        redirectState: RedirectState?
    ) async throws -> HTTPClientResponse {
        var currentRequest = request
        var currentRedirectState = redirectState
        var history: [HTTPClientRequestResponse] = []

        // this loop is there to follow potential redirects
        while true {
            let preparedRequest =
                try HTTPClientRequest.Prepared(
                    currentRequest,
                    dnsOverride: configuration.dnsOverride,
                    tracing: self.configuration.tracing
                )
            let response = try await {
                var response = try await self.executeCancellable(preparedRequest, deadline: deadline, logger: logger)

                history.append(
                    .init(
                        request: currentRequest,
                        responseHead: .init(
                            version: response.version,
                            status: response.status,
                            headers: response.headers
                        )
                    )
                )

                response.history = history

                return response
            }()

            guard var redirectState = currentRedirectState else {
                // a `nil` redirectState means we should not follow redirects
                return response
            }

            guard
                let redirectURL = response.headers.extractRedirectTarget(
                    status: response.status,
                    originalURL: preparedRequest.url,
                    originalScheme: preparedRequest.poolKey.scheme
                )
            else {
                // response does not want a redirect
                return response
            }

            // validate that we do not exceed any limits or are running circles
            try redirectState.redirect(to: redirectURL.absoluteString)
            currentRedirectState = redirectState

            let newRequest = currentRequest.followingRedirect(
                from: preparedRequest.url,
                to: redirectURL,
                status: response.status
            )

            guard newRequest.body.canBeConsumedMultipleTimes else {
                // we already send the request body and it cannot be send again
                return response
            }

            currentRequest = newRequest
        }
    }

    /// - warning: This method may violates Structured Concurrency because it returns a `HTTPClientResponse` that needs to be
    ///            streamed by the user. This means the request, the connection and other resources are still alive when the request returns.
    private func executeCancellable(
        _ request: HTTPClientRequest.Prepared,
        deadline: NIODeadline,
        logger: Logger
    ) async throws -> HTTPClientResponse {
        let cancelHandler = TransactionCancelHandler()

        return try await withTaskCancellationHandler(
            operation: { () async throws -> HTTPClientResponse in
                let eventLoop = self.eventLoopGroup.any()
                let deadlineTask = eventLoop.scheduleTask(deadline: deadline) {
                    cancelHandler.cancel(reason: .deadlineExceeded)
                }
                defer {
                    deadlineTask.cancel()
                }
                return try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<HTTPClientResponse, Swift.Error>) -> Void in
                    let transaction = Transaction(
                        request: request,
                        requestOptions: .fromClientConfiguration(self.configuration),
                        logger: logger,
                        connectionDeadline: .now() + (self.configuration.timeout.connectionCreationTimeout),
                        preferredEventLoop: eventLoop,
                        responseContinuation: continuation
                    )

                    cancelHandler.registerTransaction(transaction)

                    self.poolManager.executeRequest(transaction)
                }
            },
            onCancel: {
                cancelHandler.cancel(reason: .taskCanceled)
            }
        )
    }
}

/// There is currently no good way to asynchronously cancel an object that is initiated inside the `body` closure of `with*Continuation`.
/// As a workaround we use `TransactionCancelHandler` which will take care of the race between instantiation of `Transaction`
/// in the `body` closure and cancelation from the `onCancel` closure  of `withTaskCancellationHandler`.
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
private actor TransactionCancelHandler {
    enum CancelReason {
        /// swift concurrency task was canceled
        case taskCanceled
        /// deadline timeout
        case deadlineExceeded
    }

    private enum State {
        case initialised
        case register(Transaction)
        case cancelled(CancelReason)
    }

    private var state: State = .initialised

    init() {}

    private func cancelTransaction(_ transaction: Transaction, for reason: CancelReason) {
        switch reason {
        case .taskCanceled:
            transaction.cancel()
        case .deadlineExceeded:
            transaction.deadlineExceeded()
        }
    }

    private func _registerTransaction(_ transaction: Transaction) {
        switch self.state {
        case .initialised:
            self.state = .register(transaction)
        case .cancelled(let reason):
            self.cancelTransaction(transaction, for: reason)
        case .register:
            preconditionFailure("transaction already set")
        }
    }

    nonisolated func registerTransaction(_ transaction: Transaction) {
        Task {
            await self._registerTransaction(transaction)
        }
    }

    private func _cancel(reason: CancelReason) {
        switch self.state {
        case .register(let transaction):
            self.state = .cancelled(reason)
            self.cancelTransaction(transaction, for: reason)
        case .cancelled:
            break
        case .initialised:
            self.state = .cancelled(reason)
        }
    }

    nonisolated func cancel(reason: CancelReason) {
        Task {
            await self._cancel(reason: reason)
        }
    }
}
