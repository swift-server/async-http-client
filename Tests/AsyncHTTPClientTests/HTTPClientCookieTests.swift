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

import AsyncHTTPClient
import Foundation
import XCTest

class HTTPClientCookieTests: XCTestCase {
    func testCookie() {
        let v = "key=value; Path=/path; Domain=example.com; Expires=Wed, 21 Oct 2015 07:28:00 GMT; Max-Age=42; Secure; HttpOnly"
        let c = HTTPClient.Cookie(header: v, defaultDomain: "exampe.org")!
        XCTAssertEqual("key", c.name)
        XCTAssertEqual("value", c.value)
        XCTAssertEqual("/path", c.path)
        XCTAssertEqual("example.com", c.domain)
        XCTAssertEqual(Date(timeIntervalSince1970: 1_445_412_480), c.expires)
        XCTAssertEqual(42, c.maxAge)
        XCTAssertTrue(c.httpOnly)
        XCTAssertTrue(c.secure)
    }

    func testCookieDefaults() {
        let v = "key=value"
        let c = HTTPClient.Cookie(header: v, defaultDomain: "example.org")!
        XCTAssertEqual("key", c.name)
        XCTAssertEqual("value", c.value)
        XCTAssertEqual("/", c.path)
        XCTAssertEqual("example.org", c.domain)
        XCTAssertNil(c.expires)
        XCTAssertNil(c.maxAge)
        XCTAssertFalse(c.httpOnly)
        XCTAssertFalse(c.secure)
    }

    func testCookieInit() {
        let c = HTTPClient.Cookie(name: "key", value: "value", path: "/path", domain: "example.com", expires: Date(timeIntervalSince1970: 1_445_412_480), maxAge: 42, httpOnly: true, secure: true)
        XCTAssertEqual("key", c.name)
        XCTAssertEqual("value", c.value)
        XCTAssertEqual("/path", c.path)
        XCTAssertEqual("example.com", c.domain)
        XCTAssertEqual(Date(timeIntervalSince1970: 1_445_412_480), c.expires)
        XCTAssertEqual(42, c.maxAge)
        XCTAssertTrue(c.httpOnly)
        XCTAssertTrue(c.secure)
    }
}
