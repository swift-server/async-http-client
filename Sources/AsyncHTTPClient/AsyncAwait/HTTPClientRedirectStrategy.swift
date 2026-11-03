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

import NIOHTTP1

/// A pluggable strategy for deciding whether — and how — to follow HTTP redirects, used via
/// ``HTTPClient/Configuration/RedirectConfiguration/strategy(_:)``.
///
/// Unlike `.disallow`/`.follow(max:allowCycles:)`, a strategy gets a chance to inspect every
/// redirect-eligible response before it's followed: adjust the outgoing request, refuse the redirect
/// outright, or fail the whole request with a custom error.
///
/// A single strategy instance is stored on ``HTTPClient/Configuration`` and reused for every request
/// that client makes, including concurrently — if your strategy holds mutable state (e.g. an audit
/// log, a shared allow-list), synchronize it yourself (an `actor`, or a class using a lock).
/// Per-request state doesn't need that: ``HTTPClientRedirectContext/history`` already carries
/// everything tracked so far for the *current* logical request, so most policies (host allow-listing,
/// loop bounds, auditing) can be implemented statelessly by reading it fresh on each call.
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
public protocol HTTPClientRedirectStrategy: Sendable {
    /// Decide whether — and how — to follow a redirect.
    ///
    /// - Parameter context: Everything known about the redirect so far. See
    ///   ``HTTPClientRedirectContext``.
    /// - Returns: Whether — and with what request — to follow the redirect.
    /// - Throws: To fail the whole `execute(...)` call with a custom error instead of following the
    ///   redirect or returning the response that triggered it.
    func redirectDecision(for context: HTTPClientRedirectContext) throws -> HTTPClientRedirectDecision
}

/// Everything a ``HTTPClientRedirectStrategy`` is handed to decide whether — and how — to follow one
/// redirect.
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
public struct HTTPClientRedirectContext: Sendable {
    /// The request that would be sent to follow the redirect. It has already gone through the same
    /// method/header rewrite rules `.follow` would apply (converting `POST` to `GET` on a 303,
    /// stripping `Authorization`/`Cookie`/`Origin`/`Proxy-Authorization` on cross-origin redirects) —
    /// you only need to make further adjustments, not reimplement those rules from scratch.
    public var redirectRequest: HTTPClientRequest

    /// The head of the response that triggered the redirect.
    public var response: HTTPResponseHead

    /// Every request/response pair sent so far for this logical request, oldest first, including the
    /// one that produced ``response``. This is the same data that ends up in
    /// ``HTTPClientResponse/history`` on the final response.
    public var history: [HTTPClientRequestResponse]

    /// How many redirects have already been followed for this logical request (equivalently,
    /// `history.count - 1`). There is no built-in limit for `.strategy`/`.custom` mode — enforce your
    /// own policy (e.g. refusing past a maximum count) to avoid infinite redirect loops.
    public var redirectCount: Int

    public init(
        redirectRequest: HTTPClientRequest,
        response: HTTPResponseHead,
        history: [HTTPClientRequestResponse],
        redirectCount: Int
    ) {
        self.redirectRequest = redirectRequest
        self.response = response
        self.history = history
        self.redirectCount = redirectCount
    }
}

/// The result of a ``HTTPClientRedirectStrategy`` deciding whether — and how — to follow a redirect.
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
public enum HTTPClientRedirectDecision: Sendable {
    /// Follow the redirect using the given request.
    case follow(HTTPClientRequest)
    /// Do not follow the redirect; the response that triggered it is returned as-is.
    case doNotFollow
}

/// Adapts a closure to ``HTTPClientRedirectStrategy``, backing
/// ``HTTPClient/Configuration/RedirectConfiguration/custom(_:)``.
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
struct ClosureRedirectStrategy: HTTPClientRedirectStrategy {
    let handler: @Sendable (HTTPClientRedirectContext) throws -> HTTPClientRedirectDecision

    func redirectDecision(for context: HTTPClientRedirectContext) throws -> HTTPClientRedirectDecision {
        try self.handler(context)
    }
}
