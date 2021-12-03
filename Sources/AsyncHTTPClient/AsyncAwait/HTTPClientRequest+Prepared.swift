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
import NIOHTTP1

@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
extension HTTPClientRequest {
    struct Prepared {
        var poolKey: ConnectionPool.Key
        var requestFramingMetadata: RequestFramingMetadata
        var head: HTTPRequestHead
        var body: Body?
    }
}

@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
extension HTTPClientRequest.Prepared {
    init(_ request: HTTPClientRequest) throws {
        let url = try DeconstructedURL(url: request.url)

        var headers = request.headers
        headers.addHostIfNeeded(for: url)
        let metadata = try headers.validateAndSetTransportFraming(
            method: request.method,
            bodyLength: .init(request.body)
        )

        self.init(
            poolKey: .init(url: url, tlsConfiguration: nil),
            requestFramingMetadata: metadata,
            head: .init(
                version: .http1_1,
                method: request.method,
                uri: url.uri,
                headers: headers
            ),
            body: request.body
        )
    }
}

@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
extension RequestBodyLength {
    init(_ body: HTTPClientRequest.Body?) {
        switch body?.mode {
        case .none:
            self = .fixed(length: 0)
        case .byteBuffer(let buffer):
            self = .fixed(length: buffer.readableBytes)
        case .sequence(nil, _), .asyncSequence(nil, _):
            self = .dynamic
        case .sequence(.some(let length), _), .asyncSequence(.some(let length), _):
            self = .fixed(length: length)
        }
    }
}

#endif
