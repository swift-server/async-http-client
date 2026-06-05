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

import Foundation
import Testing

@testable import AsyncHTTPClient

@Suite
struct FoundationExtensionTests {
    @Test(arguments: [
        // Format: (input, expected)
        ("localhost", "localhost"),  // Alphanumerics (No encoding needed)
        ("example.com", "example.com"),  // Domain with unreserved dot (No encoding needed)
        ("user@email.com", "user%40email.com"),  // '@' is not allowed in host (Should be encoded to %40)
        ("!$&'()*+,;=[]", "!$&\'()*+,;=%5B%5D"),  // Sub-delimiters and brackets (Allowed in host, NO encoding)
        ("~_.-", "~_.-"),  // Unreserved punctuation (Allowed in host, NO encoding)
        ("café", "caf%C3%A9"),  // Non-ASCII character (Should be encoded)
        ("👨‍💻 swift", "%F0%9F%91%A8%E2%80%8D%F0%9F%92%BB%20swift"),  // Emoji and space (Space to %20, Emoji encoded)
        ("", ""),  // Empty string
        ("100% coverage", "100%25%20coverage"),  // '%' symbol itself (Must be encoded to %25)
        ("sub.domain_test~1.com", "sub.domain_test~1.com"),  // Mix of allowed characters
        // Invalid host chars like '/', '?', and '#' (Should be encoded), '=' is a valid sub-delimiter
        ("path/to/api?query=1#frag", "path%2Fto%2Fapi%3Fquery=1%23frag"),
    ])
    func addingPercentEncodingAllowingURLHost(input: String, expected: String) {
        let foundationResult = input.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed)
        let customResult = input.addingPercentEncodingAllowingURLHost()

        #expect(
            customResult == expected,
            "Encoding mismatch for input: '\(input)'. Expected '\(String(describing: expected))', got '\(String(describing: customResult))'"
        )

        #expect(
            customResult == foundationResult,
            "Result did not match Foundation: '\(input)'. Expected '\(String(describing: foundationResult))', got '\(String(describing: customResult))'"
        )
    }
}
