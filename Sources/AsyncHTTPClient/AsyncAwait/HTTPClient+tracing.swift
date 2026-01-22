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
import OTelSemanticConventions
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
            span.attributes.http.request.method = .init(rawValue: request.method.rawValue)

            // set request headers
            for header in request.headers {
                span.attributes.http.request.header.set(header.name, to: [header.value])
            }

            // set url attributes
            if let deconstructedURL = try? DeconstructedURL(url: request.url) {
                span.attributes.url.path = deconstructedURL.uri
                span.attributes.url.scheme = deconstructedURL.scheme.rawValue
                span.attributes.server.address = deconstructedURL.connectionTarget.host
                span.attributes.server.port = deconstructedURL.connectionTarget.port
            }

            let response = try await body()

            // set response span attributes
            TracingSupport.handleResponseStatusCode(span, response.status)

            for header in response.headers {
                span.attributes.http.response.header.set(header.name, to: [header.value])
            }
            
            // set network protocol version
            span.attributes.network.protocol.version = "\(response.version.major).\(response.version.minor)"

            return response
        }
    }
}
