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
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOPosix
import NIOTestUtils
import XCTest

class HTTPClientInternalTests: XCTestCase {
    typealias Request = HTTPClient.Request
    typealias Task = HTTPClient.Task

    var serverGroup: EventLoopGroup!
    var clientGroup: EventLoopGroup!

    override func setUp() {
        XCTAssertNil(self.clientGroup)
        XCTAssertNil(self.serverGroup)
        self.serverGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.clientGroup = getDefaultEventLoopGroup(numberOfThreads: 1)
    }

    override func tearDown() {
        XCTAssertNotNil(self.serverGroup)
        XCTAssertNoThrow(try self.serverGroup.syncShutdownGracefully())
        XCTAssertNotNil(self.clientGroup)
        XCTAssertNoThrow(try self.clientGroup.syncShutdownGracefully())
        self.clientGroup = nil
        self.serverGroup = nil
    }

    func testHTTPPartsHandler() throws {
        let channel = EmbeddedChannel()
        let recorder = RecordingHandler<HTTPClientResponsePart, HTTPClientRequestPart>()
        let task = Task<Void>(eventLoop: channel.eventLoop, logger: HTTPClient.loggingDisabled)

        try channel.pipeline.addHandler(recorder).wait()
        try channel.pipeline.addHandler(TaskHandler(task: task,
                                                    kind: .host,
                                                    delegate: TestHTTPDelegate(),
                                                    redirectHandler: nil,
                                                    ignoreUncleanSSLShutdown: false,
                                                    logger: HTTPClient.loggingDisabled)).wait()

        var request = try Request(url: "http://localhost:8080/get")
        request.headers.add(name: "X-Test-Header", value: "X-Test-Value")
        request.body = .string("1234")

        XCTAssertNoThrow(try channel.writeOutbound(request))
        XCTAssertEqual(3, recorder.writes.count)
        var head = HTTPRequestHead(version: HTTPVersion(major: 1, minor: 1), method: .GET, uri: "/get")
        head.headers.add(name: "X-Test-Header", value: "X-Test-Value")
        head.headers.add(name: "Host", value: "localhost:8080")
        head.headers.add(name: "Content-Length", value: "4")
        XCTAssertEqual(HTTPClientRequestPart.head(head), recorder.writes[0])
        let buffer = channel.allocator.buffer(string: "1234")
        XCTAssertEqual(HTTPClientRequestPart.body(.byteBuffer(buffer)), recorder.writes[1])

        XCTAssertNoThrow(try channel.writeInbound(HTTPClientResponsePart.head(HTTPResponseHead(version: HTTPVersion(major: 1, minor: 1), status: HTTPResponseStatus.ok))))
        XCTAssertNoThrow(try channel.writeInbound(HTTPClientResponsePart.end(nil)))
    }

    func testBadHTTPRequest() throws {
        let channel = EmbeddedChannel()
        let recorder = RecordingHandler<HTTPClientResponsePart, HTTPClientRequestPart>()
        let task = Task<Void>(eventLoop: channel.eventLoop, logger: HTTPClient.loggingDisabled)

        XCTAssertNoThrow(try channel.pipeline.addHandler(recorder).wait())
        XCTAssertNoThrow(try channel.pipeline.addHandler(TaskHandler(task: task,
                                                                     kind: .host,
                                                                     delegate: TestHTTPDelegate(),
                                                                     redirectHandler: nil,
                                                                     ignoreUncleanSSLShutdown: false,
                                                                     logger: HTTPClient.loggingDisabled)).wait())

        var request = try Request(url: "http://localhost/get")
        request.headers.add(name: "X-Test-Header", value: "X-Test-Value")
        request.headers.add(name: "Transfer-Encoding", value: "identity")
        request.body = .string("1234")

        XCTAssertThrowsError(try channel.writeOutbound(request)) { error in
            XCTAssertEqual(HTTPClientError.identityCodingIncorrectlyPresent, error as? HTTPClientError)
        }
    }

    func testHostPort() throws {
        let channel = EmbeddedChannel()
        let recorder = RecordingHandler<HTTPClientResponsePart, HTTPClientRequestPart>()
        let task = Task<Void>(eventLoop: channel.eventLoop, logger: HTTPClient.loggingDisabled)

        try channel.pipeline.addHandler(recorder).wait()
        try channel.pipeline.addHandler(TaskHandler(task: task,
                                                    kind: .host,
                                                    delegate: TestHTTPDelegate(),
                                                    redirectHandler: nil,
                                                    ignoreUncleanSSLShutdown: false,
                                                    logger: HTTPClient.loggingDisabled)).wait()

        let request1 = try Request(url: "http://localhost:80/get")
        XCTAssertNoThrow(try channel.writeOutbound(request1))
        let request2 = try Request(url: "https://localhost/get")
        XCTAssertNoThrow(try channel.writeOutbound(request2))
        let request3 = try Request(url: "http://localhost:8080/get")
        XCTAssertNoThrow(try channel.writeOutbound(request3))
        let request4 = try Request(url: "http://localhost:443/get")
        XCTAssertNoThrow(try channel.writeOutbound(request4))
        let request5 = try Request(url: "https://localhost:80/get")
        XCTAssertNoThrow(try channel.writeOutbound(request5))

        let head1 = HTTPRequestHead(version: HTTPVersion(major: 1, minor: 1), method: .GET, uri: "/get", headers: ["host": "localhost"])
        XCTAssertEqual(HTTPClientRequestPart.head(head1), recorder.writes[0])
        let head2 = HTTPRequestHead(version: HTTPVersion(major: 1, minor: 1), method: .GET, uri: "/get", headers: ["host": "localhost"])
        XCTAssertEqual(HTTPClientRequestPart.head(head2), recorder.writes[2])
        let head3 = HTTPRequestHead(version: HTTPVersion(major: 1, minor: 1), method: .GET, uri: "/get", headers: ["host": "localhost:8080"])
        XCTAssertEqual(HTTPClientRequestPart.head(head3), recorder.writes[4])
        let head4 = HTTPRequestHead(version: HTTPVersion(major: 1, minor: 1), method: .GET, uri: "/get", headers: ["host": "localhost:443"])
        XCTAssertEqual(HTTPClientRequestPart.head(head4), recorder.writes[6])
        let head5 = HTTPRequestHead(version: HTTPVersion(major: 1, minor: 1), method: .GET, uri: "/get", headers: ["host": "localhost:80"])
        XCTAssertEqual(HTTPClientRequestPart.head(head5), recorder.writes[8])
    }

    func testHTTPPartsHandlerMultiBody() throws {
        let channel = EmbeddedChannel()
        let delegate = TestHTTPDelegate()
        let task = Task<Void>(eventLoop: channel.eventLoop, logger: HTTPClient.loggingDisabled)
        let handler = TaskHandler(task: task,
                                  kind: .host,
                                  delegate: delegate,
                                  redirectHandler: nil,
                                  ignoreUncleanSSLShutdown: false,
                                  logger: HTTPClient.loggingDisabled)

        try channel.pipeline.addHandler(handler).wait()

        handler.state = .bodySentWaitingResponseHead
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

    func testHTTPResponseHeadBeforeRequestHead() throws {
        let channel = EmbeddedChannel()
        XCTAssertNoThrow(try channel.connect(to: try SocketAddress(unixDomainSocketPath: "/fake")).wait())

        let delegate = TestHTTPDelegate()
        let task = Task<Void>(eventLoop: channel.eventLoop, logger: HTTPClient.loggingDisabled)
        let handler = TaskHandler(task: task,
                                  kind: .host,
                                  delegate: delegate,
                                  redirectHandler: nil,
                                  ignoreUncleanSSLShutdown: false,
                                  logger: HTTPClient.loggingDisabled)

        XCTAssertNoThrow(try channel.pipeline.addHTTPClientHandlers().wait())
        XCTAssertNoThrow(try channel.pipeline.addHandler(handler).wait())

        XCTAssertNoThrow(try channel.writeInbound(ByteBuffer(string: "HTTP/1.0 200 OK\r\n\r\n")))

        XCTAssertThrowsError(try task.futureResult.wait()) { error in
            XCTAssertEqual(error as? NIOHTTPDecoderError, NIOHTTPDecoderError.unsolicitedResponse)
        }
    }

    func testHTTPResponseDoubleHead() throws {
        let channel = EmbeddedChannel()
        XCTAssertNoThrow(try channel.connect(to: try SocketAddress(unixDomainSocketPath: "/fake")).wait())

        let delegate = TestHTTPDelegate()
        let task = Task<Void>(eventLoop: channel.eventLoop, logger: HTTPClient.loggingDisabled)
        let handler = TaskHandler(task: task,
                                  kind: .host,
                                  delegate: delegate,
                                  redirectHandler: nil,
                                  ignoreUncleanSSLShutdown: false,
                                  logger: HTTPClient.loggingDisabled)

        XCTAssertNoThrow(try channel.pipeline.addHTTPClientHandlers().wait())
        XCTAssertNoThrow(try channel.pipeline.addHandler(handler).wait())

        let request = try HTTPClient.Request(url: "http://localhost/get")
        XCTAssertNoThrow(try channel.writeOutbound(request))

        XCTAssertNoThrow(try channel.writeInbound(ByteBuffer(string: "HTTP/1.0 200 OK\r\nHTTP/1.0 200 OK\r\n\r\n")))

        XCTAssertThrowsError(try task.futureResult.wait()) { error in
            XCTAssertEqual((error as? HTTPParserError)?.debugDescription, "invalid character in header")
        }
    }

    func testRequestFinishesAfterRedirectIfServerRespondsBeforeClientFinishes() throws {
        let channel = EmbeddedChannel()

        var request = try Request(url: "http://localhost:8080/get")
        // This promise is needed to force task handler to process incoming redirecting head before finishing sending the request
        let promise = channel.eventLoop.makePromise(of: Void.self)
        request.body = .stream(length: 6) { writer in
            promise.futureResult.flatMap {
                writer.write(.byteBuffer(ByteBuffer(string: "helllo")))
            }
        }

        let task = Task<Void>(eventLoop: channel.eventLoop, logger: HTTPClient.loggingDisabled)
        let redirecter = RedirectHandler<Void>(request: request) { _ in
            task
        }

        let handler = TaskHandler(task: task,
                                  kind: .host,
                                  delegate: TestHTTPDelegate(),
                                  redirectHandler: redirecter,
                                  ignoreUncleanSSLShutdown: false,
                                  logger: HTTPClient.loggingDisabled)

        XCTAssertNoThrow(try channel.pipeline.addHTTPClientHandlers().wait())
        XCTAssertNoThrow(try channel.pipeline.addHandler(handler).wait())

        let future = channel.write(request)
        channel.flush()

        XCTAssertNoThrow(XCTAssertNotNil(try channel.readOutbound(as: ByteBuffer.self))) // expecting to read head from the client
        // sending redirect before client finishesh processing the request
        XCTAssertNoThrow(try channel.writeInbound(ByteBuffer(string: "HTTP/1.1 302 Found\r\nLocation: /follow\r\n\r\n")))
        channel.flush()

        promise.succeed(())

        // we expect client to fully send us all bytes
        XCTAssertEqual(try channel.readOutbound(as: ByteBuffer.self), ByteBuffer(string: "helllo"))
        XCTAssertEqual(try channel.readOutbound(as: ByteBuffer.self), ByteBuffer(string: ""))
        XCTAssertNoThrow(try channel.writeInbound(ByteBuffer(string: "\r\n")))

        XCTAssertNoThrow(try future.wait())
    }

    func testProxyStreaming() throws {
        let httpBin = HTTPBin()
        let httpClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup))
        defer {
            XCTAssertNoThrow(try httpClient.syncShutdown(requiresCleanClose: true))
            XCTAssertNoThrow(try httpBin.shutdown())
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
        let data = upload.body.flatMap { try? JSONDecoder().decode(RequestInfo.self, from: $0) }

        XCTAssertEqual(.ok, upload.status)
        XCTAssertEqual("id: 0id: 1id: 2id: 3id: 4id: 5id: 6id: 7id: 8id: 9", data?.data)
    }

    func testProxyStreamingFailure() throws {
        let httpBin = HTTPBin()
        let httpClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup))
        defer {
            XCTAssertNoThrow(try httpClient.syncShutdown())
            XCTAssertNoThrow(try httpBin.shutdown())
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

        let request12 = try Request(url: "https://someserver.com/some%2Fpathsegment1/pathsegment2")
        XCTAssertEqual(request12.url.uri, "/some%2Fpathsegment1/pathsegment2")
    }

    func testChannelAndDelegateOnDifferentEventLoops() throws {
        class Delegate: HTTPClientResponseDelegate {
            typealias Response = ([Message], [Message])

            enum Message {
                case head(HTTPResponseHead)
                case bodyPart(ByteBuffer)
                case sentRequestHead(HTTPRequestHead)
                case sentRequestPart(IOData)
                case sentRequest
                case error(Error)
            }

            var receivedMessages: [Message] = []
            var sentMessages: [Message] = []
            private let eventLoop: EventLoop
            private let randoEL: EventLoop

            init(expectedEventLoop: EventLoop, randomOtherEventLoop: EventLoop) {
                self.eventLoop = expectedEventLoop
                self.randoEL = randomOtherEventLoop
            }

            func didSendRequestHead(task: HTTPClient.Task<Response>, _ head: HTTPRequestHead) {
                self.eventLoop.assertInEventLoop()
                self.sentMessages.append(.sentRequestHead(head))
            }

            func didSendRequestPart(task: HTTPClient.Task<Response>, _ part: IOData) {
                self.eventLoop.assertInEventLoop()
                self.sentMessages.append(.sentRequestPart(part))
            }

            func didSendRequest(task: HTTPClient.Task<Response>) {
                self.eventLoop.assertInEventLoop()
                self.sentMessages.append(.sentRequest)
            }

            func didReceiveError(task: HTTPClient.Task<Response>, _ error: Error) {
                self.eventLoop.assertInEventLoop()
                self.receivedMessages.append(.error(error))
            }

            public func didReceiveHead(task: HTTPClient.Task<Response>,
                                       _ head: HTTPResponseHead) -> EventLoopFuture<Void> {
                self.eventLoop.assertInEventLoop()
                self.receivedMessages.append(.head(head))
                return self.randoEL.makeSucceededFuture(())
            }

            func didReceiveBodyPart(task: HTTPClient.Task<Response>,
                                    _ buffer: ByteBuffer) -> EventLoopFuture<Void> {
                self.eventLoop.assertInEventLoop()
                self.receivedMessages.append(.bodyPart(buffer))
                return self.randoEL.makeSucceededFuture(())
            }

            func didFinishRequest(task: HTTPClient.Task<Response>) throws -> Response {
                self.eventLoop.assertInEventLoop()
                return (self.receivedMessages, self.sentMessages)
            }
        }

        let group = getDefaultEventLoopGroup(numberOfThreads: 3)
        let serverGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
            XCTAssertNoThrow(try serverGroup.syncShutdownGracefully())
        }

        let channelEL = group.next()
        let delegateEL = group.next()
        let randoEL = group.next()

        let httpClient = HTTPClient(eventLoopGroupProvider: .shared(group))
        let server = NIOHTTP1TestServer(group: serverGroup)
        defer {
            XCTAssertNoThrow(try server.stop())
            XCTAssertNoThrow(try httpClient.syncShutdown(requiresCleanClose: true))
        }

        let body: HTTPClient.Body = .stream(length: 8) { writer in
            let buffer = ByteBuffer(string: "1234")
            return writer.write(.byteBuffer(buffer)).flatMap {
                let buffer = ByteBuffer(string: "4321")
                return writer.write(.byteBuffer(buffer))
            }
        }

        let request = try Request(url: "http://127.0.0.1:\(server.serverPort)/custom",
                                  body: body)
        let delegate = Delegate(expectedEventLoop: delegateEL, randomOtherEventLoop: randoEL)
        let future = httpClient.execute(request: request,
                                        delegate: delegate,
                                        eventLoop: .init(.testOnly_exact(channelOn: channelEL,
                                                                         delegateOn: delegateEL))).futureResult

        XCTAssertNoThrow(try server.readInbound()) // .head
        XCTAssertNoThrow(try server.readInbound()) // .body
        XCTAssertNoThrow(try server.readInbound()) // .end

        // Send 3 parts, but only one should be received until the future is complete
        XCTAssertNoThrow(try server.writeOutbound(.head(.init(version: .init(major: 1, minor: 1),
                                                              status: .ok,
                                                              headers: HTTPHeaders([("Transfer-Encoding", "chunked")])))))
        let buffer = ByteBuffer(string: "1234")
        XCTAssertNoThrow(try server.writeOutbound(.body(.byteBuffer(buffer))))
        XCTAssertNoThrow(try server.writeOutbound(.end(nil)))

        let (receivedMessages, sentMessages) = try future.wait()
        XCTAssertEqual(2, receivedMessages.count)
        XCTAssertEqual(4, sentMessages.count)

        switch sentMessages.dropFirst(0).first {
        case .some(.sentRequestHead(let head)):
            XCTAssertEqual(request.url.uri, head.uri)
        default:
            XCTFail("wrong message")
        }

        switch sentMessages.dropFirst(1).first {
        case .some(.sentRequestPart(.byteBuffer(let buffer))):
            XCTAssertEqual("1234", String(decoding: buffer.readableBytesView, as: Unicode.UTF8.self))
        default:
            XCTFail("wrong message")
        }

        switch sentMessages.dropFirst(2).first {
        case .some(.sentRequestPart(.byteBuffer(let buffer))):
            XCTAssertEqual("4321", String(decoding: buffer.readableBytesView, as: Unicode.UTF8.self))
        default:
            XCTFail("wrong message")
        }

        switch sentMessages.dropFirst(3).first {
        case .some(.sentRequest):
            () // OK
        default:
            XCTFail("wrong message")
        }

        switch receivedMessages.dropFirst(0).first {
        case .some(.head(let head)):
            XCTAssertEqual(head.headers["transfer-encoding"].first, "chunked")
        default:
            XCTFail("wrong message")
        }

        switch receivedMessages.dropFirst(1).first {
        case .some(.bodyPart(let buffer)):
            XCTAssertEqual("1234", String(decoding: buffer.readableBytesView, as: Unicode.UTF8.self))
        default:
            XCTFail("wrong message")
        }
    }

    func testResponseFutureIsOnCorrectEL() throws {
        let group = getDefaultEventLoopGroup(numberOfThreads: 4)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }
        let client = HTTPClient(eventLoopGroupProvider: .shared(group))
        let httpBin = HTTPBin()
        defer {
            XCTAssertNoThrow(try client.syncShutdown())
            XCTAssertNoThrow(try httpBin.shutdown())
        }

        let request = try HTTPClient.Request(url: "http://localhost:\(httpBin.port)/get")
        var futures = [EventLoopFuture<HTTPClient.Response>]()
        for _ in 1...100 {
            let el = group.next()
            let req1 = client.execute(request: request, eventLoop: .delegate(on: el))
            let req2 = client.execute(request: request, eventLoop: .delegateAndChannel(on: el))
            let req3 = client.execute(request: request, eventLoop: .init(.testOnly_exact(channelOn: el, delegateOn: el)))
            XCTAssert(req1.eventLoop === el)
            XCTAssert(req2.eventLoop === el)
            XCTAssert(req3.eventLoop === el)
            futures.append(contentsOf: [req1, req2, req3])
        }
        try EventLoopFuture<HTTPClient.Response>.andAllComplete(futures, on: group.next()).wait()
    }

    func testUncleanCloseThrows() {
        let server = NIOHTTP1TestServer(group: self.serverGroup)
        defer {
            XCTAssertNoThrow(try server.stop())
        }

        let httpClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup))

        _ = httpClient.get(url: "http://localhost:\(server.serverPort)/wait")

        XCTAssertNoThrow(try server.readInbound()) // .head
        XCTAssertNoThrow(try server.readInbound()) // .end

        do {
            try httpClient.syncShutdown(requiresCleanClose: true)
            XCTFail("There should be an error on shutdown")
        } catch {
            guard let clientError = error as? HTTPClientError, clientError == .uncleanShutdown else {
                XCTFail("Unexpected shutdown error: \(error)")
                return
            }
        }
    }

    func testUploadStreamingIsCalledOnTaskEL() throws {
        let group = getDefaultEventLoopGroup(numberOfThreads: 4)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let httpBin = HTTPBin()
        let httpClient = HTTPClient(eventLoopGroupProvider: .shared(group))
        defer {
            XCTAssertNoThrow(try httpClient.syncShutdown())
            XCTAssertNoThrow(try httpBin.shutdown())
        }

        let el1 = group.next()
        let el2 = group.next()
        XCTAssert(el1 !== el2)

        let body: HTTPClient.Body = .stream(length: 8) { writer in
            XCTAssert(el1.inEventLoop)
            let buffer = ByteBuffer(string: "1234")
            return writer.write(.byteBuffer(buffer)).flatMap {
                XCTAssert(el1.inEventLoop)
                let buffer = ByteBuffer(string: "4321")
                return writer.write(.byteBuffer(buffer))
            }
        }
        let request = try HTTPClient.Request(url: "http://localhost:\(httpBin.port)/post", method: .POST, body: body)
        let response = httpClient.execute(request: request,
                                          delegate: ResponseAccumulator(request: request),
                                          eventLoop: HTTPClient.EventLoopPreference(.testOnly_exact(channelOn: el2,
                                                                                                    delegateOn: el1)))
        XCTAssert(el1 === response.eventLoop)
        XCTAssertNoThrow(try response.wait())
    }

    func testTaskPromiseBoundToEL() throws {
        let elg = getDefaultEventLoopGroup(numberOfThreads: 2)
        let el1 = elg.next()
        let el2 = elg.next()

        let httpBin = HTTPBin()
        let client = HTTPClient(eventLoopGroupProvider: .shared(elg))

        defer {
            XCTAssertNoThrow(try client.syncShutdown())
            XCTAssertNoThrow(try httpBin.shutdown())
            XCTAssertNoThrow(try elg.syncShutdownGracefully())
        }

        let request = try HTTPClient.Request(url: "http://localhost:\(httpBin.port)//get")
        let delegate = ResponseAccumulator(request: request)
        let task = client.execute(request: request, delegate: delegate, eventLoop: .init(.testOnly_exact(channelOn: el1, delegateOn: el2)))
        XCTAssertTrue(task.futureResult.eventLoop === el2)
        XCTAssertNoThrow(try task.wait())
    }

    func testConnectErrorCalloutOnCorrectEL() throws {
        class TestDelegate: HTTPClientResponseDelegate {
            typealias Response = Void

            let expectedEL: EventLoop
            var receivedError: Bool = false

            init(expectedEL: EventLoop) {
                self.expectedEL = expectedEL
            }

            func didFinishRequest(task: HTTPClient.Task<Void>) throws {}

            func didReceiveError(task: HTTPClient.Task<Void>, _ error: Error) {
                self.receivedError = true
                XCTAssertTrue(self.expectedEL.inEventLoop)
            }
        }

        let elg = getDefaultEventLoopGroup(numberOfThreads: 2)
        let el1 = elg.next()
        let el2 = elg.next()

        let httpBin = HTTPBin(.refuse)
        let client = HTTPClient(eventLoopGroupProvider: .shared(elg))

        defer {
            XCTAssertNoThrow(try client.syncShutdown())
            XCTAssertNoThrow(try elg.syncShutdownGracefully())
        }

        let request = try HTTPClient.Request(url: "http://localhost:\(httpBin.port)/get")
        let delegate = TestDelegate(expectedEL: el1)
        XCTAssertNoThrow(try httpBin.shutdown())
        let task = client.execute(request: request, delegate: delegate, eventLoop: .init(.testOnly_exact(channelOn: el2, delegateOn: el1)))
        XCTAssertThrowsError(try task.wait())
        XCTAssertTrue(delegate.receivedError)
    }

    func testInternalRequestURI() throws {
        let request1 = try Request(url: "https://someserver.com:8888/some/path?foo=bar")
        XCTAssertEqual(request1.kind, .host)
        XCTAssertEqual(request1.socketPath, "")
        XCTAssertEqual(request1.uri, "/some/path?foo=bar")

        let request2 = try Request(url: "https://someserver.com")
        XCTAssertEqual(request2.kind, .host)
        XCTAssertEqual(request2.socketPath, "")
        XCTAssertEqual(request2.uri, "/")

        let request3 = try Request(url: "unix:///tmp/file")
        XCTAssertEqual(request3.kind, .unixSocket(.baseURL))
        XCTAssertEqual(request3.socketPath, "/tmp/file")
        XCTAssertEqual(request3.uri, "/")

        let request4 = try Request(url: "http+unix://%2Ftmp%2Ffile/file/path")
        XCTAssertEqual(request4.kind, .unixSocket(.http_unix))
        XCTAssertEqual(request4.socketPath, "/tmp/file")
        XCTAssertEqual(request4.uri, "/file/path")

        let request5 = try Request(url: "https+unix://%2Ftmp%2Ffile/file/path")
        XCTAssertEqual(request5.kind, .unixSocket(.https_unix))
        XCTAssertEqual(request5.socketPath, "/tmp/file")
        XCTAssertEqual(request5.uri, "/file/path")
    }

    func testBodyPartStreamStateChangedBeforeNotification() throws {
        class StateValidationDelegate: HTTPClientResponseDelegate {
            typealias Response = Void

            var handler: TaskHandler<StateValidationDelegate>!
            var triggered = false

            func didReceiveError(task: HTTPClient.Task<Response>, _ error: Error) {
                self.triggered = true
                switch self.handler.state {
                case .endOrError:
                    // expected
                    break
                default:
                    XCTFail("unexpected state: \(self.handler.state)")
                }
            }

            func didFinishRequest(task: HTTPClient.Task<Void>) throws {}
        }

        let channel = EmbeddedChannel()
        XCTAssertNoThrow(try channel.connect(to: try SocketAddress(unixDomainSocketPath: "/fake")).wait())

        let task = Task<Void>(eventLoop: channel.eventLoop, logger: HTTPClient.loggingDisabled)

        let delegate = StateValidationDelegate()
        let handler = TaskHandler(task: task,
                                  kind: .host,
                                  delegate: delegate,
                                  redirectHandler: nil,
                                  ignoreUncleanSSLShutdown: false,
                                  logger: HTTPClient.loggingDisabled)

        delegate.handler = handler
        try channel.pipeline.addHandler(handler).wait()

        var request = try Request(url: "http://localhost:8080/post")
        request.body = .stream(length: 1) { writer in
            writer.write(.byteBuffer(ByteBuffer(string: "1234")))
        }

        XCTAssertThrowsError(try channel.writeOutbound(request))
        XCTAssertTrue(delegate.triggered)

        XCTAssertNoThrow(try channel.readOutbound(as: HTTPClientRequestPart.self)) // .head
        XCTAssertNoThrow(XCTAssertTrue(try channel.finish().isClean))
    }

    func testHandlerDoubleError() throws {
        class ErrorCountingDelegate: HTTPClientResponseDelegate {
            typealias Response = Void

            var count = 0

            func didReceiveError(task: HTTPClient.Task<Response>, _: Error) {
                self.count += 1
            }

            func didFinishRequest(task: HTTPClient.Task<Void>) throws {
                return ()
            }
        }

        class SendTwoErrorsHandler: ChannelInboundHandler {
            typealias InboundIn = Any

            func handlerAdded(context: ChannelHandlerContext) {
                context.fireErrorCaught(HTTPClientError.cancelled)
                context.fireErrorCaught(HTTPClientError.cancelled)
            }
        }

        let channel = EmbeddedChannel()
        let task = Task<Void>(eventLoop: channel.eventLoop, logger: HTTPClient.loggingDisabled)
        let delegate = ErrorCountingDelegate()
        try channel.pipeline.addHandler(TaskHandler(task: task,
                                                    kind: .host,
                                                    delegate: delegate,
                                                    redirectHandler: nil,
                                                    ignoreUncleanSSLShutdown: false,
                                                    logger: HTTPClient.loggingDisabled)).wait()

        try channel.pipeline.addHandler(SendTwoErrorsHandler()).wait()

        XCTAssertEqual(delegate.count, 1)
    }

    func testTaskHandlerStateChangeAfterError() throws {
        let channel = EmbeddedChannel()
        let task = Task<Void>(eventLoop: channel.eventLoop, logger: HTTPClient.loggingDisabled)

        let handler = TaskHandler(task: task,
                                  kind: .host,
                                  delegate: TestHTTPDelegate(),
                                  redirectHandler: nil,
                                  ignoreUncleanSSLShutdown: false,
                                  logger: HTTPClient.loggingDisabled)

        try channel.pipeline.addHandler(handler).wait()

        var request = try Request(url: "http://localhost:8080/get")
        request.headers.add(name: "X-Test-Header", value: "X-Test-Value")
        request.body = .stream(length: 4) { writer in
            writer.write(.byteBuffer(channel.allocator.buffer(string: "1234"))).map {
                handler.state = .endOrError
            }
        }

        XCTAssertNoThrow(try channel.writeOutbound(request))

        try channel.writeInbound(HTTPClientResponsePart.head(.init(version: .init(major: 1, minor: 1), status: .ok)))
        XCTAssertTrue(handler.state.isEndOrError)

        try channel.writeInbound(HTTPClientResponsePart.body(channel.allocator.buffer(string: "1234")))
        XCTAssertTrue(handler.state.isEndOrError)

        try channel.writeInbound(HTTPClientResponsePart.end(nil))
        XCTAssertTrue(handler.state.isEndOrError)
    }
}

extension TaskHandler.State {
    var isEndOrError: Bool {
        switch self {
        case .endOrError:
            return true
        default:
            return false
        }
    }
}
