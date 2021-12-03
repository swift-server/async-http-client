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
import Logging
import NIOCore

@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
extension HTTPClient {
    func execute(_ request: HTTPClientRequest, deadline: NIODeadline, logger: Logger) async throws -> HTTPClientResponse {
        actor SwiftCancellationHandlingIs🤔 {
            enum State {
                case initialized
                case register(AsyncRequestBag)
                case cancelled
            }

            private var state: State = .initialized

            init() {}

            func registerRequestBag(_ bag: AsyncRequestBag) {
                switch self.state {
                case .initialized:
                    self.state = .register(bag)
                case .cancelled:
                    bag.cancel()
                case .register:
                    preconditionFailure()
                }
            }

            func cancel() {
                switch self.state {
                case .register(let bag):
                    self.state = .cancelled
                    bag.cancel()
                case .cancelled:
                    break
                case .initialized:
                    self.state = .cancelled
                }
            }
        }
        let preparedRequest = try HTTPClientRequest.Prepared(request)

        let cancelHandler = SwiftCancellationHandlingIs🤔()

        return try await withTaskCancellationHandler(operation: { () async throws -> HTTPClientResponse in
            try await withUnsafeThrowingContinuation {
                (continuation: UnsafeContinuation<HTTPClientResponse, Swift.Error>) -> Void in
                let bag = AsyncRequestBag(
                    request: preparedRequest,
                    requestOptions: .init(idleReadTimeout: nil),
                    logger: logger,
                    connectionDeadline: .now() + .seconds(10),
                    preferredEventLoop: self.eventLoopGroup.next(),
                    responseContinuation: continuation
                )

                _Concurrency.Task {
                    await cancelHandler.registerRequestBag(bag)
                }

                self.poolManager.executeRequest(bag)
            }
        }, onCancel: {
            _Concurrency.Task {
                await cancelHandler.cancel()
            }
        })
    }
}

#endif
