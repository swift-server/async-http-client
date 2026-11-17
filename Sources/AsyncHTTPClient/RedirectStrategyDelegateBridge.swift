//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2026 Apple Inc. and the AsyncHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore

#if canImport(FoundationEssentials)
import struct FoundationEssentials.URL
#else
import struct Foundation.URL
#endif

/// Converts between the `HTTPClient.Request`/`HTTPClient.Body` the delegate-based
/// `execute(request:delegate:...)` API is built on, and the `HTTPClientRequest`/`HTTPClientRequest
/// .Body` a ``HTTPClientRedirectStrategy`` is offered and returns -- so a `.strategy` redirect
/// configuration, which is only natively wired up for the Swift Concurrency `execute(_:deadline:
/// logger:)` family, can also drive the delegate-based path's own redirect following (see
/// `RedirectHandler` in `HTTPHandler.swift`).
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension HTTPClientRequest {
    /// Builds the request a strategy is offered from the `HTTPClient.Request` the delegate-based
    /// path was about to follow a redirect with.
    ///
    /// `localAddress` has no equivalent field on `HTTPClient.Request`, so a strategy that sets it
    /// on the request it returns has no effect when reissued through `asDelegateRequest()` --
    /// there is nowhere on that side to put it.
    init(delegateRequest request: HTTPClient.Request) {
        self.init(url: request.url.absoluteString)
        self.method = request.method
        self.headers = request.headers
        self.body = request.body.map { HTTPClientRequest.Body(.delegateBody($0)) }
        self.tlsConfiguration = request.tlsConfiguration
    }

    /// Reissues a strategy's `.follow(_:)` decision through the delegate-based path.
    ///
    /// - Throws: Whatever `HTTPClient.Request.init(url:method:headers:body:tlsConfiguration:)`
    ///   throws for an invalid `url`, or ``HTTPClientError/redirectStrategyBodyNotSupported`` if
    ///   `body` is a streaming representation (`.stream`/`AsyncSequence`-backed, or the unstable
    ///   upload-writer body) that didn't originate from `init(delegateRequest:)` -- those can only
    ///   be drained by actually opening a connection and writing to it, which nothing at
    ///   redirect-decision time is in a position to do. A strategy that only returns
    ///   `context.redirectRequest` unchanged, or replaces its body with `.bytes`/`.byteBuffer`,
    ///   never hits this.
    func asDelegateRequest() throws -> HTTPClient.Request {
        try HTTPClient.Request(
            url: self.url,
            method: self.method,
            headers: self.headers,
            body: self.body.map { try $0.asDelegateBody() },
            tlsConfiguration: self.tlsConfiguration
        )
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension HTTPClientRequest.Body {
    fileprivate func asDelegateBody() throws -> HTTPClient.Body {
        switch self.mode {
        case .delegateBody(let body):
            // The common case: a strategy that didn't touch `redirectRequest.body` at all, so
            // this is still the exact body `init(delegateRequest:)` wrapped -- reused verbatim,
            // no re-encoding, no loss of whatever streaming behavior it originally had.
            return body

        case .byteBuffer(let buffer):
            return .byteBuffer(buffer)

        case .sequence(_, _, let makeCompleteBody):
            // `makeCompleteBody` is a plain synchronous closure (unlike `.asyncSequence`), so
            // this is a lossless, non-streaming drain -- not an approximation.
            return .byteBuffer(makeCompleteBody(ByteBufferAllocator()))

        case .asyncSequence:
            throw HTTPClientError.redirectStrategyBodyNotSupported

        #if UnstableHTTPAPIsSupport
        case .httpClientRequestBody:
            throw HTTPClientError.redirectStrategyBodyNotSupported
        #endif
        }
    }
}
