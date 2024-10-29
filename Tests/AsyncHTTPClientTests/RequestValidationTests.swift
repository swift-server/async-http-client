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

import NIOCore
import NIOHTTP1
import XCTest

@testable import AsyncHTTPClient

class RequestValidationTests: XCTestCase {
    func testContentLengthHeaderIsRemovedFromGETIfNoBody() {
        var headers = HTTPHeaders([("Content-Length", "0")])
        var metadata: RequestFramingMetadata?
        XCTAssertNoThrow(metadata = try headers.validateAndSetTransportFraming(method: .GET, bodyLength: .known(0)))
        XCTAssertNil(headers.first(name: "Content-Length"))
        XCTAssertEqual(metadata?.body, .fixedSize(0))
    }

    func testContentLengthHeaderIsAddedToPOSTAndPUTWithNoBody() {
        var putHeaders = HTTPHeaders()
        var putMetadata: RequestFramingMetadata?
        XCTAssertNoThrow(
            putMetadata = try putHeaders.validateAndSetTransportFraming(method: .PUT, bodyLength: .known(0))
        )
        XCTAssertEqual(putHeaders.first(name: "Content-Length"), "0")
        XCTAssertEqual(putMetadata?.body, .fixedSize(0))

        var postHeaders = HTTPHeaders()
        var postMetadata: RequestFramingMetadata?
        XCTAssertNoThrow(
            postMetadata = try postHeaders.validateAndSetTransportFraming(method: .POST, bodyLength: .known(0))
        )
        XCTAssertEqual(postHeaders.first(name: "Content-Length"), "0")
        XCTAssertEqual(postMetadata?.body, .fixedSize(0))
    }

    func testContentLengthHeaderIsChangedIfBodyHasDifferentLength() {
        var headers = HTTPHeaders([("Content-Length", "0")])
        var metadata: RequestFramingMetadata?
        XCTAssertNoThrow(metadata = try headers.validateAndSetTransportFraming(method: .PUT, bodyLength: .known(200)))
        XCTAssertEqual(headers.first(name: "Content-Length"), "200")
        XCTAssertEqual(metadata?.body, .fixedSize(200))
    }

    func testTRACERequestMustNotHaveBody() {
        for header in [("Content-Length", "200"), ("Transfer-Encoding", "chunked")] {
            var headers = HTTPHeaders([header])
            XCTAssertThrowsError(try headers.validateAndSetTransportFraming(method: .TRACE, bodyLength: .known(200))) {
                XCTAssertEqual($0 as? HTTPClientError, .traceRequestWithBody)
            }
        }
    }

    func testGET_HEAD_DELETE_CONNECTRequestCanHaveBody() {
        // GET, HEAD, DELETE and CONNECT requests can have a payload. (though uncommon)
        let allowedMethods: [HTTPMethod] = [.GET, .HEAD, .DELETE, .CONNECT]
        var headers = HTTPHeaders()
        for method in allowedMethods {
            XCTAssertNoThrow(try headers.validateAndSetTransportFraming(method: method, bodyLength: .known(100)))
        }
    }

    func testInvalidHeaderFieldNames() {
        var headers = HTTPHeaders([
            ("Content-Length", "200"),
            ("User Agent", "Haha"),
        ])

        XCTAssertThrowsError(try headers.validateAndSetTransportFraming(method: .GET, bodyLength: .known(0))) { error in
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

        XCTAssertNoThrow(try headers.validateAndSetTransportFraming(method: .GET, bodyLength: .known(0)))
    }

    func testMetadataDetectConnectionClose() {
        var headers = HTTPHeaders([
            ("Connection", "close")
        ])
        var metadata: RequestFramingMetadata?
        XCTAssertNoThrow(metadata = try headers.validateAndSetTransportFraming(method: .GET, bodyLength: .known(0)))
        XCTAssertEqual(metadata?.connectionClose, true)
    }

    func testMetadataDefaultIsConnectionCloseIsFalse() {
        var headers = HTTPHeaders([])
        var metadata: RequestFramingMetadata?
        XCTAssertNoThrow(metadata = try headers.validateAndSetTransportFraming(method: .GET, bodyLength: .known(0)))
        XCTAssertEqual(metadata?.connectionClose, false)
    }

    // MARK: - Content-Length/Transfer-Encoding Matrix

    // Method kind                               User sets  Body   Expectation
    // ----------------------------------------------------------------------------------
    // .GET, .HEAD, .DELETE, .CONNECT, .TRACE    nothing    nil    Neither CL nor chunked
    // other                                     nothing    nil    CL=0
    func testNoHeadersNoBody() throws {
        for method: HTTPMethod in [.GET, .HEAD, .DELETE, .CONNECT, .TRACE] {
            var headers: HTTPHeaders = .init()
            var metadata: RequestFramingMetadata?
            XCTAssertNoThrow(
                metadata = try headers.validateAndSetTransportFraming(method: method, bodyLength: .known(0))
            )
            XCTAssertTrue(headers["content-length"].isEmpty)
            XCTAssertTrue(headers["transfer-encoding"].isEmpty)
            XCTAssertEqual(metadata?.body, .fixedSize(0))
        }

        for method: HTTPMethod in [.POST, .PUT] {
            var headers: HTTPHeaders = .init()
            var metadata: RequestFramingMetadata?
            XCTAssertNoThrow(
                metadata = try headers.validateAndSetTransportFraming(method: method, bodyLength: .known(0))
            )
            XCTAssertEqual(headers["content-length"].first, "0")
            XCTAssertFalse(headers["transfer-encoding"].contains("chunked"))
            XCTAssertEqual(metadata?.body, .fixedSize(0))
        }
    }

    // Method kind                               User sets  Body       Expectation
    // --------------------------------------------------------------------------------------
    // .GET, .HEAD, .DELETE, .CONNECT, .TRACE    nothing    not nil    CL or chunked
    // other                                     nothing    not nil    CL or chunked
    func testNoHeadersHasBody() throws {
        // Body length is known
        for method: HTTPMethod in [.GET, .HEAD, .DELETE, .CONNECT] {
            var headers: HTTPHeaders = .init()
            var metadata: RequestFramingMetadata?
            XCTAssertNoThrow(
                metadata = try headers.validateAndSetTransportFraming(method: method, bodyLength: .known(1))
            )
            XCTAssertEqual(headers["content-length"].first, "1")
            XCTAssertTrue(headers["transfer-encoding"].isEmpty)
            XCTAssertEqual(metadata?.body, .fixedSize(1))
        }

        // Body length is _not_ known
        for method: HTTPMethod in [.GET, .HEAD, .DELETE, .CONNECT] {
            var headers: HTTPHeaders = .init()
            var metadata: RequestFramingMetadata?
            XCTAssertNoThrow(
                metadata = try headers.validateAndSetTransportFraming(method: method, bodyLength: .unknown)
            )
            XCTAssertTrue(headers["content-length"].isEmpty)
            XCTAssertTrue(headers["transfer-encoding"].contains("chunked"))
            XCTAssertEqual(metadata?.body, .stream)
        }

        // Body length is known
        for method: HTTPMethod in [.POST, .PUT] {
            var headers: HTTPHeaders = .init()
            var metadata: RequestFramingMetadata?
            XCTAssertNoThrow(
                metadata = try headers.validateAndSetTransportFraming(method: method, bodyLength: .known(1))
            )
            XCTAssertEqual(headers["content-length"].first, "1")
            XCTAssertTrue(headers["transfer-encoding"].isEmpty)
            XCTAssertEqual(metadata?.body, .fixedSize(1))
        }

        // Body length is _not_ known
        for method: HTTPMethod in [.POST, .PUT] {
            var headers: HTTPHeaders = .init()
            var metadata: RequestFramingMetadata?
            XCTAssertNoThrow(
                metadata = try headers.validateAndSetTransportFraming(method: method, bodyLength: .unknown)
            )
            XCTAssertTrue(headers["content-length"].isEmpty)
            XCTAssertTrue(headers["transfer-encoding"].contains("chunked"))
            XCTAssertEqual(metadata?.body, .stream)
        }
    }

    // Method kind                               User sets         Body   Expectation
    // ------------------------------------------------------------------------------
    // .GET, .HEAD, .DELETE, .CONNECT, .TRACE    content-length    nil    Neither CL nor chunked
    // other                                     content-length    nil    CL=0
    func testContentLengthHeaderNoBody() throws {
        for method: HTTPMethod in [.GET, .HEAD, .DELETE, .CONNECT, .TRACE] {
            var headers: HTTPHeaders = .init([("Content-Length", "1")])
            var metadata: RequestFramingMetadata?
            XCTAssertNoThrow(
                metadata = try headers.validateAndSetTransportFraming(method: method, bodyLength: .known(0))
            )
            XCTAssertTrue(headers["content-length"].isEmpty)
            XCTAssertTrue(headers["transfer-encoding"].isEmpty)
            XCTAssertEqual(metadata?.body, .fixedSize(0))
        }

        for method: HTTPMethod in [.POST, .PUT] {
            var headers: HTTPHeaders = .init([("Content-Length", "1")])
            var metadata: RequestFramingMetadata?
            XCTAssertNoThrow(
                metadata = try headers.validateAndSetTransportFraming(method: method, bodyLength: .known(0))
            )
            XCTAssertEqual(headers["content-length"].first, "0")
            XCTAssertTrue(headers["transfer-encoding"].isEmpty)
            XCTAssertEqual(metadata?.body, .fixedSize(0))
        }
    }

    // Method kind                       User sets         Body       Expectation
    // --------------------------------------------------------------------------
    // .GET, .HEAD, .DELETE, .CONNECT    content-length    not nil    CL=1
    // other                             content-length    nit nil    CL=1
    func testContentLengthHeaderHasBody() throws {
        for method: HTTPMethod in [.GET, .HEAD, .DELETE, .CONNECT] {
            var headers: HTTPHeaders = .init([("Content-Length", "1")])
            var metadata: RequestFramingMetadata?
            XCTAssertNoThrow(
                metadata = try headers.validateAndSetTransportFraming(method: method, bodyLength: .known(1))
            )
            XCTAssertEqual(headers["content-length"].first, "1")
            XCTAssertTrue(headers["transfer-encoding"].isEmpty)
            XCTAssertEqual(metadata?.body, .fixedSize(1))
        }

        for method: HTTPMethod in [.POST, .PUT] {
            var headers: HTTPHeaders = .init([("Content-Length", "1")])
            var metadata: RequestFramingMetadata?
            XCTAssertNoThrow(
                metadata = try headers.validateAndSetTransportFraming(method: method, bodyLength: .known(1))
            )
            XCTAssertEqual(headers["content-length"].first, "1")
            XCTAssertTrue(headers["transfer-encoding"].isEmpty)
            XCTAssertEqual(metadata?.body, .fixedSize(1))
        }
    }

    // Method kind                               User sets                     Body   Expectation
    // ------------------------------------------------------------------------------------------
    // .GET, .HEAD, .DELETE, .CONNECT, .TRACE    transfer-encoding: chunked    nil    nil
    // other                                     transfer-encoding: chunked    nil    nil
    func testTransferEncodingHeaderNoBody() throws {
        for method: HTTPMethod in [.GET, .HEAD, .DELETE, .CONNECT, .TRACE] {
            var headers: HTTPHeaders = .init([("Transfer-Encoding", "chunked")])
            var metadata: RequestFramingMetadata?
            XCTAssertNoThrow(
                metadata = try headers.validateAndSetTransportFraming(method: method, bodyLength: .known(0))
            )
            XCTAssertTrue(headers["content-length"].isEmpty)
            XCTAssertFalse(headers["transfer-encoding"].contains("chunked"))
            XCTAssertEqual(metadata?.body, .fixedSize(0))
        }

        for method: HTTPMethod in [.POST, .PUT] {
            var headers: HTTPHeaders = .init([("Transfer-Encoding", "chunked")])
            var metadata: RequestFramingMetadata?
            XCTAssertNoThrow(
                metadata = try headers.validateAndSetTransportFraming(method: method, bodyLength: .known(0))
            )
            XCTAssertEqual(headers["content-length"].first, "0")
            XCTAssertFalse(headers["transfer-encoding"].contains("chunked"))
            XCTAssertEqual(metadata?.body, .fixedSize(0))
        }
    }

    // Method kind                       User sets                     Body       Expectation
    // --------------------------------------------------------------------------------------
    // .GET, .HEAD, .DELETE, .CONNECT    transfer-encoding: chunked    not nil    no header
    // other                             transfer-encoding: chunked    not nil    content-length
    func testTransferEncodingHeaderHasBody() throws {
        for method: HTTPMethod in [.GET, .HEAD, .DELETE, .CONNECT] {
            var headers: HTTPHeaders = .init([("Transfer-Encoding", "chunked")])
            XCTAssertNoThrow(try headers.validateAndSetTransportFraming(method: method, bodyLength: .known(1)))
            XCTAssertEqual(headers, ["Content-Length": "1"])
        }

        for method: HTTPMethod in [.POST, .PUT] {
            var headers: HTTPHeaders = .init([("Transfer-Encoding", "chunked")])
            XCTAssertNoThrow(try headers.validateAndSetTransportFraming(method: method, bodyLength: .known(1)))
            XCTAssertEqual(headers, ["Content-Length": "1"])
        }
    }

    // Method kind                               User sets                 Body   Expectation
    // ---------------------------------------------------------------------------------------
    // .GET, .HEAD, .DELETE, .CONNECT, .TRACE    CL & chunked (illegal)    nil    no header
    // other                                     CL & chunked (illegal)    nil    content-length
    func testBothHeadersNoBody() throws {
        for method: HTTPMethod in [.GET, .HEAD, .DELETE, .CONNECT, .TRACE] {
            var headers: HTTPHeaders = .init([("Content-Length", "1"), ("Transfer-Encoding", "chunked")])
            XCTAssertNoThrow(try headers.validateAndSetTransportFraming(method: method, bodyLength: .known(0)))
            XCTAssertEqual(headers, [:])
        }

        for method: HTTPMethod in [.POST, .PUT] {
            var headers: HTTPHeaders = .init([("Content-Length", "1"), ("Transfer-Encoding", "chunked")])
            XCTAssertNoThrow(try headers.validateAndSetTransportFraming(method: method, bodyLength: .known(0)))
            XCTAssertEqual(headers, ["Content-Length": "0"])
        }
    }

    // Method kind                               User sets                 Body       Expectation
    // -------------------------------------------------------------------------------------------
    // .TRACE    CL & chunked (illegal)    not nil    throws error
    // other                                     CL & chunked (illegal)    not nil    content-length
    func testBothHeadersHasBody() throws {
        for method: HTTPMethod in [.TRACE] {
            var headers: HTTPHeaders = .init([("Content-Length", "1"), ("Transfer-Encoding", "chunked")])
            XCTAssertThrowsError(try headers.validateAndSetTransportFraming(method: method, bodyLength: .known(1)))
        }

        for method: HTTPMethod in [.GET, .HEAD, .DELETE, .CONNECT, .POST, .PUT] {
            var headers: HTTPHeaders = .init([("Content-Length", "1"), ("Transfer-Encoding", "chunked")])
            XCTAssertNoThrow(try headers.validateAndSetTransportFraming(method: method, bodyLength: .known(1)))
            XCTAssertEqual(headers, ["Content-Length": "1"])
        }
    }

    func testHostHeaderIsSetCorrectlyInCreateRequestHead() {
        let req1 = try! HTTPClient.Request(url: "http://localhost:80/get")
        XCTAssertEqual(try req1.createRequestHead().0.headers["host"].first, "localhost")

        let req2 = try! HTTPClient.Request(url: "https://localhost/get")
        XCTAssertEqual(try req2.createRequestHead().0.headers["host"].first, "localhost")

        let req3 = try! HTTPClient.Request(url: "http://localhost:8080/get")
        XCTAssertEqual(try req3.createRequestHead().0.headers["host"].first, "localhost:8080")

        let req4 = try! HTTPClient.Request(url: "http://localhost:443/get")
        XCTAssertEqual(try req4.createRequestHead().0.headers["host"].first, "localhost:443")

        let req5 = try! HTTPClient.Request(url: "https://localhost:80/get")
        XCTAssertEqual(try req5.createRequestHead().0.headers["host"].first, "localhost:80")

        let req6 = try! HTTPClient.Request(url: "https://localhost/get", headers: ["host": "foo"])
        XCTAssertEqual(try req6.createRequestHead().0.headers["host"].first, "foo")
    }

    func testTraceMethodIsNotAllowedToHaveAFixedLengthBody() {
        var headers = HTTPHeaders()
        XCTAssertThrowsError(try headers.validateAndSetTransportFraming(method: .TRACE, bodyLength: .known(10))) {
            XCTAssertEqual($0 as? HTTPClientError, .traceRequestWithBody)
        }
    }

    func testTraceMethodIsNotAllowedToHaveADynamicLengthBody() {
        var headers = HTTPHeaders()
        XCTAssertThrowsError(try headers.validateAndSetTransportFraming(method: .TRACE, bodyLength: .unknown)) {
            XCTAssertEqual($0 as? HTTPClientError, .traceRequestWithBody)
        }
    }

    func testTransferEncodingsAreOverwrittenIfBodyLengthIsFixed() {
        var headers: HTTPHeaders = [
            "Transfer-Encoding": "gzip, chunked"
        ]
        XCTAssertNoThrow(try headers.validateAndSetTransportFraming(method: .POST, bodyLength: .known(1)))
        XCTAssertEqual(
            headers,
            [
                "Content-Length": "1"
            ]
        )
    }

    func testTransferEncodingsAreOverwrittenIfBodyLengthIsDynamic() {
        var headers: HTTPHeaders = [
            "Transfer-Encoding": "gzip, chunked"
        ]
        XCTAssertNoThrow(try headers.validateAndSetTransportFraming(method: .POST, bodyLength: .unknown))
        XCTAssertEqual(
            headers,
            [
                "Transfer-Encoding": "chunked"
            ]
        )
    }
}
