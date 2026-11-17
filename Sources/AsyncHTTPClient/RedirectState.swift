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

#if canImport(FoundationEssentials)
import struct FoundationEssentials.URL
#else
import struct Foundation.URL
#endif

typealias RedirectMode = HTTPClient.Configuration.RedirectConfiguration.Mode

// `Mode` can't derive `Equatable`/`Hashable` because `.strategy` carries an existential. `.strategy`
// values have no meaningful notion of equality, so — like `NaN` — a `.strategy` value is never equal
// to any other value, including another `.strategy`; this is consistent (if vacuously so) with the
// `Hashable` requirement that equal values hash equally.
extension HTTPClient.Configuration.RedirectConfiguration.Mode: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.disallow, .disallow):
            return true
        case (.follow(let lhsConfig), .follow(let rhsConfig)):
            return lhsConfig == rhsConfig
        default:
            return false
        }
    }
}

extension HTTPClient.Configuration.RedirectConfiguration.Mode: Hashable {
    func hash(into hasher: inout Hasher) {
        switch self {
        case .disallow:
            hasher.combine(0)
        case .follow(let config):
            hasher.combine(1)
            hasher.combine(config)
        case .strategy:
            hasher.combine(2)
        }
    }
}

/// Tracks how the delegate-based `execute(request:delegate:...)` API should handle the next
/// redirect for one logical request, for whichever mode `HTTPClient.Configuration
/// .RedirectConfiguration.Mode` was configured with.
enum RedirectState {
    case follow(Follow)

    /// Always a `Strategy` value underneath -- type-erased as `any Sendable` for the same reason
    /// `Mode.strategy` itself is: `Strategy` is only available on OSes new enough for Swift
    /// Concurrency, and Swift disallows `@available` on an enum case with an associated value. See
    /// `Mode.strategy`'s own doc comment.
    case strategy(any Sendable)
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

        case .follow(let config):
            self = .follow(Follow(config: config, visited: [initialURL]))

        case .strategy(let anyStrategy):
            guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else {
                // `.strategy(_:)`/`.custom(_:)` require this same availability floor to
                // construct, so this is unreachable in practice. Falling back to "don't track
                // redirect state" would silently degrade to "no redirects are ever followed"
                // instead -- `_execute`'s own availability guard is what actually surfaces this
                // as `.invalidRedirectConfiguration` rather than a silent behavior change.
                return nil
            }

            let strategy = anyStrategy as! any HTTPClientRedirectStrategy
            self = .strategy(Strategy(strategy: strategy, history: [], redirectCount: 0))
        }
    }
}

extension RedirectState {
    struct Follow: Sendable {
        var config: HTTPClient.Configuration.RedirectConfiguration.FollowConfiguration

        /// All visited URLs.
        private var visited: [String]

        fileprivate init(config: HTTPClient.Configuration.RedirectConfiguration.FollowConfiguration, visited: [String])
        {
            self.config = config
            self.visited = visited
        }

        /// Call this method when you are about to do a redirect to the given `redirectURL`.
        /// This method records that URL into `self`.
        /// - Parameter redirectURL: the new URL to redirect the request to
        /// - Throws: if it reaches the redirect limit or detects a redirect cycle if and `allowCycles` is false
        mutating func redirect(to redirectURL: String) throws {
            guard self.visited.count <= config.max else {
                throw HTTPClientError.redirectLimitReached
            }

            guard config.allowCycles || !self.visited.contains(redirectURL) else {
                throw HTTPClientError.redirectCycleDetected
            }
            self.visited.append(redirectURL)
        }
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension RedirectState {
    struct Strategy: Sendable {
        let strategy: any HTTPClientRedirectStrategy

        /// Every request/response pair sent so far for this logical request, oldest first.
        var history: [HTTPClientRequestResponse]

        /// How many redirects have already been followed for this logical request.
        var redirectCount: Int
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
    status responseStatus: HTTPResponseStatus,
    config: HTTPClient.Configuration.RedirectConfiguration.FollowConfiguration
) -> (HTTPMethod, HTTPHeaders, Body?) {
    let convertToGet: Bool
    if responseStatus == .seeOther, requestMethod != .HEAD {
        convertToGet = true
    } else if responseStatus == .movedPermanently, requestMethod == .POST {
        convertToGet = !config.retainHTTPMethodAndBodyOn301
    } else if responseStatus == .found, requestMethod == .POST {
        convertToGet = !config.retainHTTPMethodAndBodyOn302
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
