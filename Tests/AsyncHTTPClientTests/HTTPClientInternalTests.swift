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
import NIOConcurrencyHelpers
import NIOHTTP1
import NIOTestUtils
import XCTest

class HTTPClientInternalTests: XCTestCase {
    typealias Request = HTTPClient.Request
    typealias Task = HTTPClient.Task

    func testHTTPPartsHandler() throws {
        let channel = EmbeddedChannel()
        let recorder = RecordingHandler<HTTPClientResponsePart, HTTPClientRequestPart>()
        let task = Task<Void>(eventLoop: channel.eventLoop)

        try channel.pipeline.addHandler(recorder).wait()
        try channel.pipeline.addHandler(TaskHandler(task: task,
                                                    kind: .host,
                                                    delegate: TestHTTPDelegate(),
                                                    redirectHandler: nil,
                                                    ignoreUncleanSSLShutdown: false)).wait()

        var request = try Request(url: "http://localhost/get")
        request.headers.add(name: "X-Test-Header", value: "X-Test-Value")
        request.body = .string("1234")

        XCTAssertNoThrow(try channel.writeOutbound(request))
        XCTAssertEqual(3, recorder.writes.count)
        var head = HTTPRequestHead(version: HTTPVersion(major: 1, minor: 1), method: .GET, uri: "/get")
        head.headers.add(name: "X-Test-Header", value: "X-Test-Value")
        head.headers.add(name: "Host", value: "localhost")
        head.headers.add(name: "Content-Length", value: "4")
        XCTAssertEqual(HTTPClientRequestPart.head(head), recorder.writes[0])
        let buffer = ByteBuffer.of(string: "1234")
        XCTAssertEqual(HTTPClientRequestPart.body(.byteBuffer(buffer)), recorder.writes[1])

        XCTAssertNoThrow(try channel.writeInbound(HTTPClientResponsePart.head(HTTPResponseHead(version: HTTPVersion(major: 1, minor: 1), status: HTTPResponseStatus.ok))))
        XCTAssertNoThrow(try channel.writeInbound(HTTPClientResponsePart.end(nil)))
    }

    func testBadHTTPRequest() throws {
        let channel = EmbeddedChannel()
        let recorder = RecordingHandler<HTTPClientResponsePart, HTTPClientRequestPart>()
        let task = Task<Void>(eventLoop: channel.eventLoop)

        XCTAssertNoThrow(try channel.pipeline.addHandler(recorder).wait())
        XCTAssertNoThrow(try channel.pipeline.addHandler(TaskHandler(task: task,
                                                                     kind: .host,
                                                                     delegate: TestHTTPDelegate(),
                                                                     redirectHandler: nil,
                                                                     ignoreUncleanSSLShutdown: false)).wait())

        var request = try Request(url: "http://localhost/get")
        request.headers.add(name: "X-Test-Header", value: "X-Test-Value")
        request.headers.add(name: "Transfer-Encoding", value: "identity")
        request.body = .string("1234")

        XCTAssertThrowsError(try channel.writeOutbound(request)) { error in
            XCTAssertEqual(HTTPClientError.identityCodingIncorrectlyPresent, error as? HTTPClientError)
        }
    }

    func testHTTPPartsHandlerMultiBody() throws {
        let channel = EmbeddedChannel()
        let delegate = TestHTTPDelegate()
        let task = Task<Void>(eventLoop: channel.eventLoop)
        let handler = TaskHandler(task: task,
                                  kind: .host,
                                  delegate: delegate,
                                  redirectHandler: nil,
                                  ignoreUncleanSSLShutdown: false)

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
        let httpBin = HTTPBin()
        let httpClient = HTTPClient(eventLoopGroupProvider: .createNew)
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
        let bytes = upload.body.flatMap { $0.getData(at: 0, length: $0.readableBytes) }
        let data = try! JSONDecoder().decode(RequestInfo.self, from: bytes!)

        XCTAssertEqual(.ok, upload.status)
        XCTAssertEqual("id: 0id: 1id: 2id: 3id: 4id: 5id: 6id: 7id: 8id: 9", data.data)
    }

    func testProxyStreamingFailure() throws {
        let httpBin = HTTPBin()
        let httpClient = HTTPClient(eventLoopGroupProvider: .createNew)
        defer {
            XCTAssertNoThrow(try httpClient.syncShutdown(requiresCleanClose: true))
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

    // In order to test backpressure we need to make sure that reads will not happen
    // until the backpressure promise is succeeded. Since we cannot guarantee when
    // messages will be delivered to a client pipeline and we need this test to be
    // fast (no waiting for arbitrary amounts of time), we do the following.
    // First, we enforce NIO to send us only 1 byte at a time. Then we send a message
    // of 4 bytes. This will guarantee that if we see first byte of the message, other
    // bytes a ready to be read as well. This will allow us to test if subsequent reads
    // are waiting for backpressure promise.
    func testUploadStreamingBackpressure() throws {
        class BackpressureTestDelegate: HTTPClientResponseDelegate {
            typealias Response = Void

            var _reads = 0
            let lock: Lock
            let backpressurePromise: EventLoopPromise<Void>
            let optionsApplied: EventLoopPromise<Void>
            let messageReceived: EventLoopPromise<Void>

            init(eventLoop: EventLoop) {
                self.lock = Lock()
                self.backpressurePromise = eventLoop.makePromise()
                self.optionsApplied = eventLoop.makePromise()
                self.messageReceived = eventLoop.makePromise()
            }

            var reads: Int {
                return self.lock.withLock {
                    self._reads
                }
            }

            func didReceiveHead(task: HTTPClient.Task<Void>, _ head: HTTPResponseHead) -> EventLoopFuture<Void> {
                // This is to force NIO to send only 1 byte at a time.
                let future = task.connection!.channel.setOption(ChannelOptions.maxMessagesPerRead, value: 1).flatMap {
                    task.connection!.channel.setOption(ChannelOptions.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 1))
                }
                future.cascade(to: self.optionsApplied)
                return future
            }

            func didReceiveBodyPart(task: HTTPClient.Task<Response>, _ buffer: ByteBuffer) -> EventLoopFuture<Void> {
                // We count a number of reads received.
                self.lock.withLockVoid {
                    self._reads += 1
                }
                // We need to notify the test when first byte of the message is arrived.
                self.messageReceived.succeed(())
                return self.backpressurePromise.futureResult
            }

            func didFinishRequest(task: HTTPClient.Task<Response>) throws {}
        }

        let httpClient = HTTPClient(eventLoopGroupProvider: .createNew)
        let promise = httpClient.eventLoopGroup.next().makePromise(of: Channel.self)
        let httpBin = HTTPBin(channelPromise: promise)

        defer {
            XCTAssertNoThrow(try httpClient.syncShutdown(requiresCleanClose: true))
            XCTAssertNoThrow(try httpBin.shutdown())
        }

        let request = try Request(url: "http://localhost:\(httpBin.port)/custom")
        let delegate = BackpressureTestDelegate(eventLoop: httpClient.eventLoopGroup.next())
        let future = httpClient.execute(request: request, delegate: delegate).futureResult

        let channel = try promise.futureResult.wait()

        // We need to wait for channel options that limit NIO to sending only one byte at a time.
        try delegate.optionsApplied.futureResult.wait()

        // Send 4 bytes, but only one should be received until the backpressure promise is succeeded.
        let buffer = ByteBuffer.of(string: "1234")
        try channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buffer))).wait()

        // Now we wait until message is delivered to client channel pipeline
        try delegate.messageReceived.futureResult.wait()
        XCTAssertEqual(delegate.reads, 1)

        // Succeed the backpressure promise.
        delegate.backpressurePromise.succeed(())

        try channel.writeAndFlush(HTTPServerResponsePart.end(nil)).wait()
        try future.wait()

        // At this point all other bytes should be delivered.
        XCTAssertEqual(delegate.reads, 4)
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

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 3)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let channelEL = group.next()
        let delegateEL = group.next()
        let randoEL = group.next()

        let httpClient = HTTPClient(eventLoopGroupProvider: .shared(group))
        let promise: EventLoopPromise<Channel> = httpClient.eventLoopGroup.next().makePromise()
        let httpBin = HTTPBin(channelPromise: promise)
        defer {
            XCTAssertNoThrow(try httpClient.syncShutdown(requiresCleanClose: true))
            XCTAssertNoThrow(try httpBin.shutdown())
        }

        let body: HTTPClient.Body = .stream(length: 8) { writer in
            let buffer = ByteBuffer.of(string: "1234")
            return writer.write(.byteBuffer(buffer)).flatMap {
                let buffer = ByteBuffer.of(string: "4321")
                return writer.write(.byteBuffer(buffer))
            }
        }

        let request = try Request(url: "http://127.0.0.1:\(httpBin.port)/custom",
                                  body: body)
        let delegate = Delegate(expectedEventLoop: delegateEL, randomOtherEventLoop: randoEL)
        let future = httpClient.execute(request: request,
                                        delegate: delegate,
                                        eventLoop: .init(.testOnly_exact(channelOn: channelEL,
                                                                         delegateOn: delegateEL))).futureResult

        let channel = try promise.futureResult.wait()

        // Send 3 parts, but only one should be received until the future is complete
        let buffer = ByteBuffer.of(string: "1234")
        try channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buffer))).wait()

        try channel.writeAndFlush(HTTPServerResponsePart.end(nil)).wait()
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
            XCTAssertEqual(["transfer-encoding": "chunked"], head.headers)
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

    func testResponseConnectionCloseGet() throws {
        let httpBin = HTTPBin(ssl: false)
        let httpClient = HTTPClient(eventLoopGroupProvider: .createNew,
                                    configuration: HTTPClient.Configuration(certificateVerification: .none))
        defer {
            XCTAssertNoThrow(try httpClient.syncShutdown(requiresCleanClose: true))
            XCTAssertNoThrow(try httpBin.shutdown())
        }

        let req = try HTTPClient.Request(url: "http://localhost:\(httpBin.port)/get", method: .GET, headers: ["Connection": "close"], body: nil)
        _ = try! httpClient.execute(request: req).wait()
        let el = httpClient.eventLoopGroup.next()
        try! el.scheduleTask(in: .milliseconds(500)) {
            XCTAssertEqual(httpClient.pool.connectionProviderCount, 0)
        }.futureResult.wait()
    }

    func testWeNoticeRemoteClosuresEvenWhenConnectionIsIdleInPool() {
        final class ServerThatRespondsThenJustCloses: ChannelInboundHandler {
            typealias InboundIn = HTTPServerRequestPart
            typealias OutboundOut = HTTPServerResponsePart

            let requestNumber: NIOAtomic<Int>
            let connectionNumber: NIOAtomic<Int>

            init(requestNumber: NIOAtomic<Int>, connectionNumber: NIOAtomic<Int>) {
                self.requestNumber = requestNumber
                self.connectionNumber = connectionNumber
            }

            func channelActive(context: ChannelHandlerContext) {
                _ = self.connectionNumber.add(1)
            }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                let req = self.unwrapInboundIn(data)

                switch req {
                case .head, .body:
                    ()
                case .end:
                    let last = self.requestNumber.add(1)
                    switch last {
                    case 0:
                        context.write(self.wrapOutboundOut(.head(.init(version: .init(major: 1, minor: 1), status: .ok))),
                                      promise: nil)
                        context.writeAndFlush(self.wrapOutboundOut(.end(nil))).whenComplete { _ in
                            context.eventLoop.scheduleTask(in: .milliseconds(10)) {
                                context.close(promise: nil)
                            }
                        }
                    case 1:
                        context.write(self.wrapOutboundOut(.head(.init(version: .init(major: 1, minor: 1), status: .ok))),
                                      promise: nil)
                        context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
                    default:
                        XCTFail("did not expect request \(last + 1)")
                    }
                }
            }
        }

        final class ObserveWhenClosedHandler: ChannelInboundHandler {
            typealias InboundIn = Any

            let channelInactivePromise: EventLoopPromise<Void>

            init(channelInactivePromise: EventLoopPromise<Void>) {
                self.channelInactivePromise = channelInactivePromise
            }

            func channelInactive(context: ChannelHandlerContext) {
                context.fireChannelInactive()
                self.channelInactivePromise.succeed(())
            }
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }
        let requestNumber = NIOAtomic<Int>.makeAtomic(value: 0)
        let connectionNumber = NIOAtomic<Int>.makeAtomic(value: 0)
        let sharedStateServerHandler = ServerThatRespondsThenJustCloses(requestNumber: requestNumber,
                                                                        connectionNumber: connectionNumber)
        var maybeServer: Channel?
        XCTAssertNoThrow(maybeServer = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(.init(SOL_SOCKET), .init(SO_REUSEADDR)), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    // We're deliberately adding a handler which is shared between multiple channels. This is normally
                    // very verboten but this handler is specially crafted to tolerate this.
                    channel.pipeline.addHandler(sharedStateServerHandler)
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait())
        guard let server = maybeServer else {
            XCTFail("couldn't create server")
            return
        }
        defer {
            XCTAssertNoThrow(try server.close().wait())
        }

        let url = "http://127.0.0.1:\(server.localAddress!.port!)"
        let client = HTTPClient(eventLoopGroupProvider: .shared(group))
        defer {
            XCTAssertNoThrow(try client.syncShutdown())
        }

        var maybeConnection: ConnectionPool.Connection?
        // This is pretty evil but we literally just get hold of a connection to get to the channel to be able to
        // observe when the server closing the connection is known to the client.
        XCTAssertNoThrow(maybeConnection = try client.pool.getConnection(for: .init(url: url),
                                                                         preference: .indifferent,
                                                                         on: group.next(),
                                                                         deadline: nil).wait())
        guard let connection = maybeConnection else {
            XCTFail("couldn't get connection")
            return
        }

        // And let's also give the connection back :).
        client.pool.release(connection)

        XCTAssertEqual(0, sharedStateServerHandler.requestNumber.load())
        XCTAssertEqual(1, client.pool.connectionProviderCount)
        XCTAssertTrue(connection.channel.isActive)
        XCTAssertNoThrow(XCTAssertEqual(.ok, try client.get(url: url).wait().status))
        XCTAssertEqual(1, sharedStateServerHandler.connectionNumber.load())
        XCTAssertEqual(1, sharedStateServerHandler.requestNumber.load())

        // We have received the first response and we know the remote end will now close the connection.
        // Let's wait until we see the closure in the client's channel.
        XCTAssertNoThrow(try connection.channel.closeFuture.wait())

        // Now that we should have learned that the connection is dead, a subsequent request should work and use a new
        // connection
        XCTAssertNoThrow(XCTAssertEqual(.ok, try client.get(url: url).wait().status))
        XCTAssertEqual(2, sharedStateServerHandler.connectionNumber.load())
        XCTAssertEqual(2, sharedStateServerHandler.requestNumber.load())
    }
}
