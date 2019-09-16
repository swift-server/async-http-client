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
import NIOConcurrencyHelpers
import NIOHTTP1
import XCTest

class HTTPClientInternalTests: XCTestCase {
    typealias Request = HTTPClient.Request
    typealias Task = HTTPClient.Task

    func testHTTPPartsHandler() throws {
        let channel = EmbeddedChannel()
        let recorder = RecordingHandler<HTTPClientResponsePart, HTTPClientRequestPart>()
        let task = Task<Void>(eventLoop: channel.eventLoop)

        try channel.pipeline.addHandler(recorder).wait()
        try channel.pipeline.addHandler(TaskHandler(task: task, delegate: TestHTTPDelegate(), redirectHandler: nil, ignoreUncleanSSLShutdown: false)).wait()

        var request = try Request(url: "http://localhost/get")
        request.headers.add(name: "X-Test-Header", value: "X-Test-Value")
        request.body = .string("1234")

        XCTAssertNoThrow(try channel.writeOutbound(request))
        XCTAssertEqual(3, recorder.writes.count)
        var head = HTTPRequestHead(version: HTTPVersion(major: 1, minor: 1), method: .GET, uri: "/get")
        head.headers.add(name: "X-Test-Header", value: "X-Test-Value")
        head.headers.add(name: "Host", value: "localhost")
        head.headers.add(name: "Content-Length", value: "4")
        head.headers.add(name: "Connection", value: "close")
        XCTAssertEqual(HTTPClientRequestPart.head(head), recorder.writes[0])
        let buffer = ByteBuffer.of(string: "1234")
        XCTAssertEqual(HTTPClientRequestPart.body(.byteBuffer(buffer)), recorder.writes[1])

        XCTAssertNoThrow(try channel.writeInbound(HTTPClientResponsePart.head(HTTPResponseHead(version: HTTPVersion(major: 1, minor: 1), status: HTTPResponseStatus.ok))))
        XCTAssertNoThrow(try channel.writeInbound(HTTPClientResponsePart.end(nil)))
    }

    func testHTTPPartsHandlerMultiBody() throws {
        let channel = EmbeddedChannel()
        let delegate = TestHTTPDelegate()
        let task = Task<Void>(eventLoop: channel.eventLoop)
        let handler = TaskHandler(task: task, delegate: delegate, redirectHandler: nil, ignoreUncleanSSLShutdown: false)

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

    func testProxyStreaming() throws {
        let httpBin = HttpBin()
        let httpClient = HTTPClient(eventLoopGroupProvider: .createNew)
        defer {
            try! httpClient.syncShutdown()
            httpBin.shutdown()
        }

        let body: HTTPClient.Body = .stream(length: 50) { writer in
            do {
                var request = try Request(url: "http://localhost:\(httpBin.port)/events/10/1")
                request.headers.add(name: "Accept", value: "text/event-stream")

                let delegate = HTTPClientCopyingDelegate { part in
                    writer.write(.byteBuffer(part))
                }
                return httpClient.execute(request: request, delegate: delegate).futureResult
            } catch {
                return httpClient.eventLoopGroup.next().makeFailedFuture(error)
            }
        }

        let upload = try! httpClient.post(url: "http://localhost:\(httpBin.port)/post", body: body).wait()
        let bytes = upload.body.flatMap { $0.getData(at: 0, length: $0.readableBytes) }
        let data = try! JSONDecoder().decode(RequestInfo.self, from: bytes!)

        XCTAssertEqual(.ok, upload.status)
        XCTAssertEqual("id: 0id: 1id: 2id: 3id: 4id: 5id: 6id: 7id: 8id: 9", data.data)
    }

    func testProxyStreamingFailure() throws {
        let httpBin = HttpBin()
        let httpClient = HTTPClient(eventLoopGroupProvider: .createNew)
        defer {
            try! httpClient.syncShutdown()
            httpBin.shutdown()
        }

        var body: HTTPClient.Body = .stream(length: 50) { _ in
            httpClient.eventLoopGroup.next().makeFailedFuture(HTTPClientError.invalidProxyResponse)
        }

        XCTAssertThrowsError(try httpClient.post(url: "http://localhost:\(httpBin.port)/post", body: body).wait())

        body = .stream(length: 50) { _ in
            do {
                var request = try Request(url: "http://localhost:\(httpBin.port)/events/10/1")
                request.headers.add(name: "Accept", value: "text/event-stream")

                let delegate = HTTPClientCopyingDelegate { _ in
                    httpClient.eventLoopGroup.next().makeFailedFuture(HTTPClientError.invalidProxyResponse)
                }
                return httpClient.execute(request: request, delegate: delegate).futureResult
            } catch {
                return httpClient.eventLoopGroup.next().makeFailedFuture(error)
            }
        }

        XCTAssertThrowsError(try httpClient.post(url: "http://localhost:\(httpBin.port)/post", body: body).wait())
    }

    func testUploadStreamingBackpressure() throws {
        class BackpressureTestDelegate: HTTPClientResponseDelegate {
            typealias Response = Void

            var _reads = 0
            let lock: Lock
            let promise: EventLoopPromise<Void>

            init(promise: EventLoopPromise<Void>) {
                self.lock = Lock()
                self.promise = promise
            }

            var reads: Int {
                return self.lock.withLock {
                    self._reads
                }
            }

            func didReceiveBodyPart(task: HTTPClient.Task<Response>, _ buffer: ByteBuffer) -> EventLoopFuture<Void> {
                self.lock.withLockVoid {
                    self._reads += 1
                }
                return self.promise.futureResult
            }

            func didFinishRequest(task: HTTPClient.Task<Response>) throws {}
        }

        let httpClient = HTTPClient(eventLoopGroupProvider: .createNew)
        let promise: EventLoopPromise<Channel> = httpClient.eventLoopGroup.next().makePromise()
        let httpBin = HttpBin(channelPromise: promise)

        defer {
            try! httpClient.syncShutdown()
            httpBin.shutdown()
        }

        let request = try Request(url: "http://localhost:\(httpBin.port)/custom")
        let delegate = BackpressureTestDelegate(promise: httpClient.eventLoopGroup.next().makePromise())
        let future = httpClient.execute(request: request, delegate: delegate).futureResult

        let channel = try promise.futureResult.wait()

        // Send 3 parts, but only one should be received until the future is complete
        let buffer = ByteBuffer.of(string: "1234")
        try channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buffer))).wait()
        try channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buffer))).wait()
        try channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buffer))).wait()

        XCTAssertEqual(delegate.reads, 1)

        delegate.promise.succeed(())

        try channel.writeAndFlush(HTTPServerResponsePart.end(nil)).wait()
        try future.wait()

        XCTAssertEqual(delegate.reads, 3)
    }

    func testRequestURITrailingSlash() throws {
        let request1 = try Request(url: "https://someserver.com:8888/some/path?foo=bar#ref")
        XCTAssertEqual(request1.url.uri, "/some/path?foo=bar")

        let request2 = try Request(url: "https://someserver.com:8888/some/path/?foo=bar#ref")
        XCTAssertEqual(request2.url.uri, "/some/path/?foo=bar")

        let request3 = try Request(url: "https://someserver.com:8888?foo=bar#ref")
        XCTAssertEqual(request3.url.uri, "/?foo=bar")

        let request4 = try Request(url: "https://someserver.com:8888/?foo=bar#ref")
        XCTAssertEqual(request4.url.uri, "/?foo=bar")

        let request5 = try Request(url: "https://someserver.com:8888/some/path")
        XCTAssertEqual(request5.url.uri, "/some/path")

        let request6 = try Request(url: "https://someserver.com:8888/some/path/")
        XCTAssertEqual(request6.url.uri, "/some/path/")

        let request7 = try Request(url: "https://someserver.com:8888")
        XCTAssertEqual(request7.url.uri, "/")

        let request8 = try Request(url: "https://someserver.com:8888/")
        XCTAssertEqual(request8.url.uri, "/")

        let request9 = try Request(url: "https://someserver.com:8888#ref")
        XCTAssertEqual(request9.url.uri, "/")

        let request10 = try Request(url: "https://someserver.com:8888/#ref")
        XCTAssertEqual(request10.url.uri, "/")

        let request11 = try Request(url: "https://someserver.com/some%20path")
        XCTAssertEqual(request11.url.uri, "/some%20path")
    }
}
