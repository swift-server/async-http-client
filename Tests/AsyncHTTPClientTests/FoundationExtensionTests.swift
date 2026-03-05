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
        "localhost",  // Alphanumerics (No encoding needed)
        "example.com",  // Domain with unreserved dot (No encoding needed)
        "user@email.com",  // '@' is not allowed in host (Should be encoded to %40)
        "!$&'()*+,;=[]",  // Sub-delimiters and brackets (Allowed in host, NO encoding)
        "~_.-",  // Unreserved punctuation (Allowed in host, NO encoding)
        "café",  // Non-ASCII character (Should be encoded)
        "👨‍💻 swift",  // Emoji and space (Space to %20, Emoji encoded)
        "",  // Empty string
        "100% coverage",  // '%' symbol itself (Must be encoded to %25)
        "sub.domain_test~1.com",  // Mix of allowed characters
        "path/to/api?query=1#frag",  // Invalid host chars like '/', '?', and '#' (Should be encoded), '=' is a valid sub-delimiter
    ])
    func addingPercentEncodingAllowingURLHost(input: String) {
        let foundationResult = input.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed)
        let customResult = input.addingPercentEncodingAllowingURLHost()

        #expect(
            customResult == foundationResult,
            "Encoding mismatch for input: '\(input)'. Expected '\(String(describing: foundationResult))', got '\(String(describing: customResult))'"
        )
    }
}
