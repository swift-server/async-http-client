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

import NIOHTTP1
import Tracing

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension HTTPClient {
    @inlinable
    func withRequestSpan(
        _ request: HTTPClientRequest,
        _ body: () async throws -> HTTPClientResponse
    ) async rethrows -> HTTPClientResponse {
        guard let tracer = self.tracer else {
            return try await body()
        }

        return try await tracer.withSpan(request.method.rawValue, ofKind: .client) { span in
            let keys = self.configuration.tracing.attributeKeys
            span.attributes[keys.requestMethod] = request.method.rawValue
            // TODO: set more attributes on the span
            let response = try await body()

            // set response span attributes
            TracingSupport.handleResponseStatusCode(span, response.status, keys: tracing.attributeKeys)

            return response
        }
    }
}
