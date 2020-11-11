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

            let nameAndValue = components[0].split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }

            guard nameAndValue.count == 2 else {
                return nil
            }

            self.name = nameAndValue[0]
            self.value = nameAndValue[1]

            guard !self.name.isEmpty else {
                return nil
            }

            self.path = "/"
            self.domain = defaultDomain
            self.expires = nil
            self.maxAge = nil
            self.httpOnly = false
            self.secure = false

            for component in components[1...] {
                switch self.parseComponent(component) {
                case (nil, nil):
                    continue
                case ("path", .some(let value)):
                    self.path = value
                case ("domain", .some(let value)):
                    self.domain = value
                case ("expires", let value):
                    guard let value = value else {
                        continue
                    }

                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US")
                    formatter.timeZone = TimeZone(identifier: "GMT")

                    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
                    if let date = formatter.date(from: value) {
                        self.expires = date
                        continue
                    }

                    formatter.dateFormat = "EEE, dd-MMM-yy HH:mm:ss z"
                    if let date = formatter.date(from: value) {
                        self.expires = date
                        continue
                    }

                    formatter.dateFormat = "EEE MMM d hh:mm:s yyyy"
                    if let date = formatter.date(from: value) {
                        self.expires = date
                    }
                case ("max-age", let value):
                    self.maxAge = value.flatMap(Int.init)
                case ("secure", nil):
                    self.secure = true
                case ("httponly", nil):
                    self.httpOnly = true
                default:
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

        func parseComponent(_ component: String) -> (String?, String?) {
            let nameAndValue = component.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if nameAndValue.count == 2 {
                return (nameAndValue[0].lowercased(), nameAndValue[1])
            } else if nameAndValue.count == 1 {
                return (nameAndValue[0].lowercased(), nil)
            }
            return (nil, nil)
        }
    }
}

extension HTTPClient.Response {
    /// List of HTTP cookies returned by the server.
    public var cookies: [HTTPClient.Cookie] {
        return self.headers["set-cookie"].compactMap { HTTPClient.Cookie(header: $0, defaultDomain: self.host) }
    }
}
