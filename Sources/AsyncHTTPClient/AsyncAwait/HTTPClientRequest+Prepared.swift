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

import Instrumentation
import NIOCore
import NIOHTTP1
import NIOSSL
import ServiceContextModule

import struct Foundation.URL

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension HTTPClientRequest {
    struct Prepared: Sendable {
        enum Body: Sendable {
            case asyncSequence(
                length: RequestBodyLength,
                makeAsyncIterator: @Sendable () -> ((ByteBufferAllocator) async throws -> ByteBuffer?)
            )
            case sequence(
                length: RequestBodyLength,
                canBeConsumedMultipleTimes: Bool,
                makeCompleteBody: @Sendable (ByteBufferAllocator) -> ByteBuffer
            )
            case byteBuffer(ByteBuffer)
        }

        var url: URL
        var poolKey: ConnectionPool.Key
        var requestFramingMetadata: RequestFramingMetadata
        var head: HTTPRequestHead
        var body: Body?
        var tlsConfiguration: TLSConfiguration?
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension HTTPClientRequest.Prepared {
    init(
        _ request: HTTPClientRequest,
        dnsOverride: [String: String] = [:],
        tracing: HTTPClient.TracingConfiguration? = nil
    ) throws {
        guard !request.url.isEmpty, let url = URL(string: request.url) else {
            throw HTTPClientError.invalidURL
        }

        let deconstructedURL = try DeconstructedURL(url: url)

        var headers = request.headers
        headers.addHostIfNeeded(for: deconstructedURL)
        if let tracer = tracing?.tracer,
            let context = ServiceContext.current
        {
            tracer.inject(context, into: &headers, using: HTTPHeadersInjector.shared)
        }

        let metadata = try headers.validateAndSetTransportFraming(
            method: request.method,
            bodyLength: .init(request.body)
        )

        self.init(
            url: url,
            poolKey: .init(url: deconstructedURL, tlsConfiguration: request.tlsConfiguration, dnsOverride: dnsOverride),
            requestFramingMetadata: metadata,
            head: .init(
                version: .http1_1,
                method: request.method,
                uri: deconstructedURL.uri,
                headers: headers
            ),
            body: request.body.map { .init($0) },
            tlsConfiguration: request.tlsConfiguration
        )
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension HTTPClientRequest.Prepared.Body {
    init(_ body: HTTPClientRequest.Body) {
        switch body.mode {
        case .asyncSequence(let length, let makeAsyncIterator):
            self = .asyncSequence(length: length, makeAsyncIterator: makeAsyncIterator)
        case .sequence(let length, let canBeConsumedMultipleTimes, let makeCompleteBody):
            self = .sequence(
                length: length,
                canBeConsumedMultipleTimes: canBeConsumedMultipleTimes,
                makeCompleteBody: makeCompleteBody
            )
        case .byteBuffer(let byteBuffer):
            self = .byteBuffer(byteBuffer)
        }
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension RequestBodyLength {
    init(_ body: HTTPClientRequest.Body?) {
        switch body?.mode {
        case .none:
            self = .known(0)
        case .byteBuffer(let buffer):
            self = .known(Int64(buffer.readableBytes))
        case .sequence(let length, _, _), .asyncSequence(let length, _):
            self = length
        }
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension HTTPClientRequest {
    func followingRedirect(
        from originalURL: URL,
        to redirectURL: URL,
        status: HTTPResponseStatus
    ) -> HTTPClientRequest {
        let (method, headers, body) = transformRequestForRedirect(
            from: originalURL,
            method: self.method,
            headers: self.headers,
            body: self.body,
            to: redirectURL,
            status: status
        )
        var newRequest = HTTPClientRequest(url: redirectURL.absoluteString)
        newRequest.method = method
        newRequest.headers = headers
        newRequest.body = body
        return newRequest
    }
}
