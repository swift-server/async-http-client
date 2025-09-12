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

#if TracingSupport
import Tracing
#endif

#if TracingSupport
struct HTTPHeadersInjector: Injector, @unchecked Sendable {
    static let shared: HTTPHeadersInjector = HTTPHeadersInjector()

    private init() {}

    func inject(_ value: String, forKey name: String, into headers: inout HTTPHeaders) {
        headers.add(name: name, value: value)
    }
}
#endif  // TracingSupport

// #if TracingSupport
// @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
// typealias HTTPClientTracingSupportTracerType = any Tracer
// #else
// enum TracingSupportDisabledTracer {}
// typealias HTTPClientTracingSupportTracerType = TracingSupportDisabledTracer
// #endif

protocol _TracingSupportOperations {
    // associatedtype TracerType

    /// Starts the "overall" Span that encompases the beginning of a request until receipt of the head part of the response.
    mutating func startRequestSpan<T>(tracer: T?)

    /// Fails the active overall span given some internal error, e.g. timeout, pool shutdown etc.
    /// This is not to be used for failing a span given a failure status coded HTTPResponse.
    mutating func failRequestSpan(error: any Error)
    mutating func failRequestSpanAsCancelled()  // because CancellationHandler availability...

    /// Ends the active overall span upon receipt of the response head.
    ///
    /// If the status code is in error range, this will automatically fail the span.
    mutating func endRequestSpan(response: HTTPResponseHead)
}

extension RequestBag.LoopBoundState: _TracingSupportOperations {}

#if !TracingSupport
/// Operations used to start/end spans at apropriate times from the Request lifecycle.
extension RequestBag.LoopBoundState {
    @inlinable
    mutating func startRequestSpan<T>(tracer: T?) {}

    @inlinable
    mutating func failRequestSpan(error: any Error) {}

    @inlinable
    mutating func failRequestSpanAsCancelled() {}

    @inlinable
    mutating func endRequestSpan(response: HTTPResponseHead) {}
}

#else  // TracingSupport

extension RequestBag.LoopBoundState {
    // typealias TracerType = Tracer

    mutating func startRequestSpan<T>(tracer: T?) {
        guard #available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *),
            let tracer = tracer as! (any Tracer)?
        else {
            return
        }

        assert(
            self.activeSpan == nil,
            "Unexpected active span when starting new request span! Was: \(String(describing: self.activeSpan))"
        )
        self.activeSpan = tracer.startSpan("\(request.method)")
        self.activeSpan?.attributes["loc"] = "\(#fileID):\(#line)"
    }

    mutating func failRequestSpanAsCancelled() {
        if #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) {
            let error = CancellationError()
            failRequestSpan(error: error)
        } else {
            fatalError("Unexpected configuration; expected availability of CancellationError")
        }
    }

    mutating func failRequestSpan(error: any Error) {
        guard let span = activeSpan else {
            return
        }

        span.recordError(error)
        span.end()

        self.activeSpan = nil
    }

    /// The request span currently ends when we receive the response head.
    mutating func endRequestSpan(response: HTTPResponseHead) {
        guard let span = activeSpan else {
            return
        }

        span.attributes["http.response.status_code"] = SpanAttribute.int64(Int64(response.status.code))
        if response.status.code >= 400 {
            span.setStatus(.init(code: .error))
        }
        span.end()
        self.activeSpan = nil
    }
}

#endif  // TracingSupport
