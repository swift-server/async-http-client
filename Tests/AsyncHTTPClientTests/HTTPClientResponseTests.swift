//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2023 Apple Inc. and the AsyncHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Logging
import NIOCore
import NIOHTTP1
import XCTest

@testable import AsyncHTTPClient

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
final class HTTPClientResponseTests: XCTestCase {
    func testSimpleResponse() {
        let response = HTTPClientResponse.expectedContentLength(
            requestMethod: .GET,
            headers: ["content-length": "1025"],
            status: .ok
        )
        XCTAssertEqual(response, 1025)
    }

    func testSimpleResponseNotModified() {
        let response = HTTPClientResponse.expectedContentLength(
            requestMethod: .GET,
            headers: ["content-length": "1025"],
            status: .notModified
        )
        XCTAssertEqual(response, 0)
    }

    func testSimpleResponseHeadRequestMethod() {
        let response = HTTPClientResponse.expectedContentLength(
            requestMethod: .HEAD,
            headers: ["content-length": "1025"],
            status: .ok
        )
        XCTAssertEqual(response, 0)
    }

    func testResponseNoContentLengthHeader() {
        let response = HTTPClientResponse.expectedContentLength(requestMethod: .GET, headers: [:], status: .ok)
        XCTAssertEqual(response, nil)
    }

    func testResponseInvalidInteger() {
        let response = HTTPClientResponse.expectedContentLength(
            requestMethod: .GET,
            headers: ["content-length": "none"],
            status: .ok
        )
        XCTAssertEqual(response, nil)
    }
}
