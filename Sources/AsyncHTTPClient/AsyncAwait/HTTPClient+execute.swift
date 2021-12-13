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

#if compiler(>=5.5) && canImport(_Concurrency)
import struct Foundation.URL
import Logging
import NIOCore

@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
extension HTTPClient {
    /// Execute arbitrary HTTP requests.
    ///
    /// - Parameters:
    ///   - request: HTTP request to execute.
    ///   - deadline: Point in time by which the request must complete.
    ///   - logger: The logger to use for this request.
    /// - Returns: The response to the request. Note that the `body` of the response may not yet have been fully received.
    func execute(
        _ request: HTTPClientRequest,
        deadline: NIODeadline,
        logger: Logger
    ) async throws -> HTTPClientResponse {
        try await self.executeAndFollowRedirectsIfNeeded(
            request,
            deadline: deadline,
            logger: logger,
            redirectState: RedirectState(self.configuration.redirectConfiguration.mode, initialURL: request.url)
        )
    }
}

@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
extension HTTPClient {
    private func executeAndFollowRedirectsIfNeeded(
        _ request: HTTPClientRequest,
        deadline: NIODeadline,
        logger: Logger,
        redirectState: RedirectState?
    ) async throws -> HTTPClientResponse {
        let preparedRequest = try HTTPClientRequest.Prepared(request)
        let response = try await execute(request, deadline: deadline, logger: logger)
        guard
            preparedRequest.body.canBeConsumedMultipleTimes,
            let redirectState = redirectState,
            let redirectURL = response.headers.extractRedirectTarget(
                status: response.status,
                originalURL: preparedRequest.url,
                originalScheme: preparedRequest.poolKey.scheme
            )
        else {
            return response
        }

        return try await self.followRedirect(
            redirectURL: redirectURL,
            redirectState: redirectState,
            request: preparedRequest,
            response: response,
            deadline: deadline,
            logger: logger
        )
    }

    private func followRedirect(
        redirectURL: URL,
        redirectState: RedirectState,
        request: HTTPClientRequest.Prepared,
        response: HTTPClientResponse,
        deadline: NIODeadline,
        logger: Logger
    ) async throws -> HTTPClientResponse {
        var redirectState = redirectState
        try redirectState.redirect(to: redirectURL.absoluteString)
        let (method, headers, body) = transformRequestForRedirect(
            from: request.url,
            method: request.head.method,
            headers: request.head.headers,
            body: request.body,
            to: redirectURL,
            status: response.status
        )
        var newRequest = HTTPClientRequest(url: redirectURL.absoluteString)
        newRequest.method = method
        newRequest.headers = headers
        newRequest.body = body
        return try await self.executeAndFollowRedirectsIfNeeded(
            newRequest,
            deadline: deadline,
            logger: logger,
            redirectState: redirectState
        )
    }

    private func executeWithoutFollowingRedirects(
        _ request: HTTPClientRequest.Prepared,
        deadline: NIODeadline,
        logger: Logger
    ) async throws -> HTTPClientResponse {
        /// There is currently no good way to asynchronously cancel an object that is initiated inside the `body` closure of `with*Continuation`.
        /// As a workaround we use `TransactionCancelHandler` which will take care of the race between instantiation of `Transaction`
        /// in the `body` closure and cancelation from the `onCancel` closure  of `with*Continuation`.
        actor TransactionCancelHandler {
            private enum State {
                case initialised
                case register(Transaction)
                case cancelled
            }

            private var state: State = .initialised

            init() {}

            func registerTransaction(_ transaction: Transaction) {
                switch self.state {
                case .initialised:
                    self.state = .register(transaction)
                case .cancelled:
                    transaction.cancel()
                case .register:
                    preconditionFailure("transaction already set")
                }
            }

            func cancel() {
                switch self.state {
                case .register(let bag):
                    self.state = .cancelled
                    bag.cancel()
                case .cancelled:
                    break
                case .initialised:
                    self.state = .cancelled
                }
            }
        }

        let cancelHandler = TransactionCancelHandler()

        return try await withTaskCancellationHandler(operation: { () async throws -> HTTPClientResponse in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPClientResponse, Swift.Error>) -> Void in
                let transaction = Transaction(
                    request: request,
                    requestOptions: .init(idleReadTimeout: nil),
                    logger: logger,
                    connectionDeadline: deadline,
                    preferredEventLoop: self.eventLoopGroup.next(),
                    responseContinuation: continuation
                )

                _Concurrency.Task {
                    await cancelHandler.registerTransaction(transaction)
                }

                self.poolManager.executeRequest(transaction)
            }
        }, onCancel: {
            _Concurrency.Task {
                await cancelHandler.cancel()
            }
        })
    }
}

#endif
