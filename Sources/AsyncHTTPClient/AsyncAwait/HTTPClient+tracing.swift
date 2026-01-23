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
import struct Foundation.URL

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

            // set explicitly allowed request headers
            let allowedRequestHeaderNames = Set(request.headers.map(\.name)).intersection(configuration.tracing.allowedHeaders)

            for headerName in allowedRequestHeaderNames {
                let values = request.headers[headerName]

                if !values.isEmpty {
                    span.attributes.http.request.header.set(headerName, to: values)
                }
            }

            // set url attributes
            if let url = URL(string: request.url) {
                span.attributes.url.path = TracingSupport.sanitizePath(
                    url.path,
                    redactionComponents: self.configuration.tracing.sensitivePathComponents
                )

                if let scheme = url.scheme {
                    span.attributes.url.scheme = scheme
                }
                if let query = url.query {
                    span.attributes.url.query = TracingSupport.sanitizeQuery(
                        query,
                        redactionComponents: self.configuration.tracing.sensitiveQueryComponents
                    )
                }
                if let fragment = url.fragment {
                    span.attributes.url.fragment = fragment
                }
                if let host = url.host {
                    span.attributes.server.address = host
                }
                if let port = url.port {
                    span.attributes.server.port = port
                }
            }

            let response = try await body()

            // set response span attributes
            TracingSupport.handleResponseStatusCode(span, response.status)

            // set explicitly allowed response headers
            let allowedResponseHeaderNames = Set(response.headers.map(\.name)).intersection(configuration.tracing.allowedHeaders)

            for headerName in allowedResponseHeaderNames {
                let values = response.headers[headerName]

                if !values.isEmpty {
                    span.attributes.http.response.header.set(headerName, to: values)
                }
            }
            
            // set network protocol version
            span.attributes.network.protocol.version = "\(response.version.major).\(response.version.minor)"

            return response
        }
    }
}
