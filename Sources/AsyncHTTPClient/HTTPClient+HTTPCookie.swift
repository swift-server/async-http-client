//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the AsyncHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation
import NIOHTTP1

extension HTTPClient {
    /// A representation of an HTTP cookie.
    public struct Cookie {
        /// The name of the cookie.
        public var name: String
        /// The cookie's string value.
        public var value: String
        /// The cookie's path.
        public var path: String
        /// The domain of the cookie.
        public var domain: String?
        /// The cookie's expiration date.
        public var expires: Date?
        /// The cookie's age in seconds.
        public var maxAge: Int?
        /// Whether the cookie should only be sent to HTTP servers.
        public var httpOnly: Bool
        /// Whether the cookie should only be sent over secure channels.
        public var secure: Bool

        /// Create a Cookie by parsing a `Set-Cookie` header.
        ///
        /// - parameters:
        ///     - header: String representation of the `Set-Cookie` response header.
        ///     - defaultDomain: Default domain to use if cookie was sent without one.
        /// - returns: nil if the header is invalid.
        public init?(header: String, defaultDomain: String) {
            let components = header.components(separatedBy: ";").map {
                $0.trimmingCharacters(in: .whitespaces)
            }

            if components.isEmpty {
                return nil
            }

            let nameAndValue = components[0].split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }

            guard nameAndValue.count == 2 else {
                return nil
            }

            self.name = nameAndValue[0]
            self.value = nameAndValue[1]

            self.path = "/"
            self.domain = defaultDomain
            self.expires = nil
            self.maxAge = nil
            self.httpOnly = false
            self.secure = false

            for component in components[1...] {
                if component.starts(with: "Path"), let value = parseComponentValue(component) {
                    self.path = value
                    continue
                }

                if component.starts(with: "Domain"), let value = parseComponentValue(component) {
                    self.domain = value
                    continue
                }

                if component.starts(with: "Expires") {
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US")
                    formatter.timeZone = TimeZone(identifier: "GMT")
                    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
                    self.expires = self.parseComponentValue(component).flatMap { formatter.date(from: $0) }
                    continue
                }

                if component.starts(with: "Max-Age"), let value = parseComponentValue(component).flatMap(Int.init) {
                    self.maxAge = value
                    continue
                }

                if component == "Secure" {
                    self.secure = true
                    continue
                }

                if component == "HttpOnly" {
                    self.httpOnly = true
                    continue
                }
            }
        }

        /// Create HTTP cookie.
        ///
        /// - parameters:
        ///     - name: The name of the cookie.
        ///     - value: The cookie's string value.
        ///     - path: The cookie's path.
        ///     - domain: The domain of the cookie, defaults to nil.
        ///     - expires: The cookie's expiration date, defaults to nil.
        ///     - maxAge: The cookie's age in seconds, defaults to nil.
        ///     - httpOnly: Whether this cookie should be used by HTTP servers only, defaults to false.
        ///     - secure: Whether this cookie should only be sent using secure channels, defaults to false.
        public init(name: String, value: String, path: String = "/", domain: String? = nil, expires: Date? = nil, maxAge: Int? = nil, httpOnly: Bool = false, secure: Bool = false) {
            self.name = name
            self.value = value
            self.path = path
            self.domain = domain
            self.expires = expires
            self.maxAge = maxAge
            self.httpOnly = httpOnly
            self.secure = secure
        }

        func parseComponentValue(_ component: String) -> String? {
            let nameAndValue = component.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if nameAndValue.count == 2 {
                return nameAndValue[1]
            }
            return nil
        }
    }
}

extension HTTPClient.Response {
    var cookieHeaders: [HTTPHeaders.Element] {
        return headers.filter { $0.name.lowercased() == "set-cookie" }
    }

    /// List of HTTP cookies returned by the server.
    public var cookies: [HTTPClient.Cookie] {
        return self.cookieHeaders.compactMap { HTTPClient.Cookie(header: $0.value, defaultDomain: self.host) }
    }
}
