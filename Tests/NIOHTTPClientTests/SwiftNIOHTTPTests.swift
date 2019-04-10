//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIOHTTPClient open source project
//
// Copyright (c) 2018-2019 Swift Server Working Group and the SwiftNIOHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIOHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation
import NIO
import NIOSSL
import XCTest
@testable import NIOHTTP1
@testable import NIOHTTPClient

class SwiftHTTPTests: XCTestCase {

    func testRequestURI() throws {
        let request1 = try HTTPRequest(url: "https://someserver.com:8888/some/path?foo=bar")
        XCTAssertEqual(request1.host, "someserver.com")
        XCTAssertEqual(request1.url.uri, "/some/path?foo=bar")
        XCTAssertEqual(request1.port, 8888)
        XCTAssertTrue(request1.useTLS)

        let request2 = try HTTPRequest(url: "https://someserver.com")
        XCTAssertEqual(request2.url.uri, "/")
    }

    func testHTTPPartsHandler() throws {
        let channel = EmbeddedChannel()
        let recorder = RecordingHandler<HTTPClientResponsePart, HTTPClientRequestPart>()

        try channel.pipeline.addHandler(recorder).wait()
        try channel.pipeline.addHandler(HTTPTaskHandler(delegate: TestHTTPDelegate(), promise: channel.eventLoop.makePromise(), redirectHandler: nil)).wait()

        var request = try HTTPRequest(url: "http://localhost/get")
        request.headers.add(name: "X-Test-Header", value: "X-Test-Value")
        request.body = .string("1234")

        XCTAssertNoThrow(try channel.writeOutbound(request))
        XCTAssertEqual(3, recorder.writes.count)
        var head = HTTPRequestHead(version: HTTPVersion(major: 1, minor: 1), method: .GET, uri: "/get")
        head.headers.add(name: "X-Test-Header", value: "X-Test-Value")
        head.headers.add(name: "Host", value: "localhost")
        head.headers.add(name: "Content-Length", value: "4")
        XCTAssertEqual(HTTPClientRequestPart.head(head), recorder.writes[0])
        var buffer = ByteBufferAllocator().buffer(capacity: 4)
        buffer.writeString("1234")
        XCTAssertEqual(HTTPClientRequestPart.body(.byteBuffer(buffer)), recorder.writes[1])

        XCTAssertNoThrow(try channel.writeInbound(HTTPClientResponsePart.head(HTTPResponseHead(version: HTTPVersion(major: 1, minor: 1), status: HTTPResponseStatus.ok))))
        XCTAssertNoThrow(try channel.writeInbound(HTTPClientResponsePart.end(nil)))
    }

    func testHTTPPartsHandlerMultiBody() throws {
        let channel = EmbeddedChannel()
        let delegate = TestHTTPDelegate()
        let handler = HTTPTaskHandler(delegate: delegate, promise: channel.eventLoop.makePromise(), redirectHandler: nil)

        try channel.pipeline.addHandler(handler).wait()

        handler.state = .sent
        var body = channel.allocator.buffer(capacity: 4)
        body.writeStaticString("1234")

        XCTAssertNoThrow(try channel.writeInbound(HTTPClientResponsePart.head(HTTPResponseHead(version: HTTPVersion(major: 1, minor: 1), status: HTTPResponseStatus.ok))))
        XCTAssertNoThrow(try channel.writeInbound(HTTPClientResponsePart.body(body)))
        XCTAssertNoThrow(try channel.writeInbound(HTTPClientResponsePart.body(body)))

        switch delegate.state {
        case .body(_, let body):
            XCTAssertEqual(8, body.readableBytes)
        default:
            XCTFail("Expecting .body")
        }
    }

    func testGet() throws {
        let httpBin = HttpBin()
        let httpClient = HTTPClient(eventLoopGroupProvider: .createNew)
        defer {
            try! httpClient.syncShutdown()
            httpBin.shutdown()
        }

        let response = try httpClient.get(url: "http://localhost:\(httpBin.port)/get").wait()
        XCTAssertEqual(.ok, response.status)
    }

    func testPost() throws {
        let httpBin = HttpBin()
        let httpClient = HTTPClient(eventLoopGroupProvider: .createNew)
        defer {
            try! httpClient.syncShutdown()
            httpBin.shutdown()
        }

        let response = try httpClient.post(url: "http://localhost:\(httpBin.port)/post", body: .string("1234")).wait()
        let bytes = response.body!.withUnsafeReadableBytes {
            Data(bytes: $0.baseAddress!, count: $0.count)
        }
        let data = try JSONDecoder().decode(RequestInfo.self, from: bytes)

        XCTAssertEqual(.ok, response.status)
        XCTAssertEqual("1234", data.data)
    }

    func testGetHttps() throws {
        let httpBin = HttpBin(ssl: true)
        let httpClient = HTTPClient(eventLoopGroupProvider: .createNew,
                                    configuration: HTTPClientConfiguration(certificateVerification: .none))
        defer {
            try! httpClient.syncShutdown()
            httpBin.shutdown()
        }

        let response = try httpClient.get(url: "https://localhost:\(httpBin.port)/get").wait()
        XCTAssertEqual(.ok, response.status)
    }

    func testPostHttps() throws {
        let httpBin = HttpBin(ssl: true)
        let httpClient = HTTPClient(eventLoopGroupProvider: .createNew,
                                    configuration: HTTPClientConfiguration(certificateVerification: .none))
        defer {
            try! httpClient.syncShutdown()
            httpBin.shutdown()
        }

        let request = try HTTPRequest(url: "https://localhost:\(httpBin.port)/post", method: .POST, body: .string("1234"))

        let response = try httpClient.execute(request: request).wait()
        let bytes = response.body!.withUnsafeReadableBytes {
            Data(bytes: $0.baseAddress!, count: $0.count)
        }
        let data = try JSONDecoder().decode(RequestInfo.self, from: bytes)

        XCTAssertEqual(.ok, response.status)
        XCTAssertEqual("1234", data.data)
    }

    func testHttpRedirect() throws {
        let httpBin = HttpBin(ssl: false)
        let httpsBin = HttpBin(ssl: true)
        let httpClient = HTTPClient(eventLoopGroupProvider: .createNew,
                                    configuration: HTTPClientConfiguration(certificateVerification: .none, followRedirects: true))

        defer {
            try! httpClient.syncShutdown()
            httpBin.shutdown()
            httpsBin.shutdown()
        }

        var response = try httpClient.get(url: "http://localhost:\(httpBin.port)/redirect/302").wait()
        XCTAssertEqual(response.status, .ok)

        response = try httpClient.get(url: "http://localhost:\(httpBin.port)/redirect/https?port=\(httpsBin.port)").wait()
        XCTAssertEqual(response.status, .ok)
    }

    func testMultipleContentLengthHeaders() throws {
        let httpClient = HTTPClient(eventLoopGroupProvider: .createNew)
        defer {
            try! httpClient.syncShutdown()
        }
        let httpBin = HttpBin()
        defer {
            httpBin.shutdown()
        }

        let allocator = ByteBufferAllocator()
        var body = allocator.buffer(capacity: 100)
        body.writeString("hello world!")

        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: "12")
        let request = try HTTPRequest(url: "http://localhost:\(httpBin.port)/post", method: .POST, headers: headers, body: .byteBuffer(body))
        let response = try httpClient.execute(request: request).wait()
        // if the library adds another content length header we'll get a bad request error.
        XCTAssertEqual(.ok, response.status)
    }

    func testStreaming() throws {
        let httpBin = HttpBin()
        let httpClient = HTTPClient(eventLoopGroupProvider: .createNew)
        defer {
            try! httpClient.syncShutdown()
            httpBin.shutdown()
        }

        var request = try HTTPRequest(url: "http://localhost:\(httpBin.port)/events/10/1")
        request.headers.add(name: "Accept", value: "text/event-stream")

        let delegate = CountingDelegate()
        let count = try httpClient.execute(request: request, delegate: delegate).wait()

        XCTAssertEqual(10, count)
    }

    func testRemoteClose() throws {
        let httpBin = HttpBin()
        let httpClient = HTTPClient(eventLoopGroupProvider: .createNew)

        defer {
            try! httpClient.syncShutdown()
            httpBin.shutdown()
        }

        do {
            _ = try httpClient.get(url: "http://localhost:\(httpBin.port)/close").wait()
            XCTFail("Should fail with RemoteConnectionClosedError")
        } catch _ as HTTPClientErrors.RemoteConnectionClosedError {
            // ok
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testReadTimeout() throws {
        let httpBin = HttpBin()
        let httpClient = HTTPClient(eventLoopGroupProvider: .createNew, configuration: HTTPClientConfiguration(timeout: Timeout(readTimeout: .milliseconds(150))))

        defer {
            try! httpClient.syncShutdown()
            httpBin.shutdown()
        }

        do {
            _ = try httpClient.get(url: "http://localhost:\(httpBin.port)/wait").wait()
            XCTFail("Should fail with: ReadTimeoutError")
        } catch _ as HTTPClientErrors.ReadTimeoutError {
            // ok
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCancel() throws {
        let httpBin = HttpBin()
        let httpClient = HTTPClient(eventLoopGroupProvider: .createNew)

        defer {
            try! httpClient.syncShutdown()
            httpBin.shutdown()
        }

        let queue = DispatchQueue(label: "nio-test")
        let request = try HTTPRequest(url: "http://localhost:\(httpBin.port)/wait")
        let task = httpClient.execute(request: request, delegate: TestHTTPDelegate())

        queue.asyncAfter(deadline: .now() + .milliseconds(100)) {
            task.cancel()
        }

        do {
            _ = try task.wait()
            XCTFail("Should fail with: CancelledError")
        } catch _ as HTTPClientErrors.CancelledError {
            // ok
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
