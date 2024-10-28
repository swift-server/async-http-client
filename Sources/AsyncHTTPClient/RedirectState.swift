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

import struct Foundation.URL

typealias RedirectMode = HTTPClient.Configuration.RedirectConfiguration.Mode

struct RedirectState {
    /// number of redirects we are allowed to follow.
    private var limit: Int

    /// All visited URLs.
    private var visited: [String]

    /// if true, `redirect(to:)` will throw an error if a cycle is detected.
    private let allowCycles: Bool
}

extension RedirectState {
    /// Creates a `RedirectState` from a configuration.
    /// Returns nil if the user disallowed redirects,
    /// otherwise an instance of `RedirectState` which respects the user defined settings.
    init?(
        _ configuration: RedirectMode,
        initialURL: String
    ) {
        switch configuration {
        case .disallow:
            return nil
        case .follow(let maxRedirects, let allowCycles):
            self.init(limit: maxRedirects, visited: [initialURL], allowCycles: allowCycles)
        }
    }
}

extension RedirectState {
    /// Call this method when you are about to do a redirect to the given `redirectURL`.
    /// This method records that URL into `self`.
    /// - Parameter redirectURL: the new URL to redirect the request to
    /// - Throws: if it reaches the redirect limit or detects a redirect cycle if and `allowCycles` is false
    mutating func redirect(to redirectURL: String) throws {
        guard self.visited.count <= limit else {
            throw HTTPClientError.redirectLimitReached
        }

        guard allowCycles || !self.visited.contains(redirectURL) else {
            throw HTTPClientError.redirectCycleDetected
        }
        self.visited.append(redirectURL)
    }
}

extension HTTPHeaders {
    /// Tries to extract a redirect URL from the `location` header if the `status` indicates it should do so.
    /// It also validates that we can redirect to the scheme of the extracted redirect URL from the `originalScheme`.
    /// - Parameters:
    ///   - status: response status of the request
    ///   - originalURL: url of the previous request
    ///   - originalScheme: scheme of the previous request
    /// - Returns: redirect URL to follow
    func extractRedirectTarget(
        status: HTTPResponseStatus,
        originalURL: URL,
        originalScheme: Scheme
    ) -> URL? {
        switch status {
        case .movedPermanently, .found, .seeOther, .notModified, .useProxy, .temporaryRedirect, .permanentRedirect:
            break
        default:
            return nil
        }

        guard let location = self.first(name: "Location") else {
            return nil
        }

        guard let url = URL(string: location, relativeTo: originalURL) else {
            return nil
        }

        guard originalScheme.supportsRedirects(to: url.scheme) else {
            return nil
        }

        if url.isFileURL {
            return nil
        }

        return url.absoluteURL
    }
}

/// Transforms the original `requestMethod`, `requestHeaders` and `requestBody` to be ready to be send out as a new request to the `redirectURL`.
/// - Returns: New `HTTPMethod`, `HTTPHeaders` and `Body` to be send as a new request to `redirectURL`
func transformRequestForRedirect<Body>(
    from originalURL: URL,
    method requestMethod: HTTPMethod,
    headers requestHeaders: HTTPHeaders,
    body requestBody: Body?,
    to redirectURL: URL,
    status responseStatus: HTTPResponseStatus
) -> (HTTPMethod, HTTPHeaders, Body?) {
    let convertToGet: Bool
    if responseStatus == .seeOther, requestMethod != .HEAD {
        convertToGet = true
    } else if responseStatus == .movedPermanently || responseStatus == .found, requestMethod == .POST {
        convertToGet = true
    } else {
        convertToGet = false
    }

    var method = requestMethod
    var headers = requestHeaders
    var body = requestBody

    if convertToGet {
        method = .GET
        body = nil
        headers.remove(name: "Content-Length")
        headers.remove(name: "Content-Type")
    }

    if !originalURL.hasTheSameOrigin(as: redirectURL) {
        headers.remove(name: "Origin")
        headers.remove(name: "Cookie")
        headers.remove(name: "Authorization")
        headers.remove(name: "Proxy-Authorization")
    }
    return (method, headers, body)
}
