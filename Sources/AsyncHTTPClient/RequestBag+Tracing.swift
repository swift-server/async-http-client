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

extension RequestBag.LoopBoundState {

    /// Starts the "overall" Span that encompases the beginning of a request until receipt of the head part of the response.
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
        self.activeSpan = tracer.startSpan("\(request.method)", ofKind: .client)
    }

    /// Fails the active overall span given some internal error, e.g. timeout, pool shutdown etc.
    /// This is not to be used for failing a span given a failure status coded HTTPResponse.
    mutating func failRequestSpanAsCancelled() {
        if #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) {
            failRequestSpan(error: CancellationError())
        } else {
            failRequestSpan(error: HTTPRequestCancellationError())
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

    /// Ends the active overall span upon receipt of the response head.
    ///
    /// If the status code is in error range, this will automatically fail the span.
    mutating func endRequestSpan(response: HTTPResponseHead) {
        guard let span = activeSpan else {
            return
        }

        TracingSupport.handleResponseStatusCode(span, response.status, keys: tracing.attributeKeys)

        span.end()
        self.activeSpan = nil
    }
}
