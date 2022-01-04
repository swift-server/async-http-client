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

import NIOHTTP1
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import CAsyncHTTPClient

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
        /// The cookie's expiration date, as a number of seconds since the Unix epoch.
        var expires_timestamp: Int64?
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
            var components = header.utf8.split(separator: UInt8(ascii: ";"), omittingEmptySubsequences: false)[...]
            guard let keyValuePair = components.popFirst()?.trimmingASCIISpaces() else {
                return nil
            }
            guard let (trimmedName, trimmedValue) = keyValuePair.parseKeyValuePair() else {
                return nil
            }
            guard !trimmedName.isEmpty else {
                return nil
            }
            // FIXME: The parsed values should be validated to ensure they only contain ASCII characters allowed by RFC-6265.
            // https://datatracker.ietf.org/doc/html/rfc6265#section-4.1.1
            self.name = String(utf8Slice: trimmedName, in: header)
            self.value = String(utf8Slice: trimmedValue.trimmingPairedASCIIQuote(), in: header)
            self.path = "/"
            self.domain = defaultDomain
            self.expires_timestamp = nil
            self.maxAge = nil
            self.httpOnly = false
            self.secure = false

            for component in components {
                switch component.parseCookieComponent() {
                case ("path", .some(let value))?:
                    self.path = String(utf8Slice: value, in: header)
                case ("domain", .some(let value))?:
                    self.domain = String(utf8Slice: value, in: header)
                case ("expires", .some(let value))?:
                    self.expires_timestamp = parseCookieTime(value, in: header)
                case ("max-age", .some(let value))?:
                    self.maxAge = Int(Substring(value))
                case ("secure", nil)?:
                    self.secure = true
                case ("httponly", nil)?:
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
        ///     - expires_timestamp: The cookie's expiration date, as a number of seconds since the Unix epoch. defaults to nil.
        ///     - maxAge: The cookie's age in seconds, defaults to nil.
        ///     - httpOnly: Whether this cookie should be used by HTTP servers only, defaults to false.
        ///     - secure: Whether this cookie should only be sent using secure channels, defaults to false.
        internal init(name: String, value: String, path: String = "/", domain: String? = nil, expires_timestamp: Int64? = nil, maxAge: Int? = nil, httpOnly: Bool = false, secure: Bool = false) {
            self.name = name
            self.value = value
            self.path = path
            self.domain = domain
            self.expires_timestamp = expires_timestamp
            self.maxAge = maxAge
            self.httpOnly = httpOnly
            self.secure = secure
        }
    }
}

extension HTTPClient.Response {
    /// List of HTTP cookies returned by the server.
    public var cookies: [HTTPClient.Cookie] {
        return self.headers["set-cookie"].compactMap { HTTPClient.Cookie(header: $0, defaultDomain: self.host) }
    }
}

extension String {
    /// Creates a String from a slice of UTF8 code-units, aligning the bounds to unicode scalar boundaries if needed.
    fileprivate init(utf8Slice: String.UTF8View.SubSequence, in base: String) {
        self.init(base[utf8Slice.startIndex..<utf8Slice.endIndex])
    }
}

extension String.UTF8View.SubSequence {
    fileprivate func trimmingASCIISpaces() -> SubSequence {
        guard let start = self.firstIndex(where: { $0 != UInt8(ascii: " ") }) else {
            return self[self.endIndex..<self.endIndex]
        }
        let end = self.lastIndex(where: { $0 != UInt8(ascii: " ") })!
        return self[start...end]
    }

    /// If this collection begins and ends with an ASCII double-quote ("),
    /// returns a version of self trimmed of those quotes. Otherwise, returns self.
    fileprivate func trimmingPairedASCIIQuote() -> SubSequence {
        let quoteChar = UInt8(ascii: "\"")
        var trimmed = self
        if trimmed.popFirst() == quoteChar && trimmed.popLast() == quoteChar {
            return trimmed
        }
        return self
    }

    /// Splits this collection in to a key and value at the first ASCII '=' character.
    /// Both the key and value are trimmed of ASCII spaces.
    fileprivate func parseKeyValuePair() -> (key: SubSequence, value: SubSequence)? {
        guard let keyValueSeparator = self.firstIndex(of: UInt8(ascii: "=")) else {
            return nil
        }
        let trimmedName = self[..<keyValueSeparator].trimmingASCIISpaces()
        let trimmedValue = self[self.index(after: keyValueSeparator)...].trimmingASCIISpaces()
        return (trimmedName, trimmedValue)
    }

    /// Parses this collection as either a key-value pair, or a plain key.
    /// The returned key is trimmed of ASCII spaces and normalized to lowercase.
    /// The returned value is trimmed of ASCII spaces.
    fileprivate func parseCookieComponent() -> (key: String, value: SubSequence?)? {
        let (trimmedName, trimmedValue) = self.parseKeyValuePair() ?? (self.trimmingASCIISpaces(), nil)
        guard !trimmedName.isEmpty else {
            return nil
        }
        return (Substring(trimmedName).lowercased(), trimmedValue)
    }
}

private let posixLocale: UnsafeMutableRawPointer = {
    // All POSIX systems must provide a "POSIX" locale, and its date/time formats are US English.
    // https://pubs.opengroup.org/onlinepubs/9699919799/basedefs/V1_chap07.html#tag_07_03_05
    let _posixLocale = newlocale(LC_TIME_MASK | LC_NUMERIC_MASK, "POSIX", nil)!
    return UnsafeMutableRawPointer(_posixLocale)
}()

private func parseTimestamp(_ string: String, format: String) -> tm? {
    var timeComponents = tm()
    guard swiftahc_cshims_strptime_l(string, format, &timeComponents, posixLocale) else {
        return nil
    }
    return timeComponents
}

private func parseCookieTime(_ timestampUTF8: String.UTF8View.SubSequence, in header: String) -> Int64? {
    if timestampUTF8.contains(where: { $0 < 0x20 /* Control characters */ || $0 == 0x7F /* DEL */ }) {
        return nil
    }
    let timestampString: String
    if timestampUTF8.hasSuffix("GMT".utf8) {
        let timezoneStart = timestampUTF8.index(timestampUTF8.endIndex, offsetBy: -3)
        let trimmedTimestampUTF8 = timestampUTF8[..<timezoneStart].trimmingASCIISpaces()
        guard trimmedTimestampUTF8.endIndex != timezoneStart else {
            return nil
        }
        timestampString = String(utf8Slice: trimmedTimestampUTF8, in: header)
    } else {
        timestampString = String(utf8Slice: timestampUTF8, in: header)
    }
    guard
        var timeComponents = parseTimestamp(timestampString, format: "%a, %d %b %Y %H:%M:%S")
        ?? parseTimestamp(timestampString, format: "%a, %d-%b-%y %H:%M:%S")
        ?? parseTimestamp(timestampString, format: "%a %b %d %H:%M:%S %Y")
    else {
        return nil
    }
    let timestamp = Int64(timegm(&timeComponents))
    return timestamp == -1 && errno == EOVERFLOW ? nil : timestamp
}
