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

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

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

extension StringProtocol {
    func addingPercentEncodingAllowingURLHost() -> String {
        guard !self.isEmpty else { return String(self) }

        let percent = UInt8(ascii: "%")
        let utf8Buffer = self.utf8
        let maxLength = utf8Buffer.count * 3
        return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: maxLength) { outputBuffer in
            var i = 0
            for byte in utf8Buffer {
                if byte.isURLHostAllowed {
                    outputBuffer[i] = byte
                    i += 1
                } else {
                    outputBuffer[i] = percent
                    outputBuffer[i + 1] = hexToAscii(byte >> 4)
                    outputBuffer[i + 2] = hexToAscii(byte & 0xF)
                    i += 3
                }
            }
            return String(decoding: outputBuffer[..<i], as: UTF8.self)
        }
    }
}

private func hexToAscii(_ hex: UInt8) -> UInt8 {
    switch hex {
    case 0x0: return UInt8(ascii: "0")
    case 0x1: return UInt8(ascii: "1")
    case 0x2: return UInt8(ascii: "2")
    case 0x3: return UInt8(ascii: "3")
    case 0x4: return UInt8(ascii: "4")
    case 0x5: return UInt8(ascii: "5")
    case 0x6: return UInt8(ascii: "6")
    case 0x7: return UInt8(ascii: "7")
    case 0x8: return UInt8(ascii: "8")
    case 0x9: return UInt8(ascii: "9")
    case 0xA: return UInt8(ascii: "A")
    case 0xB: return UInt8(ascii: "B")
    case 0xC: return UInt8(ascii: "C")
    case 0xD: return UInt8(ascii: "D")
    case 0xE: return UInt8(ascii: "E")
    case 0xF: return UInt8(ascii: "F")
    default: fatalError("Invalid hex digit: \(hex)")
    }
}

extension UInt8 {
    fileprivate var isURLHostAllowed: Bool {
        switch self {
        case UInt8(ascii: "0")...UInt8(ascii: "9"),
            UInt8(ascii: "A")...UInt8(ascii: "Z"),
            UInt8(ascii: "a")...UInt8(ascii: "z"),
            UInt8(ascii: "!"), UInt8(ascii: "$"), UInt8(ascii: "&"), UInt8(ascii: "'"),
            UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "*"), UInt8(ascii: "+"),
            UInt8(ascii: ","), UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: ";"),
            UInt8(ascii: "="), UInt8(ascii: "_"), UInt8(ascii: "~"):
            return true
        default: return false
        }
    }
}
