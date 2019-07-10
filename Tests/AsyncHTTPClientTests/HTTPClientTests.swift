//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2018-2019 Swift Server Working Group and the AsyncHTTPClient project authors
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
import NIOFoundationCompat
import NIOHTTP1
import XCTest

class HTTPClientTests: XCTestCase {
    typealias Request = HTTPClient.Request

    func testRequestURI() throws {
        let request1 = Request(url: "https://someserver.com:8888/some/path?foo=bar")!
        XCTAssertEqual(request1.host, "someserver.com")
        XCTAssertEqual(request1.url.path, "/some/path")
        XCTAssertEqual(request1.url.query!, "foo=bar")
        XCTAssertEqual(request1.port, 8888)
        XCTAssertTrue(request1.useTLS)

        let request2 = Request(url: "https://someserver.com")!
        XCTAssertEqual(request2.url.path, "")
    }

    func testBadRequestURI() throws {
        let request1 = Request(url: "file://somewhere/some/path?foo=bar")
        XCTAssertNil(request1)

        let url = URL(string: "file://somewhere/some/path?foo=bar")!
        let request2 = Request(url: url)
        XCTAssertNil(request2)
    }

    func testSchemaCasing() throws {
        let request1 = Request(url: "https://someserver.com:8888/some/path?foo=bar")!
        XCTAssertNotNil(request1)

        let request2 = Request(url: "hTTpS://someserver.com:8888/some/path?foo=bar")!
        XCTAssertNotNil(request2)
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
    
    func testGetWithSharedEventLoopGroup() throws {
        let httpBin = HttpBin()
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 8)
        let httpClient = HTTPClient(eventLoopGroupProvider: .shared(elg))
        defer {
            try! elg.syncShutdownGracefully()
            httpBin.shutdown()
        }
        
        let delegate = TestHTTPDelegate()
        let request = HTTPClient.Request(url: "http://localhost:\(httpBin.port)/events/10/1")!
        let task = httpClient.execute(request: request, delegate: delegate)
        let expectedEventLoop = task.eventLoop
        task.futureResult.whenComplete { (_) in
            XCTAssertTrue(expectedEventLoop.inEventLoop)
        }
        try task.wait()
    }

    func testPost() throws {
        let httpBin = HttpBin()
        let httpClient = HTTPClient(eventLoopGroupProvider: .createNew)
        defer {
            try! httpClient.syncShutdown()
            httpBin.shutdown()
        }

        let response = try httpClient.post(url: "http://localhost:\(httpBin.port)/post", body: .string("1234")).wait()
        let bytes = response.body.flatMap { $0.getData(at: 0, length: $0.readableBytes) }
        let data = try JSONDecoder().decode(RequestInfo.self, from: bytes!)

        XCTAssertEqual(.ok, response.status)
        XCTAssertEqual("1234", data.data)
    }

    func testGetHttps() throws {
        let httpBin = HttpBin(ssl: true)
        let httpClient = HTTPClient(eventLoopGroupProvider: .createNew,
                                    configuration: HTTPClient.Configuration(certificateVerification: .none))
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
                                    configuration: HTTPClient.Configuration(certificateVerification: .none))
        defer {
            try! httpClient.syncShutdown()
            httpBin.shutdown()
        }

        let request = Request(url: "https://localhost:\(httpBin.port)/post", method: .POST, body: .string("1234"))!
        let response = try httpClient.execute(request: request).wait()
        let bytes = response.body.flatMap { $0.getData(at: 0, length: $0.readableBytes) }
        let data = try JSONDecoder().decode(RequestInfo.self, from: bytes!)

        XCTAssertEqual(.ok, response.status)
        XCTAssertEqual("1234", data.data)
    }

    func testHttpRedirect() throws {
        let httpBin = HttpBin(ssl: false)
        let httpsBin = HttpBin(ssl: true)
        let httpClient = HTTPClient(eventLoopGroupProvider: .createNew,
                                    configuration: HTTPClient.Configuration(certificateVerification: .none, followRedirects: true))

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

    func testHttpHostRedirect() throws {
        let httpBin = HttpBin(ssl: false)
        let httpClient = HTTPClient(eventLoopGroupProvider: .createNew,
                                    configuration: HTTPClient.Configuration(certificateVerification: .none, followRedirects: true))

        defer {
            try! httpClient.syncShutdown()
            httpBin.shutdown()
        }

        let response = try httpClient.get(url: "http://localhost:\(httpBin.port)/redirect/loopback?port=\(httpBin.port)").wait()
        guard var body = response.body else {
            XCTFail("The target page should have a body containing the value of the Host header")
            return
        }
        guard let responseData = body.readData(length: body.readableBytes) else {
            XCTFail("Read data shouldn't be nil since we passed body.readableBytes to body.readData")
            return
        }
        let decoder = JSONDecoder()
        let hostName = try decoder.decode([String: String].self, from: responseData)["data"]
        XCTAssert(hostName == "127.0.0.1")
    }
    
    func testPercentEncoded() throws {
        let httpBin = HttpBin()
        let httpClient = HTTPClient(eventLoopGroupProvider: .createNew)
        defer {
            try! httpClient.syncShutdown()
            httpBin.shutdown()
        }
        
        let response = try httpClient.get(url: "http://localhost:\(httpBin.port)/percent%20encoded").wait()
        XCTAssertEqual(.ok, response.status)
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

        let body = ByteBuffer.of(string: "hello world!")

        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: "12")
        let request = Request(url: "http://localhost:\(httpBin.port)/post", method: .POST, headers: headers, body: .byteBuffer(body))!
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

        var request = Request(url: "http://localhost:\(httpBin.port)/events/10/1")!
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

        XCTAssertThrowsError(try httpClient.get(url: "http://localhost:\(httpBin.port)/close").wait(), "Should fail") { error in
            guard case let error = error as? HTTPClientError, error == .remoteConnectionClosed else {
                return XCTFail("Should fail with remoteConnectionClosed")
            }
        }
    }

    func testReadTimeout() throws {
        let httpBin = HttpBin()
        let httpClient = HTTPClient(eventLoopGroupProvider: .createNew, configuration: HTTPClient.Configuration(timeout: HTTPClient.Timeout(read: .milliseconds(150))))

        defer {
            try! httpClient.syncShutdown()
            httpBin.shutdown()
        }

        XCTAssertThrowsError(try httpClient.get(url: "http://localhost:\(httpBin.port)/wait").wait(), "Should fail") { error in
            guard case let error = error as? HTTPClientError, error == .readTimeout else {
                return XCTFail("Should fail with readTimeout")
            }
        }
    }

    func testDeadline() throws {
        let httpBin = HttpBin()
        let httpClient = HTTPClient(eventLoopGroupProvider: .createNew)

        defer {
            try! httpClient.syncShutdown()
            httpBin.shutdown()
        }

        XCTAssertThrowsError(try httpClient.get(url: "http://localhost:\(httpBin.port)/wait", deadline: .now() + .milliseconds(150)).wait(), "Should fail") { error in
            guard case let error = error as? HTTPClientError, error == .readTimeout else {
                return XCTFail("Should fail with readTimeout")
            }
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
        let request = Request(url: "http://localhost:\(httpBin.port)/wait")!
        let task = httpClient.execute(request: request, delegate: TestHTTPDelegate())

        queue.asyncAfter(deadline: .now() + .milliseconds(100)) {
            task.cancel()
        }

        XCTAssertThrowsError(try task.wait(), "Should fail") { error in
            guard case let error = error as? HTTPClientError, error == .cancelled else {
                return XCTFail("Should fail with cancelled")
            }
        }
    }

    func testProxyPlaintext() throws {
        let httpBin = HttpBin(simulateProxy: .plaintext)
        let httpClient = HTTPClient(
            eventLoopGroupProvider: .createNew,
            configuration: .init(proxy: .server(host: "localhost", port: httpBin.port))
        )
        defer {
            try! httpClient.syncShutdown()
            httpBin.shutdown()
        }
        let res = try httpClient.get(url: "http://test/ok").wait()
        XCTAssertEqual(res.status, .ok)
    }

    func testProxyTLS() throws {
        let httpBin = HttpBin(simulateProxy: .tls)
        let httpClient = HTTPClient(
            eventLoopGroupProvider: .createNew,
            configuration: .init(
                certificateVerification: .none,
                proxy: .server(host: "localhost", port: httpBin.port)
            )
        )
        defer {
            try! httpClient.syncShutdown()
            httpBin.shutdown()
        }
        let res = try httpClient.get(url: "https://test/ok").wait()
        XCTAssertEqual(res.status, .ok)
    }

    func testUploadStreaming() throws {
        let httpBin = HttpBin()
        let httpClient = HTTPClient(eventLoopGroupProvider: .createNew)
        defer {
            try! httpClient.syncShutdown()
            httpBin.shutdown()
        }

        let body: HTTPClient.Body = .stream(length: 8) { writer in
            let buffer = ByteBuffer.of(string: "1234")
            return writer.write(.byteBuffer(buffer)).flatMap {
                let buffer = ByteBuffer.of(string: "4321")
                return writer.write(.byteBuffer(buffer))
            }
        }

        let response = try httpClient.post(url: "http://localhost:\(httpBin.port)/post", body: body).wait()
        let bytes = response.body.flatMap { $0.getData(at: 0, length: $0.readableBytes) }
        let data = try JSONDecoder().decode(RequestInfo.self, from: bytes!)

        XCTAssertEqual(.ok, response.status)
        XCTAssertEqual("12344321", data.data)
    }
}
