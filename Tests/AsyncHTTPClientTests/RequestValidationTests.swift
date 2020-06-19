//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2020 Apple Inc. and the AsyncHTTPClient project authors
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

    func testTRACERequestMustNotHaveBody() {
        for header in [("Content-Length", "200"), ("Transfer-Encoding", "chunked")] {
            var headers = HTTPHeaders([header])
            var buffer = ByteBufferAllocator().buffer(capacity: 200)
            buffer.writeBytes([UInt8](repeating: 12, count: 200))
            XCTAssertThrowsError(try headers.validate(method: .TRACE, body: .byteBuffer(buffer))) {
                XCTAssertEqual($0 as? HTTPClientError, .traceRequestWithBody)
            }
        }
    }

    func testGET_HEAD_DELETE_CONNECTRequestCanHaveBody() {
        var buffer = ByteBufferAllocator().buffer(capacity: 100)
        buffer.writeBytes([UInt8](repeating: 12, count: 100))

        // GET, HEAD, DELETE and CONNECT requests can have a payload. (though uncommon)
        let allowedMethods: [HTTPMethod] = [.GET, .HEAD, .DELETE, .CONNECT]
        var headers = HTTPHeaders()
        for method in allowedMethods {
            XCTAssertNoThrow(try headers.validate(method: method, body: .byteBuffer(buffer)))
        }
    }

    func testInvalidHeaderFieldNames() {
        var headers = HTTPHeaders([
            ("Content-Length", "200"),
            ("User Agent", "Haha"),
        ])

        XCTAssertThrowsError(try headers.validate(method: .GET, body: nil)) { error in
            XCTAssertEqual(error as? HTTPClientError, HTTPClientError.invalidHeaderFieldNames(["User Agent"]))
        }
    }

    func testValidHeaderFieldNames() {
        var headers = HTTPHeaders([
            ("abcdefghijklmnopqrstuvwxyz", "Haha"),
            ("ABCDEFGHIJKLMNOPQRSTUVWXYZ", "Haha"),
            ("0123456789", "Haha"),
            ("!#$%&'*+-.^_`|~", "Haha"),
        ])

        XCTAssertNoThrow(try headers.validate(method: .GET, body: nil))
    }

    // MARK: - Content-Length/Transfer-Encoding Matrix

    // Method kind                               User sets  Body   Expectation
    // ----------------------------------------------------------------------------------
    // .GET, .HEAD, .DELETE, .CONNECT, .TRACE    nothing    nil    Neither CL nor chunked
    // other                                     nothing    nil    chunked
    func testNoHeadersNoBody() throws {
        for method: HTTPMethod in [.GET, .HEAD, .DELETE, .CONNECT, .TRACE] {
            var headers: HTTPHeaders = .init()
            XCTAssertNoThrow(try headers.validate(method: method, body: nil))
            XCTAssertTrue(headers["content-length"].isEmpty)
            XCTAssertTrue(headers["transfer-encoding"].isEmpty)
        }

        for method: HTTPMethod in [.POST, .PUT] {
            var headers: HTTPHeaders = .init()
            XCTAssertNoThrow(try headers.validate(method: method, body: nil))
            // TODO: This should be CL=0 ??? https://tools.ietf.org/html/rfc7230#section-3.3.2
            XCTAssertTrue(headers["content-length"].isEmpty)
            XCTAssertTrue(headers["transfer-encoding"].contains("chunked"))
        }
    }

    // Method kind                               User sets  Body       Expectation
    // --------------------------------------------------------------------------------------
    // .GET, .HEAD, .DELETE, .CONNECT, .TRACE    nothing    not nil    Neither CL nor chunked
    // other                                     nothing    not nil    chunked
    func testNoHeadersHasBody() throws {
        for method: HTTPMethod in [.GET, .HEAD, .DELETE, .CONNECT] {
            var headers: HTTPHeaders = .init()
            XCTAssertNoThrow(try headers.validate(method: method, body: .byteBuffer(ByteBuffer(bytes: [0]))))

            // TODO: Logically, this should be a Content-Length: 1

            XCTAssertTrue(headers["content-length"].isEmpty)
            XCTAssertTrue(headers["transfer-encoding"].isEmpty)
        }

        for method: HTTPMethod in [.POST, .PUT] {
            var headers: HTTPHeaders = .init()
            XCTAssertNoThrow(try headers.validate(method: method, body: .byteBuffer(ByteBuffer(bytes: [0]))))

            // TODO: Logically, this should be a Content-Length: 1 since we know size, or chunked if we don't

            XCTAssertTrue(headers["content-length"].isEmpty)
            XCTAssertTrue(headers["transfer-encoding"].contains("chunked"))
        }

        for method: HTTPMethod in [.POST, .PUT] {
            var headers: HTTPHeaders = .init()
            let body: HTTPClient.Body = .stream { writer in
                writer.write(.byteBuffer(ByteBuffer(bytes: [0])))
            }
            XCTAssertNoThrow(try headers.validate(method: method, body: body))

            // TODO: Logically, this should be a Content-Length: 1 since we know size, or chunked if we don't

            XCTAssertTrue(headers["content-length"].isEmpty)
            XCTAssertTrue(headers["transfer-encoding"].contains("chunked"))
        }
    }

    // Method kind                               User sets         Body   Expectation
    // ------------------------------------------------------------------------------
    // .GET, .HEAD, .DELETE, .CONNECT, .TRACE    content-length    nil    CL=0
    // other                                     content-length    nil    CL=0
    func testContentLengthHeaderNoBody() throws {
        for method: HTTPMethod in [.GET, .HEAD, .DELETE, .CONNECT, .TRACE] {
            var headers: HTTPHeaders = .init([("Content-Length", "1")])
            XCTAssertNoThrow(try headers.validate(method: method, body: nil))
            // TODO: this should be Neither CL nor chunked https://tools.ietf.org/html/rfc7230#section-3.3.2
            XCTAssertEqual(headers["content-length"].first, "0")
            XCTAssertTrue(headers["transfer-encoding"].isEmpty)
        }

        for method: HTTPMethod in [.POST, .PUT] {
            var headers: HTTPHeaders = .init([("Content-Length", "1")])
            XCTAssertNoThrow(try headers.validate(method: method, body: nil))
            XCTAssertEqual(headers["content-length"].first, "0")
            XCTAssertTrue(headers["transfer-encoding"].isEmpty)
        }
    }

    // Method kind                               User sets         Body       Expectation
    // ----------------------------------------------------------------------------------
    // .GET, .HEAD, .DELETE, .CONNECT, .TRACE    content-length    not nil    CL=1
    // other                                     content-length    nit nil    CL=1
    func testContentLengthHeaderHasBody() throws {
        for method: HTTPMethod in [.GET, .HEAD, .DELETE, .CONNECT] {
            var headers: HTTPHeaders = .init([("Content-Length", "1")])
            XCTAssertNoThrow(try headers.validate(method: method, body: .byteBuffer(ByteBuffer(bytes: [0]))))
            XCTAssertEqual(headers["content-length"].first, "1")
            XCTAssertTrue(headers["transfer-encoding"].isEmpty)
        }

        for method: HTTPMethod in [.POST, .PUT] {
            var headers: HTTPHeaders = .init([("Content-Length", "1")])
            XCTAssertNoThrow(try headers.validate(method: method, body: .byteBuffer(ByteBuffer(bytes: [0]))))
            XCTAssertEqual(headers["content-length"].first, "1")
            XCTAssertTrue(headers["transfer-encoding"].isEmpty)
        }
    }

    // Method kind                               User sets                     Body   Expectation
    // ------------------------------------------------------------------------------------------
    // .GET, .HEAD, .DELETE, .CONNECT, .TRACE    transfer-encoding: chunked    nil    chunked
    // other                                     transfer-encoding: chunked    nil    chunked
    func testTransferEncodingHeaderNoBody() throws {
        for method: HTTPMethod in [.GET, .HEAD, .DELETE, .CONNECT, .TRACE] {
            var headers: HTTPHeaders = .init([("Transfer-Encoding", "chunked")])
            XCTAssertNoThrow(try headers.validate(method: method, body: nil))
            XCTAssertTrue(headers["content-length"].isEmpty)
            XCTAssertTrue(headers["transfer-encoding"].contains("chunked"))
        }

        for method: HTTPMethod in [.POST, .PUT] {
            var headers: HTTPHeaders = .init([("Transfer-Encoding", "chunked")])
            XCTAssertNoThrow(try headers.validate(method: method, body: nil))
            XCTAssertTrue(headers["content-length"].isEmpty)
            XCTAssertTrue(headers["transfer-encoding"].contains("chunked"))
        }
    }

    // Method kind                       User sets                     Body       Expectation
    // --------------------------------------------------------------------------------------
    // .GET, .HEAD, .DELETE, .CONNECT    transfer-encoding: chunked    not nil    chunked
    // other                             transfer-encoding: chunked    not nil    chunked
    func testTransferEncodingHeaderHasBody() throws {
        for method: HTTPMethod in [.GET, .HEAD, .DELETE, .CONNECT] {
            var headers: HTTPHeaders = .init([("Transfer-Encoding", "chunked")])
            XCTAssertNoThrow(try headers.validate(method: method, body: .byteBuffer(ByteBuffer(bytes: [0]))))
            XCTAssertTrue(headers["content-length"].isEmpty)
            XCTAssertTrue(headers["transfer-encoding"].contains("chunked"))
        }

        for method: HTTPMethod in [.POST, .PUT] {
            var headers: HTTPHeaders = .init([("Transfer-Encoding", "chunked")])
            XCTAssertNoThrow(try headers.validate(method: method, body: .byteBuffer(ByteBuffer(bytes: [0]))))
            XCTAssertTrue(headers["content-length"].isEmpty)
            XCTAssertTrue(headers["transfer-encoding"].contains("chunked"))
        }
    }

    // Method kind                               User sets                 Body   Expectation
    // ---------------------------------------------------------------------------------------
    // .GET, .HEAD, .DELETE, .CONNECT, .TRACE    CL & chunked (illegal)    nil    throws error
    // other                                     CL & chunked (illegal)    nil    throws error
    func testBothHeadersNoBody() throws {
        for method: HTTPMethod in [.GET, .HEAD, .DELETE, .CONNECT, .TRACE] {
            var headers: HTTPHeaders = .init([("Content-Length", "1"), ("Transfer-Encoding", "chunked")])
            XCTAssertThrowsError(try headers.validate(method: method, body: nil))
        }

        for method: HTTPMethod in [.POST, .PUT] {
            var headers: HTTPHeaders = .init([("Content-Length", "1"), ("Transfer-Encoding", "chunked")])
            XCTAssertThrowsError(try headers.validate(method: method, body: nil))
        }
    }

    // Method kind                               User sets                 Body       Expectation
    // -------------------------------------------------------------------------------------------
    // .GET, .HEAD, .DELETE, .CONNECT, .TRACE    CL & chunked (illegal)    not nil    throws error
    // other                                     CL & chunked (illegal)    not nil    throws error
    func testBothHeadersHasBody() throws {
        for method: HTTPMethod in [.GET, .HEAD, .DELETE, .CONNECT, .TRACE] {
            var headers: HTTPHeaders = .init([("Content-Length", "1"), ("Transfer-Encoding", "chunked")])
            XCTAssertThrowsError(try headers.validate(method: method, body: .byteBuffer(ByteBuffer(bytes: [0]))))
        }

        for method: HTTPMethod in [.POST, .PUT] {
            var headers: HTTPHeaders = .init([("Content-Length", "1"), ("Transfer-Encoding", "chunked")])
            XCTAssertThrowsError(try headers.validate(method: method, body: .byteBuffer(ByteBuffer(bytes: [0]))))
        }
    }
}
