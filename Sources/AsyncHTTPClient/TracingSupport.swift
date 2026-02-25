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

import Foundation
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOSSL
import Tracing

// MARK: - Centralized span attribute handling

@usableFromInline
struct TracingSupport {
    @inlinable
    static func handleResponseStatusCode(
        _ span: Span,
        _ status: HTTPResponseStatus,
        keys: HTTPClient.TracingConfiguration.AttributeKeys
    ) {
        if status.code >= 400 {
            span.setStatus(.init(code: .error))
        }

        span.attributes[keys.responseStatusCode] = SpanAttribute.int64(Int64(status.code))
    }

    @inlinable
    static func sanitizePath(_ path: String, redactionComponents: Set<String>) -> String {
        redactionComponents.reduce(path) { path, component in
            path.replacingOccurrences(of: component, with: "REDACTED")
        }
    }

    @inlinable
    static func sanitizeQuery(_ query: String, redactionComponents: Set<String>) -> String {
        query.components(separatedBy: "&").map {
            let nameAndValue = $0
                .trimmingCharacters(in: .whitespaces)
                .components(separatedBy: "=")

            if redactionComponents.contains(nameAndValue[0]) {
                return "\(nameAndValue[0])=REDACTED"
            }

            return $0
        }.joined(separator: "&")
    }
}

// MARK: - HTTPHeadersInjector

struct HTTPHeadersInjector: Injector, @unchecked Sendable {
    static let shared: HTTPHeadersInjector = HTTPHeadersInjector()

    private init() {}

    func inject(_ value: String, forKey name: String, into headers: inout HTTPHeaders) {
        headers.add(name: name, value: value)
    }
}

// MARK: - Errors

internal struct HTTPRequestCancellationError: Error {}
