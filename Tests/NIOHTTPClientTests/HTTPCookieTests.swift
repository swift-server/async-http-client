//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIOHTTP open source project
//
// Copyright (c) 2017-2018 Swift Server Working Group and the SwiftNIOHTTP project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIOHTTP project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation
import XCTest
@testable import NIOHTTPClient

class HTTPCookieTests: XCTestCase {

    func testCookie() {
        let v = "key=value; Path=/path; Domain=example.com; Expires=Wed, 21 Oct 2015 07:28:00 GMT; Max-Age=42; Secure; HttpOnly"
        let c = HTTPCookie(from: v, defaultDomain: "exampe.org")!
        XCTAssertEqual("key", c.name)
        XCTAssertEqual("value", c.value)
        XCTAssertEqual("/path", c.path)
        XCTAssertEqual("example.com", c.domain)
        XCTAssertEqual(Date(timeIntervalSince1970: 1445412480), c.expires)
        XCTAssertEqual(42, c.maxAge)
        XCTAssertTrue(c.httpOnly)
        XCTAssertTrue(c.secure)
    }

    func testCookieDefaults() {
        let v = "key=value"
        let c = HTTPCookie(from: v, defaultDomain: "example.org")!
        XCTAssertEqual("key", c.name)
        XCTAssertEqual("value", c.value)
        XCTAssertEqual("/", c.path)
        XCTAssertEqual("example.org", c.domain)
        XCTAssertNil(c.expires)
        XCTAssertNil(c.maxAge)
        XCTAssertFalse(c.httpOnly)
        XCTAssertFalse(c.secure)
    }
}
