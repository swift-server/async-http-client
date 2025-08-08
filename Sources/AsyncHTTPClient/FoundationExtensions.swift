//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2018-2021 Apple Inc. and the AsyncHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

// Extensions which provide better ergonomics when using Foundation types,
// or by using Foundation APIs.

import Foundation

extension HTTPClient.Cookie {
    /// The cookie's expiration date.
    public var expires: Date? {
        get {
            expires_timestamp.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        }
        set {
            expires_timestamp = newValue.map { Int64($0.timeIntervalSince1970) }
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
    public init(
        name: String,
        value: String,
        path: String = "/",
        domain: String? = nil,
        expires: Date? = nil,
        maxAge: Int? = nil,
        httpOnly: Bool = false,
        secure: Bool = false
    ) {
        // FIXME: This should be failable and validate the inputs
        // (for example, checking that the strings are ASCII, path begins with "/", domain is not empty, etc).
        self.init(
            name: name,
            value: value,
            path: path,
            domain: domain,
            expires_timestamp: expires.map { Int64($0.timeIntervalSince1970) },
            maxAge: maxAge,
            httpOnly: httpOnly,
            secure: secure
        )
    }
}

extension HTTPClient.Body {
    /// Create and stream body using `Data`.
    ///
    /// - parameters:
    ///     - data: Body `Data` representation.
    public static func data(_ data: Data) -> HTTPClient.Body {
        self.bytes(data)
    }
}
