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
import CAsyncHTTPClient
import Foundation
import XCTest

class HTTPClientCookieTests: XCTestCase {
    func testCookie() {
        let v = "key=value; PaTh=/path; DoMaIn=example.com; eXpIRes=Wed, 21 Oct 2015 07:28:00 GMT; max-AGE=42; seCURE; HTTPOnly"
        guard let c = HTTPClient.Cookie(header: v, defaultDomain: "example.com") else {
            XCTFail("Failed to parse cookie")
            return
        }
        XCTAssertEqual("key", c.name)
        XCTAssertEqual("value", c.value)
        XCTAssertEqual("/path", c.path)
        XCTAssertEqual("example.com", c.domain)
        XCTAssertEqual(Date(timeIntervalSince1970: 1_445_412_480), c.expires)
        XCTAssertEqual(42, c.maxAge)
        XCTAssertTrue(c.httpOnly)
        XCTAssertTrue(c.secure)
    }

    func testEmptyValueCookie() {
        let v = "cookieValue=; Path=/"
        guard let c = HTTPClient.Cookie(header: v, defaultDomain: "example.com") else {
            XCTFail("Failed to parse cookie")
            return
        }
        XCTAssertEqual("cookieValue", c.name)
        XCTAssertEqual("", c.value)
        XCTAssertEqual("/", c.path)
        XCTAssertEqual("example.com", c.domain)
        XCTAssertNil(c.expires)
        XCTAssertNil(c.maxAge)
        XCTAssertFalse(c.httpOnly)
        XCTAssertFalse(c.secure)
    }

    func testCookieDefaults() {
        let v = "key=value"
        guard let c = HTTPClient.Cookie(header: v, defaultDomain: "example.com") else {
            XCTFail("Failed to parse cookie")
            return
        }
        XCTAssertEqual("key", c.name)
        XCTAssertEqual("value", c.value)
        XCTAssertEqual("/", c.path)
        XCTAssertEqual("example.com", c.domain)
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

    func testMalformedCookies() {
        XCTAssertNil(HTTPClient.Cookie(header: "", defaultDomain: "exampe.org"))
        XCTAssertNil(HTTPClient.Cookie(header: "name", defaultDomain: "exampe.org"))
        XCTAssertNil(HTTPClient.Cookie(header: ";;", defaultDomain: "exampe.org"))
        XCTAssertNil(HTTPClient.Cookie(header: "name;;", defaultDomain: "exampe.org"))
        XCTAssertNotNil(HTTPClient.Cookie(header: "name=;;", defaultDomain: "exampe.org"))
        XCTAssertNotNil(HTTPClient.Cookie(header: "name=value;;", defaultDomain: "exampe.org"))
        XCTAssertNotNil(HTTPClient.Cookie(header: "name=value;x;", defaultDomain: "exampe.org"))
        XCTAssertNotNil(HTTPClient.Cookie(header: "name=value;x=;", defaultDomain: "exampe.org"))
        XCTAssertNotNil(HTTPClient.Cookie(header: "name=value;;x=;", defaultDomain: "exampe.org"))
        XCTAssertNil(HTTPClient.Cookie(header: ";key=value", defaultDomain: "exampe.org"))
        XCTAssertNil(HTTPClient.Cookie(header: "key;key=value", defaultDomain: "exampe.org"))
        XCTAssertNil(HTTPClient.Cookie(header: "=;", defaultDomain: "exampe.org"))
        XCTAssertNil(HTTPClient.Cookie(header: "=value;", defaultDomain: "exampe.org"))
    }

    func testCookieExpiresDateParsing() {
        let domain = "example.org"

        // Regular formats.
        var c = HTTPClient.Cookie(header: "key=value; eXpIRes=Sun, 06 Nov 1994 08:49:37 GMT;", defaultDomain: domain)
        XCTAssertEqual(Date(timeIntervalSince1970: 784_111_777), c?.expires)
        c = HTTPClient.Cookie(header: "key=value; eXpIRes=Sunday, 06-Nov-94 08:49:37 GMT;", defaultDomain: domain)
        XCTAssertEqual(Date(timeIntervalSince1970: 784_111_777), c?.expires)
        c = HTTPClient.Cookie(header: "key=value; eXpIRes=Sun Nov  6 08:49:37 1994;", defaultDomain: domain)
        XCTAssertEqual(Date(timeIntervalSince1970: 784_111_777), c?.expires)

        // GMT is implicit.
        // Formats which typically include it may omit it; formats which typically omit it may include it.
        c = HTTPClient.Cookie(header: "key=value; expires=Sun, 06 Nov 1994 08:49:37;", defaultDomain: domain)
        XCTAssertEqual(Date(timeIntervalSince1970: 784_111_777), c?.expires)
        c = HTTPClient.Cookie(header: "key=value; expires=Sunday, 06-Nov-94 08:49:37;", defaultDomain: domain)
        XCTAssertEqual(Date(timeIntervalSince1970: 784_111_777), c?.expires)
        c = HTTPClient.Cookie(header: "key=value; expires=Sun Nov  6 08:49:37 1994 GMT;", defaultDomain: domain)
        XCTAssertEqual(Date(timeIntervalSince1970: 784_111_777), c?.expires)

        // If GMT is explicit, it must be separated from the timestamp by at least one space.
        c = HTTPClient.Cookie(header: "key=value; expires=Sun, 06 Nov 1994 08:49:37GMT;", defaultDomain: domain)
        XCTAssertNil(c?.expires)
        c = HTTPClient.Cookie(header: "key=value; expires=Sunday, 06-Nov-94 08:49:37GMT;", defaultDomain: domain)
        XCTAssertNil(c?.expires)
        c = HTTPClient.Cookie(header: "key=value; expires=Sun Nov  6 08:49:37 1994GMT;", defaultDomain: domain)
        XCTAssertNil(c?.expires)

        // Where space are required, any number of spaces are okay.
        c = HTTPClient.Cookie(header: "key=value; expires=Sun,     06 Nov    1994 08:49:37;", defaultDomain: domain)
        XCTAssertEqual(Date(timeIntervalSince1970: 784_111_777), c?.expires)
        c = HTTPClient.Cookie(header: "key=value; expires=Sunday,   06-Nov-94     08:49:37;", defaultDomain: domain)
        XCTAssertEqual(Date(timeIntervalSince1970: 784_111_777), c?.expires)
        c = HTTPClient.Cookie(header: "key=value; expires=  Sun    Nov  6    08:49:37 1994;", defaultDomain: domain)
        XCTAssertEqual(Date(timeIntervalSince1970: 784_111_777), c?.expires)
        c = HTTPClient.Cookie(header: "key=value; expires=Sun, 06 Nov 1994 08:49:37    GMT;", defaultDomain: domain)
        XCTAssertEqual(Date(timeIntervalSince1970: 784_111_777), c?.expires)
        c = HTTPClient.Cookie(header: "key=value; expires=Sunday, 06-Nov-94 08:49:37   GMT;", defaultDomain: domain)
        XCTAssertEqual(Date(timeIntervalSince1970: 784_111_777), c?.expires)
        c = HTTPClient.Cookie(header: "key=value; expires=Sun Nov  6 08:49:37 1994     GMT;", defaultDomain: domain)
        XCTAssertEqual(Date(timeIntervalSince1970: 784_111_777), c?.expires)

        // Where spaces are required, tabs and newlines are not okay.
        c = HTTPClient.Cookie(header: "key=value; expires=Sun,\t06 Nov 1994 08:49:37 GMT;", defaultDomain: domain)
        XCTAssertNil(c?.expires)
        c = HTTPClient.Cookie(header: "key=value; expires=Sun,\n06 Nov 1994 08:49:37 GMT;", defaultDomain: domain)
        XCTAssertNil(c?.expires)
        c = HTTPClient.Cookie(header: "key=value; expires=Sun, 06 Nov 1994 08:49:37\tGMT;", defaultDomain: domain)
        XCTAssertNil(c?.expires)
        c = HTTPClient.Cookie(header: "key=value; expires=Sun, 06 Nov 1994 08:49:37\nGMT;", defaultDomain: domain)
        XCTAssertNil(c?.expires)

        // Spaces are only allowed in particular locations.
        c = HTTPClient.Cookie(header: "key=value; expires=Sunday, 06-  Nov-94     08:49:37;", defaultDomain: domain)
        XCTAssertNil(c?.expires)
        c = HTTPClient.Cookie(header: "key=value; expires=  Sun    Nov  6   08:4 9:37 1994;", defaultDomain: domain)
        XCTAssertNil(c?.expires)

        // Incorrect comma placement.
        c = HTTPClient.Cookie(header: "key=value; expires=Sun 06 Nov 1994 08:49:37 GMT;", defaultDomain: domain)
        XCTAssertNil(c?.expires)
        c = HTTPClient.Cookie(header: "key=value; expires=Sunday 06-Nov-94 08:49:37 GMT;", defaultDomain: domain)
        XCTAssertNil(c?.expires)
        c = HTTPClient.Cookie(header: "key=value; expires=Sun, Nov  6 08:49:37 1994 GMT;", defaultDomain: domain)
        XCTAssertNil(c?.expires)

        // Incorrect delimiters.
        c = HTTPClient.Cookie(header: "key=value; expires=Sunday 06/Nov/94 08:49:37 GMT;", defaultDomain: domain)
        XCTAssertNil(c?.expires)
        c = HTTPClient.Cookie(header: "key=value; expires=Sun, Nov  6 08-49-37 1994 GMT;", defaultDomain: domain)
        XCTAssertNil(c?.expires)

        // Non-GMT timezones are rejected.
        c = HTTPClient.Cookie(header: "key=value; expires=Sun, 06 Nov 1994 08:49:37 BST;", defaultDomain: domain)
        XCTAssertNil(c?.expires)
        c = HTTPClient.Cookie(header: "key=value; expires=Sunday, 06-Nov-94 08:49:37 PST;", defaultDomain: domain)
        XCTAssertNil(c?.expires)
        c = HTTPClient.Cookie(header: "key=value; expires=Sun Nov  6 08:49:37 1994 CET;", defaultDomain: domain)
        XCTAssertNil(c?.expires)

        c = HTTPClient.Cookie(header: "key=value; expires=GMT;", defaultDomain: domain)
        XCTAssertNil(c?.expires)
        c = HTTPClient.Cookie(header: "key=value; expires=\"  GMT\";", defaultDomain: domain)
        XCTAssertNil(c?.expires)
        c = HTTPClient.Cookie(header: "key=value; expires=CET;", defaultDomain: domain)
        XCTAssertNil(c?.expires)
    }

    func testQuotedCookies() {
        var c = HTTPClient.Cookie(header: "key=\"value\"", defaultDomain: "example.org")
        XCTAssertEqual("value", c?.value)

        c = HTTPClient.Cookie(header: "key=\"value\"; Path=/path", defaultDomain: "example.org")
        XCTAssertEqual("value", c?.value)
        XCTAssertEqual("/path", c?.path)

        c = HTTPClient.Cookie(header: "key=\"\"", defaultDomain: "example.org")
        XCTAssertEqual("", c?.value)

        // Spaces inside paired quotes are not trimmed.
        c = HTTPClient.Cookie(header: "key=\"  abc  \"", defaultDomain: "example.org")
        XCTAssertEqual("  abc  ", c?.value)

        c = HTTPClient.Cookie(header: "key=\"  \"", defaultDomain: "example.org")
        XCTAssertEqual("  ", c?.value)

        // Unpaired quote at start of value.
        c = HTTPClient.Cookie(header: "key=\"abc", defaultDomain: "example.org")
        XCTAssertEqual("\"abc", c?.value)

        // Unpaired quote in the middle of the value.
        c = HTTPClient.Cookie(header: "key=ab\"c", defaultDomain: "example.org")
        XCTAssertEqual("ab\"c", c?.value)

        // Unpaired quote at the end of the value.
        c = HTTPClient.Cookie(header: "key=abc\"", defaultDomain: "example.org")
        XCTAssertEqual("abc\"", c?.value)
    }

    func testCookieExpiresDateParsingWithNonEnglishLocale() throws {
        try withCLocaleSetToGerman {
            // Check that we are using a German C locale.
            var localeCheck = tm()
            guard swiftahc_cshims_strptime("Freitag Februar", "%a %b", &localeCheck) else {
                throw XCTSkip("Unable to set locale")
            }
            // These values are zero-based 🙄
            try XCTSkipIf(localeCheck.tm_wday != 5, "Unable to set locale")
            try XCTSkipIf(localeCheck.tm_mon != 1, "Unable to set locale")

            // Cookie parsing should be independent of C locale.
            var c = HTTPClient.Cookie(header: "key=value; eXpIRes=Sunday, 06-Nov-94 08:49:37 GMT;", defaultDomain: "example.org")
            XCTAssertEqual(Date(timeIntervalSince1970: 784_111_777), c?.expires)
            c = HTTPClient.Cookie(header: "key=value; eXpIRes=Sun Nov  6 08:49:37 1994;", defaultDomain: "example.org")!
            XCTAssertEqual(Date(timeIntervalSince1970: 784_111_777), c?.expires)
            c = HTTPClient.Cookie(header: "key=value; eXpIRes=Sonntag, 06-Nov-94 08:49:37 GMT;", defaultDomain: "example.org")!
            XCTAssertNil(c?.expires)
        }
    }
}
