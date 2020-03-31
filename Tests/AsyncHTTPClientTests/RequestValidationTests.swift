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

@testable import AsyncHTTPClient
import NIO
import NIOHTTP1
import XCTest

class RequestValidationTests: XCTestCase {
    func testContentLengthHeaderIsRemovedFromGETIfNoBody() {
        var headers = HTTPHeaders([("Content-Length", "0")])
        XCTAssertNoThrow(try headers.validate(method: .GET, body: .none))
        XCTAssertNil(headers.first(name: "Content-Length"))
    }

    func testContentLengthHeaderIsAddedToPOSTAndPUTWithNoBody() {
        var putHeaders = HTTPHeaders()
        XCTAssertNoThrow(try putHeaders.validate(method: .PUT, body: .none))
        XCTAssertEqual(putHeaders.first(name: "Content-Length"), "0")

        var postHeaders = HTTPHeaders()
        XCTAssertNoThrow(try postHeaders.validate(method: .POST, body: .none))
        XCTAssertEqual(postHeaders.first(name: "Content-Length"), "0")
    }

    func testContentLengthHeaderIsChangedIfBodyHasDifferentLength() {
        var headers = HTTPHeaders([("Content-Length", "0")])
        var buffer = ByteBufferAllocator().buffer(capacity: 200)
        buffer.writeBytes([UInt8](repeating: 12, count: 200))
        XCTAssertNoThrow(try headers.validate(method: .PUT, body: .byteBuffer(buffer)))
        XCTAssertEqual(headers.first(name: "Content-Length"), "200")
    }

    func testChunkedEncodingDoesNotHaveContentLengthHeader() {
        var headers = HTTPHeaders([
            ("Content-Length", "200"),
            ("Transfer-Encoding", "chunked"),
        ])
        var buffer = ByteBufferAllocator().buffer(capacity: 200)
        buffer.writeBytes([UInt8](repeating: 12, count: 200))
        XCTAssertNoThrow(try headers.validate(method: .PUT, body: .byteBuffer(buffer)))

        // https://tools.ietf.org/html/rfc7230#section-3.3.2
        // A sender MUST NOT send a Content-Length header field in any message
        // that contains a Transfer-Encoding header field.

        XCTAssertNil(headers.first(name: "Content-Length"))
        XCTAssertEqual(headers.first(name: "Transfer-Encoding"), "chunked")
    }

    func testTRACERequestMustNotHaveBody() {
        var headers = HTTPHeaders([
            ("Content-Length", "200"),
            ("Transfer-Encoding", "chunked"),
        ])
        var buffer = ByteBufferAllocator().buffer(capacity: 200)
        buffer.writeBytes([UInt8](repeating: 12, count: 200))
        XCTAssertThrowsError(try headers.validate(method: .TRACE, body: .byteBuffer(buffer))) {
            XCTAssertEqual($0 as? HTTPClientError, .traceRequestWithBody)
        }
    }
}
