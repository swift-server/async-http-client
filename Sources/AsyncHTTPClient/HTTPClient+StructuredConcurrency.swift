//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2025 Apple Inc. and the AsyncHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Logging
import NIO

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension HTTPClient {
    /// Start & automatically shut down a new ``HTTPClient``.
    ///
    /// This method allows to start & automatically dispose of a ``HTTPClient`` following the principle of Structured Concurrency.
    /// The ``HTTPClient`` is guaranteed to be shut down upon return, whether `body` throws or not.
    ///
    /// This may be particularly useful if you cannot use the shared singleton (``HTTPClient/shared``).
    public static func withHTTPClient<Return>(
        eventLoopGroup: any EventLoopGroup = HTTPClient.defaultEventLoopGroup,
        configuration: Configuration = Configuration(),
        backgroundActivityLogger: Logger? = nil,
        isolation: isolated (any Actor)? = #isolation,
        _ body: (HTTPClient) async throws -> Return
    ) async throws -> Return {
        let logger = (backgroundActivityLogger ?? HTTPClient.loggingDisabled)
        let httpClient = HTTPClient(
            eventLoopGroup: eventLoopGroup,
            configuration: configuration,
            backgroundActivityLogger: logger
        )
        return try await asyncDo {
            try await body(httpClient)
        } finally: { _ in
            try await httpClient.shutdown()
        }
    }
}
