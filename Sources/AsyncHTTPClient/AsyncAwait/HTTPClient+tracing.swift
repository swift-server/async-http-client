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
            let keys = self.configuration.tracing.attributeKeys
            span.attributes[keys.requestMethod] = request.method.rawValue

            // set explicitly allowed request headers
            let allowedRequestHeaderNames = Set(request.headers.map(\.name)).intersection(configuration.tracing.allowedHeaders)

            for headerName in allowedRequestHeaderNames {
                let values = request.headers[headerName]

                if !values.isEmpty {
                    span.attributes["\(keys.requestHeader).\(headerName)"] = values
                }
            }

            // set url attributes
            if let url = URL(string: request.url) {
                span.attributes[keys.urlPath] = TracingSupport.sanitizePath(
                    url.path,
                    redactionComponents: self.configuration.tracing.sensitivePathComponents
                )

                if let scheme = url.scheme {
                    span.attributes[keys.urlScheme] = scheme
                }
                if let query = url.query {
                    span.attributes[keys.urlQuery] = TracingSupport.sanitizeQuery(
                        query,
                        redactionComponents: self.configuration.tracing.sensitiveQueryComponents
                    )
                }
                if let fragment = url.fragment {
                    span.attributes[keys.urlFragment] = fragment
                }
                if let host = url.host {
                    span.attributes[keys.serverHostname] = host
                }
                if let port = url.port {
                    span.attributes[keys.serverPort] = port
                }
            }

            let response = try await body()

            // set response span attributes
            TracingSupport.handleResponseStatusCode(span, response.status, keys: tracing.attributeKeys)

            // set explicitly allowed response headers
            let allowedResponseHeaderNames = Set(response.headers.map(\.name)).intersection(configuration.tracing.allowedHeaders)

            for headerName in allowedResponseHeaderNames {
                let values = response.headers[headerName]

                if !values.isEmpty {
                    span.attributes["\(keys.responseHeader).\(headerName)"] = values
                }
            }
            
            // set network protocol version
            span.attributes[keys.networkProtocolVersion] = "\(response.version.major).\(response.version.minor)"

            return response
        }
    }
}
