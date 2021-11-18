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
import NIOCore
import NIOHTTP1
import XCTest

class RequestValidationTests: XCTestCase {
    func testContentLengthHeaderIsRemovedFromGETIfNoBody() {
        var headers = HTTPHeaders([("Content-Length", "0")])
        var metadata: RequestFramingMetadata?
        XCTAssertNoThrow(metadata = try headers.validateAndFixTransportFraming(method: .GET, bodyLength: .fixed(length: 0)))
        XCTAssertNil(headers.first(name: "Content-Length"))
        XCTAssertEqual(metadata?.body, .fixedSize(0))
    }

    func testContentLengthHeaderIsAddedToPOSTAndPUTWithNoBody() {
        var putHeaders = HTTPHeaders()
        var putMetadata: RequestFramingMetadata?
        XCTAssertNoThrow(putMetadata = try putHeaders.validateAndFixTransportFraming(method: .PUT, bodyLength: .fixed(length: 0)))
        XCTAssertEqual(putHeaders.first(name: "Content-Length"), "0")
        XCTAssertEqual(putMetadata?.body, .fixedSize(0))

        var postHeaders = HTTPHeaders()
        var postMetadata: RequestFramingMetadata?
        XCTAssertNoThrow(postMetadata = try postHeaders.validateAndFixTransportFraming(method: .POST, bodyLength: .fixed(length: 0)))
        XCTAssertEqual(postHeaders.first(name: "Content-Length"), "0")
        XCTAssertEqual(postMetadata?.body, .fixedSize(0))
    }

    func testContentLengthHeaderIsChangedIfBodyHasDifferentLength() {
        var headers = HTTPHeaders([("Content-Length", "0")])
        var metadata: RequestFramingMetadata?
        XCTAssertNoThrow(metadata = try headers.validateAndFixTransportFraming(method: .PUT, bodyLength: .fixed(length: 200)))
        XCTAssertEqual(headers.first(name: "Content-Length"), "200")
        XCTAssertEqual(metadata?.body, .fixedSize(200))
    }

    func testTRACERequestMustNotHaveBody() {
        for header in [("Content-Length", "200"), ("Transfer-Encoding", "chunked")] {
            var headers = HTTPHeaders([header])
            XCTAssertThrowsError(try headers.validateAndFixTransportFraming(method: .TRACE, bodyLength: .fixed(length: 200))) {
                XCTAssertEqual($0 as? HTTPClientError, .traceRequestWithBody)
            }
        }
    }

    func testGET_HEAD_DELETE_CONNECTRequestCanHaveBody() {
        // GET, HEAD, DELETE and CONNECT requests can have a payload. (though uncommon)
        let allowedMethods: [HTTPMethod] = [.GET, .HEAD, .DELETE, .CONNECT]
        var headers = HTTPHeaders()
        for method in allowedMethods {
            XCTAssertNoThrow(try headers.validateAndFixTransportFraming(method: method, bodyLength: .fixed(length: 100)))
        }
    }

    func testInvalidHeaderFieldNames() {
        var headers = HTTPHeaders([
            ("Content-Length", "200"),
            ("User Agent", "Haha"),
        ])

        XCTAssertThrowsError(try headers.validateAndFixTransportFraming(method: .GET, bodyLength: .fixed(length: 0))) { error in
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

        XCTAssertNoThrow(try headers.validateAndFixTransportFraming(method: .GET, bodyLength: .fixed(length: 0)))
    }

    func testMetadataDetectConnectionClose() {
        var headers = HTTPHeaders([
            ("Connection", "close"),
        ])
        var metadata: RequestFramingMetadata?
        XCTAssertNoThrow(metadata = try headers.validateAndFixTransportFraming(method: .GET, bodyLength: .fixed(length: 0)))
        XCTAssertEqual(metadata?.connectionClose, true)
    }

    func testMetadataDefaultIsConnectionCloseIsFalse() {
        var headers = HTTPHeaders([])
        var metadata: RequestFramingMetadata?
        XCTAssertNoThrow(metadata = try headers.validateAndFixTransportFraming(method: .GET, bodyLength: .fixed(length: 0)))
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
            XCTAssertNoThrow(metadata = try headers.validateAndFixTransportFraming(method: method, bodyLength: .fixed(length: 0)))
            XCTAssertTrue(headers["content-length"].isEmpty)
            XCTAssertTrue(headers["transfer-encoding"].isEmpty)
            XCTAssertEqual(metadata?.body, .fixedSize(0))
        }

        for method: HTTPMethod in [.POST, .PUT] {
            var headers: HTTPHeaders = .init()
            var metadata: RequestFramingMetadata?
            XCTAssertNoThrow(metadata = try headers.validateAndFixTransportFraming(method: method, bodyLength: .fixed(length: 0)))
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
            XCTAssertNoThrow(metadata = try headers.validateAndFixTransportFraming(method: method, bodyLength: .fixed(length: 1)))
            XCTAssertEqual(headers["content-length"].first, "1")
            XCTAssertTrue(headers["transfer-encoding"].isEmpty)
            XCTAssertEqual(metadata?.body, .fixedSize(1))
        }

        // Body length is _not_ known
        for method: HTTPMethod in [.GET, .HEAD, .DELETE, .CONNECT] {
            var headers: HTTPHeaders = .init()
            var metadata: RequestFramingMetadata?
            XCTAssertNoThrow(metadata = try headers.validateAndFixTransportFraming(method: method, bodyLength: .dynamic))
            XCTAssertTrue(headers["content-length"].isEmpty)
            XCTAssertTrue(headers["transfer-encoding"].contains("chunked"))
            XCTAssertEqual(metadata?.body, .stream)
        }

        // Body length is known
        for method: HTTPMethod in [.POST, .PUT] {
            var headers: HTTPHeaders = .init()
            var metadata: RequestFramingMetadata?
            XCTAssertNoThrow(metadata = try headers.validateAndFixTransportFraming(method: method, bodyLength: .fixed(length: 1)))
            XCTAssertEqual(headers["content-length"].first, "1")
            XCTAssertTrue(headers["transfer-encoding"].isEmpty)
            XCTAssertEqual(metadata?.body, .fixedSize(1))
        }

        // Body length is _not_ known
        for method: HTTPMethod in [.POST, .PUT] {
            var headers: HTTPHeaders = .init()
            var metadata: RequestFramingMetadata?
            XCTAssertNoThrow(metadata = try headers.validateAndFixTransportFraming(method: method, bodyLength: .dynamic))
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
            XCTAssertNoThrow(metadata = try headers.validateAndFixTransportFraming(method: method, bodyLength: .fixed(length: 0)))
            XCTAssertTrue(headers["content-length"].isEmpty)
            XCTAssertTrue(headers["transfer-encoding"].isEmpty)
            XCTAssertEqual(metadata?.body, .fixedSize(0))
        }

        for method: HTTPMethod in [.POST, .PUT] {
            var headers: HTTPHeaders = .init([("Content-Length", "1")])
            var metadata: RequestFramingMetadata?
            XCTAssertNoThrow(metadata = try headers.validateAndFixTransportFraming(method: method, bodyLength: .fixed(length: 0)))
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
            XCTAssertNoThrow(metadata = try headers.validateAndFixTransportFraming(method: method, bodyLength: .fixed(length: 1)))
            XCTAssertEqual(headers["content-length"].first, "1")
            XCTAssertTrue(headers["transfer-encoding"].isEmpty)
            XCTAssertEqual(metadata?.body, .fixedSize(1))
        }

        for method: HTTPMethod in [.POST, .PUT] {
            var headers: HTTPHeaders = .init([("Content-Length", "1")])
            var metadata: RequestFramingMetadata?
            XCTAssertNoThrow(metadata = try headers.validateAndFixTransportFraming(method: method, bodyLength: .fixed(length: 1)))
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
            XCTAssertNoThrow(metadata = try headers.validateAndFixTransportFraming(method: method, bodyLength: .fixed(length: 0)))
            XCTAssertTrue(headers["content-length"].isEmpty)
            XCTAssertFalse(headers["transfer-encoding"].contains("chunked"))
            XCTAssertEqual(metadata?.body, .fixedSize(0))
        }

        for method: HTTPMethod in [.POST, .PUT] {
            var headers: HTTPHeaders = .init([("Transfer-Encoding", "chunked")])
            var metadata: RequestFramingMetadata?
            XCTAssertNoThrow(metadata = try headers.validateAndFixTransportFraming(method: method, bodyLength: .fixed(length: 0)))
            XCTAssertEqual(headers["content-length"].first, "0")
            XCTAssertFalse(headers["transfer-encoding"].contains("chunked"))
            XCTAssertEqual(metadata?.body, .fixedSize(0))
        }
    }

    // Method kind                       User sets                     Body       Expectation
    // --------------------------------------------------------------------------------------
    // .GET, .HEAD, .DELETE, .CONNECT    transfer-encoding: chunked    not nil    chunked
    // other                             transfer-encoding: chunked    not nil    chunked
    func testTransferEncodingHeaderHasBody() throws {
        for method: HTTPMethod in [.GET, .HEAD, .DELETE, .CONNECT] {
            var headers: HTTPHeaders = .init([("Transfer-Encoding", "chunked")])
            var metadata: RequestFramingMetadata?
            XCTAssertNoThrow(metadata = try headers.validateAndFixTransportFraming(method: method, bodyLength: .fixed(length: 1)))
            XCTAssertTrue(headers["content-length"].isEmpty)
            XCTAssertTrue(headers["transfer-encoding"].contains("chunked"))
            XCTAssertEqual(metadata?.body, .stream)
        }

        for method: HTTPMethod in [.POST, .PUT] {
            var headers: HTTPHeaders = .init([("Transfer-Encoding", "chunked")])
            var metadata: RequestFramingMetadata?
            XCTAssertNoThrow(metadata = try headers.validateAndFixTransportFraming(method: method, bodyLength: .fixed(length: 1)))
            XCTAssertTrue(headers["content-length"].isEmpty)
            XCTAssertTrue(headers["transfer-encoding"].contains("chunked"))
            XCTAssertEqual(metadata?.body, .stream)
        }
    }

    // Method kind                               User sets                 Body   Expectation
    // ---------------------------------------------------------------------------------------
    // .GET, .HEAD, .DELETE, .CONNECT, .TRACE    CL & chunked (illegal)    nil    throws error
    // other                                     CL & chunked (illegal)    nil    throws error
    func testBothHeadersNoBody() throws {
        for method: HTTPMethod in [.GET, .HEAD, .DELETE, .CONNECT, .TRACE] {
            var headers: HTTPHeaders = .init([("Content-Length", "1"), ("Transfer-Encoding", "chunked")])
            XCTAssertThrowsError(try headers.validateAndFixTransportFraming(method: method, bodyLength: .fixed(length: 0)))
        }

        for method: HTTPMethod in [.POST, .PUT] {
            var headers: HTTPHeaders = .init([("Content-Length", "1"), ("Transfer-Encoding", "chunked")])
            XCTAssertThrowsError(try headers.validateAndFixTransportFraming(method: method, bodyLength: .fixed(length: 0)))
        }
    }

    // Method kind                               User sets                 Body       Expectation
    // -------------------------------------------------------------------------------------------
    // .GET, .HEAD, .DELETE, .CONNECT, .TRACE    CL & chunked (illegal)    not nil    throws error
    // other                                     CL & chunked (illegal)    not nil    throws error
    func testBothHeadersHasBody() throws {
        for method: HTTPMethod in [.GET, .HEAD, .DELETE, .CONNECT, .TRACE] {
            var headers: HTTPHeaders = .init([("Content-Length", "1"), ("Transfer-Encoding", "chunked")])
            XCTAssertThrowsError(try headers.validateAndFixTransportFraming(method: method, bodyLength: .fixed(length: 1)))
        }

        for method: HTTPMethod in [.POST, .PUT] {
            var headers: HTTPHeaders = .init([("Content-Length", "1"), ("Transfer-Encoding", "chunked")])
            XCTAssertThrowsError(try headers.validateAndFixTransportFraming(method: method, bodyLength: .fixed(length: 1)))
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
        XCTAssertThrowsError(try headers.validateAndFixTransportFraming(method: .TRACE, bodyLength: .fixed(length: 10)))
    }

    func testTraceMethodIsNotAllowedToHaveADynamicLengthBody() {
        var headers = HTTPHeaders()
        XCTAssertThrowsError(try headers.validateAndFixTransportFraming(method: .TRACE, bodyLength: .dynamic))
    }

    func testTransferEncodingsArePreservedIfBodyLengthIsFixed() {
        var headers: HTTPHeaders = [
            "Transfer-Encoding": "gzip, chunked",
        ]
        XCTAssertNoThrow(try headers.validateAndFixTransportFraming(method: .POST, bodyLength: .fixed(length: 1)))
        XCTAssertEqual(headers, [
            "Transfer-Encoding": "gzip, chunked",
        ])
    }

    func testTransferEncodingsArePreservedIfBodyLengthIsDynamic() {
        var headers: HTTPHeaders = [
            "Transfer-Encoding": "gzip, chunked",
        ]
        XCTAssertNoThrow(try headers.validateAndFixTransportFraming(method: .POST, bodyLength: .dynamic))
        XCTAssertEqual(headers, [
            "Transfer-Encoding": "gzip, chunked",
        ])
    }

    func testTransferEncodingValidation() {
        XCTAssertNoThrow(try HTTPHeaders.validateTransferEncoding([String]()))
        XCTAssertNoThrow(try HTTPHeaders.validateTransferEncoding(["Chunked"]))
        XCTAssertNoThrow(try HTTPHeaders.validateTransferEncoding(["chunked"]))
        XCTAssertNoThrow(try HTTPHeaders.validateTransferEncoding(["gzip", "chunked"]))
        XCTAssertNoThrow(try HTTPHeaders.validateTransferEncoding(["deflat", "chunked"]))

        XCTAssertThrowsError(try HTTPHeaders.validateTransferEncoding(["gzip"])) {
            XCTAssertEqual($0 as? HTTPClientError, .transferEncodingSpecifiedButChunkedIsNotTheFinalEncoding)
        }
        XCTAssertThrowsError(try HTTPHeaders.validateTransferEncoding(["chunked", "Chunked"])) {
            XCTAssertEqual($0 as? HTTPClientError, .chunkedSpecifiedMultipleTimes)
        }
        XCTAssertThrowsError(try HTTPHeaders.validateTransferEncoding(["chunked", "chunked"])) {
            XCTAssertEqual($0 as? HTTPClientError, .chunkedSpecifiedMultipleTimes)
        }
        XCTAssertThrowsError(try HTTPHeaders.validateTransferEncoding(["chunked", "gzip"])) {
            XCTAssertEqual($0 as? HTTPClientError, .transferEncodingSpecifiedButChunkedIsNotTheFinalEncoding)
        }
        XCTAssertThrowsError(try HTTPHeaders.validateTransferEncoding(["chunked", "gzip", "chunked"])) {
            let error = $0 as? HTTPClientError
            XCTAssertTrue(
                error == .chunkedSpecifiedMultipleTimes ||
                    error == .transferEncodingSpecifiedButChunkedIsNotTheFinalEncoding,
                "\(error as Any) must be \(HTTPClientError.chunkedSpecifiedMultipleTimes) or \(HTTPClientError.transferEncodingSpecifiedButChunkedIsNotTheFinalEncoding)"
            )
        }
    }
}
