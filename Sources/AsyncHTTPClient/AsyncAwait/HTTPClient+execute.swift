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
import NIOHTTP1

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
        var currentRequest = request
        var currentRedirectState = redirectState

        // this loop is there to follow potential redirects
        while true {
            let preparedRequest = try HTTPClientRequest.Prepared(currentRequest)
            let response = try await executeCancellable(preparedRequest, deadline: deadline, logger: logger)

            guard var redirectState = currentRedirectState else {
                // a `nil` redirectState means we should not follow redirects
                return response
            }

            guard let redirectURL = response.headers.extractRedirectTarget(
                status: response.status,
                originalURL: preparedRequest.url,
                originalScheme: preparedRequest.poolKey.scheme
            ) else {
                // response does not want a redirect
                return response
            }

            // validate that we do not exceed any limits or are running circles
            try redirectState.redirect(to: redirectURL.absoluteString)
            currentRedirectState = redirectState

            let newRequest = preparedRequest.followingRedirect(to: redirectURL, status: response.status)

            guard newRequest.body.canBeConsumedMultipleTimes else {
                // we already send the request body and it cannot be send again
                return response
            }

            currentRequest = newRequest
        }
    }

    private func executeCancellable(
        _ request: HTTPClientRequest.Prepared,
        deadline: NIODeadline,
        logger: Logger
    ) async throws -> HTTPClientResponse {
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

                // `HTTPClient.Task` conflicts with Swift Concurrency Task and `Swift.Task` doesn't work
                _Concurrency.Task {
                    await cancelHandler.registerTransaction(transaction)
                }

                self.poolManager.executeRequest(transaction)
            }
        }, onCancel: {
            cancelHandler.cancel()
        })
    }
}

/// There is currently no good way to asynchronously cancel an object that is initiated inside the `body` closure of `with*Continuation`.
/// As a workaround we use `TransactionCancelHandler` which will take care of the race between instantiation of `Transaction`
/// in the `body` closure and cancelation from the `onCancel` closure  of `with*Continuation`.
@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
private actor TransactionCancelHandler {
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

    func _cancel() {
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

    nonisolated func cancel() {
        Task {
            await self._cancel()
        }
    }
}

#endif
