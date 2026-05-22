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
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOSSL
import Tracing

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// MARK: - Centralized span attribute handling

@usableFromInline
struct TracingSupport {
    @inlinable
    @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
    static func handleRequestTracingAttributes(
        _ span: Span,
        _ request: HTTPClientRequest,
        configuration: HTTPClient.TracingConfiguration
    ) {
        let requestBodySize: Int? =
            switch request.body?.mode {
            case .asyncSequence(.known(let length), _), .sequence(.known(let length), _, _):
                Int(length)
            case .byteBuffer(let byteBuffer):
                byteBuffer.readableBytes
            case .asyncSequence(.unknown, _), .sequence(.unknown, _, _), nil:
                nil
            #if UnstableHTTPAPIsSupport
            case .httpClientRequestBody(.known(let length), startUpload: _):
                Int(length)
            case .httpClientRequestBody(.unknown, startUpload: _):
                nil
            #endif
            }
        let url = URL(string: request.url)
        let deconstructedURL: DeconstructedURL? =
            if let url {
                try? DeconstructedURL(url: url)
            } else {
                nil
            }
        handleRequestTracingAttributes(
            span,
            requestMethod: request.method.rawValue,
            url: url,
            deconstructedURL: deconstructedURL,
            requestBodySize: requestBodySize,
            configuration: configuration
        )
    }

    @inlinable
    static func handleRequestTracingAttributes(
        _ span: Span,
        _ request: HTTPClient.Request,
        configuration: HTTPClient.TracingConfiguration
    ) {
        handleRequestTracingAttributes(
            span,
            requestMethod: request.method.rawValue,
            url: request.url,
            deconstructedURL: request.deconstructedURL,
            requestBodySize: request.body?.contentLength.map { Int($0) },
            configuration: configuration
        )
    }

    @usableFromInline
    static func handleRequestTracingAttributes(
        _ span: Span,
        requestMethod: String,
        url: URL?,
        deconstructedURL: DeconstructedURL?,
        requestBodySize: Int?,
        configuration: HTTPClient.TracingConfiguration
    ) {
        let keys = configuration.attributeKeys
        span.attributes[keys.requestMethod] = requestMethod
        span.attributes[keys.urlScheme] = deconstructedURL?.scheme.rawValue
        span.attributes[keys.serverAddress] = deconstructedURL?.connectionTarget.host
        span.attributes[keys.serverPort] = deconstructedURL?.connectionTarget.port
        span.attributes[keys.requestBodySize] = requestBodySize
        span.attributes[keys.urlPath] = url?.path
        span.attributes[keys.fullUrl] = url?.stringWithUserAndPasswordStripped
        span.attributes[keys.urlQuery] = url?.query
    }

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

extension URL {
    /// Returns the absolute string of `url` with any embedded credentials (username and password) removed to avoid logging secrets.
    fileprivate var stringWithUserAndPasswordStripped: String? {
        if #available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *) {
            guard self.user() != nil || self.password() != nil else {
                return self.absoluteString
            }
        } else {
            guard self.user != nil || self.password != nil else {
                return self.absoluteString
            }
        }
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: true) else {
            // Should never happen because URL should be well-formed. If it is not, be defensive and avoid logging the URL instead of logging
            // username + password.
            return nil
        }
        components.user = nil
        components.password = nil
        return components.string
    }
}
