//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2021 Apple Inc. and the AsyncHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

@testable import AsyncHTTPClient
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOHTTPCompression
import NIOPosix
import NIOTestUtils
import XCTest

class HTTP1ConnectionTests: XCTestCase {
    func testCreateNewConnectionWithDecompression() {
        let embedded = EmbeddedChannel()
        let logger = Logger(label: "test.http1.connection")

        XCTAssertNoThrow(try embedded.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 3000)).wait())

        var connection: HTTP1Connection?
        XCTAssertNoThrow(connection = try HTTP1Connection.start(
            channel: embedded,
            connectionID: 0,
            delegate: MockHTTP1ConnectionDelegate(),
            configuration: .init(decompression: .enabled(limit: .ratio(4))),
            logger: logger
        ))

        XCTAssertNotNil(try embedded.pipeline.syncOperations.handler(type: HTTPRequestEncoder.self))
        XCTAssertNotNil(try embedded.pipeline.syncOperations.handler(type: ByteToMessageHandler<HTTPResponseDecoder>.self))
        XCTAssertNotNil(try embedded.pipeline.syncOperations.handler(type: NIOHTTPResponseDecompressor.self))

        XCTAssertNoThrow(try connection?.close().wait())
        embedded.embeddedEventLoop.run()
        XCTAssert(!embedded.isActive)
    }

    func testCreateNewConnectionWithoutDecompression() {
        let embedded = EmbeddedChannel()
        let logger = Logger(label: "test.http1.connection")

        XCTAssertNoThrow(try embedded.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 3000)).wait())

        XCTAssertNoThrow(try HTTP1Connection.start(
            channel: embedded,
            connectionID: 0,
            delegate: MockHTTP1ConnectionDelegate(),
            configuration: .init(decompression: .disabled),
            logger: logger
        ))

        XCTAssertNotNil(try embedded.pipeline.syncOperations.handler(type: HTTPRequestEncoder.self))
        XCTAssertNotNil(try embedded.pipeline.syncOperations.handler(type: ByteToMessageHandler<HTTPResponseDecoder>.self))
        XCTAssertThrowsError(try embedded.pipeline.syncOperations.handler(type: NIOHTTPResponseDecompressor.self)) { error in
            XCTAssertEqual(error as? ChannelPipelineError, .notFound)
        }
    }

    func testCreateNewConnectionFailureClosedIO() {
        let embedded = EmbeddedChannel()

        XCTAssertNoThrow(try embedded.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 3000)).wait())
        XCTAssertNoThrow(try embedded.close().wait())
        // to really destroy the channel we need to tick once
        embedded.embeddedEventLoop.run()
        let logger = Logger(label: "test.http1.connection")

        XCTAssertThrowsError(try HTTP1Connection.start(
            channel: embedded,
            connectionID: 0,
            delegate: MockHTTP1ConnectionDelegate(),
            configuration: .init(),
            logger: logger
        ))
    }

    func testGETRequest() {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let clientEL = elg.next()
        let serverEL = elg.next()
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }
        let server = NIOHTTP1TestServer(group: serverEL)
        defer { XCTAssertNoThrow(try server.stop()) }

        let logger = Logger(label: "test")
        let delegate = MockHTTP1ConnectionDelegate()
        delegate.closePromise = clientEL.makePromise(of: Void.self)

        let connection = try! ClientBootstrap(group: clientEL)
            .connect(to: .init(ipAddress: "127.0.0.1", port: server.serverPort))
            .flatMapThrowing {
                try HTTP1Connection.start(
                    channel: $0,
                    connectionID: 0,
                    delegate: delegate,
                    configuration: .init(decompression: .disabled),
                    logger: logger
                )
            }
            .wait()

        var maybeRequest: HTTPClient.Request?
        XCTAssertNoThrow(maybeRequest = try HTTPClient.Request(
            url: "http://localhost/hello/swift",
            method: .POST,
            body: .stream(length: 4) { writer -> EventLoopFuture<Void> in
                func recursive(count: UInt8, promise: EventLoopPromise<Void>) {
                    guard count < 4 else {
                        return promise.succeed(())
                    }

                    writer.write(.byteBuffer(ByteBuffer(bytes: [count]))).whenComplete { result in
                        switch result {
                        case .failure(let error):
                            XCTFail("Unexpected error: \(error)")
                        case .success:
                            recursive(count: count + 1, promise: promise)
                        }
                    }
                }

                let promise = clientEL.makePromise(of: Void.self)
                recursive(count: 0, promise: promise)
                return promise.futureResult
            }
        ))

        guard let request = maybeRequest else {
            return XCTFail("Expected to have a connection and a request")
        }

        let task = HTTPClient.Task<HTTPClient.Response>(eventLoop: clientEL, logger: logger)

        var maybeRequestBag: RequestBag<ResponseAccumulator>?
        XCTAssertNoThrow(maybeRequestBag = try RequestBag(
            request: request,
            eventLoopPreference: .delegate(on: clientEL),
            task: task,
            redirectHandler: nil,
            connectionDeadline: .now() + .seconds(60),
            idleReadTimeout: nil,
            delegate: ResponseAccumulator(request: request)
        ))
        guard let requestBag = maybeRequestBag else { return XCTFail("Expected to be able to create a request bag.") }
        connection.executeRequest(requestBag)

        XCTAssertNoThrow(try server.receiveHeadAndVerify { head in
            XCTAssertEqual(head.method, .POST)
            XCTAssertEqual(head.uri, "/hello/swift")
            XCTAssertEqual(head.headers["content-length"].first, "4")
        })

        var received: UInt8 = 0
        while received < 4 {
            XCTAssertNoThrow(try server.receiveBodyAndVerify { body in
                var body = body
                while let read = body.readInteger(as: UInt8.self) {
                    XCTAssertEqual(received, read)
                    received += 1
                }
            })
        }
        XCTAssertEqual(received, 4)
        XCTAssertNoThrow(try server.receiveEnd())

        XCTAssertNoThrow(try server.writeOutbound(.head(.init(version: .http1_1, status: .ok))))
        XCTAssertNoThrow(try server.writeOutbound(.body(.byteBuffer(ByteBuffer(bytes: [0, 1, 2, 3])))))
        XCTAssertNoThrow(try server.writeOutbound(.end(nil)))

        var response: HTTPClient.Response?
        XCTAssertNoThrow(response = try task.futureResult.wait())

        XCTAssertEqual(response?.body, ByteBuffer(bytes: [0, 1, 2, 3]))

        // connection is closed
        XCTAssertNoThrow(try XCTUnwrap(delegate.closePromise).futureResult.wait())
    }

    func testConnectionClosesOnCloseHeader() {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = eventLoopGroup.next()
        defer { XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully()) }

        let httpBin = HTTPBin(handlerFactory: { _ in SuddenlySendsCloseHeaderChannelHandler(closeOnRequest: 1) })

        var maybeChannel: Channel?

        XCTAssertNoThrow(maybeChannel = try ClientBootstrap(group: eventLoop).connect(host: "localhost", port: httpBin.port).wait())
        let connectionDelegate = MockConnectionDelegate()
        let logger = Logger(label: "test")
        var maybeConnection: HTTP1Connection?
        XCTAssertNoThrow(maybeConnection = try eventLoop.submit { try HTTP1Connection.start(
            channel: XCTUnwrap(maybeChannel),
            connectionID: 0,
            delegate: connectionDelegate,
            configuration: .init(),
            logger: logger
        ) }.wait())
        guard let connection = maybeConnection else { return XCTFail("Expected to have a connection here") }

        var maybeRequest: HTTPClient.Request?
        XCTAssertNoThrow(maybeRequest = try HTTPClient.Request(url: "http://localhost:\(httpBin.port)/"))
        guard let request = maybeRequest else { return XCTFail("Expected to be able to create a request") }

        let delegate = ResponseAccumulator(request: request)
        var maybeRequestBag: RequestBag<ResponseAccumulator>?
        XCTAssertNoThrow(maybeRequestBag = try RequestBag(
            request: request,
            eventLoopPreference: .delegate(on: eventLoopGroup.next()),
            task: .init(eventLoop: eventLoopGroup.next(), logger: logger),
            redirectHandler: nil,
            connectionDeadline: .now() + .seconds(30),
            idleReadTimeout: nil,
            delegate: delegate
        ))
        guard let requestBag = maybeRequestBag else { return XCTFail("Expected to be able to create a request bag") }

        connection.executeRequest(requestBag)

        var response: HTTPClient.Response?
        XCTAssertNoThrow(response = try requestBag.task.futureResult.wait())
        XCTAssertEqual(response?.status, .ok)
        XCTAssertEqual(connectionDelegate.hitConnectionReleased, 0)
        XCTAssertNoThrow(try XCTUnwrap(maybeChannel).closeFuture.wait())
        XCTAssertEqual(connectionDelegate.hitConnectionClosed, 1)

        // we need to wait a small amount of time to see the connection close on the server
        try! eventLoop.scheduleTask(in: .milliseconds(200)) {}.futureResult.wait()
        XCTAssertEqual(httpBin.activeConnections, 0)
    }

    func testConnectionClosesOnRandomlyAppearingCloseHeader() {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = eventLoopGroup.next()
        defer { XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully()) }

        let closeOnRequest = (30...100).randomElement()!
        let httpBin = HTTPBin(handlerFactory: { _ in SuddenlySendsCloseHeaderChannelHandler(closeOnRequest: closeOnRequest) })

        var maybeChannel: Channel?

        XCTAssertNoThrow(maybeChannel = try ClientBootstrap(group: eventLoop).connect(host: "localhost", port: httpBin.port).wait())
        let connectionDelegate = MockConnectionDelegate()
        let logger = Logger(label: "test")
        var maybeConnection: HTTP1Connection?
        XCTAssertNoThrow(maybeConnection = try eventLoop.submit { try HTTP1Connection.start(
            channel: XCTUnwrap(maybeChannel),
            connectionID: 0,
            delegate: connectionDelegate,
            configuration: .init(),
            logger: logger
        ) }.wait())
        guard let connection = maybeConnection else { return XCTFail("Expected to have a connection here") }

        var counter = 0
        while true {
            counter += 1

            var maybeRequest: HTTPClient.Request?
            XCTAssertNoThrow(maybeRequest = try HTTPClient.Request(url: "http://localhost:\(httpBin.port)/"))
            guard let request = maybeRequest else { return XCTFail("Expected to be able to create a request") }

            let delegate = ResponseAccumulator(request: request)
            var maybeRequestBag: RequestBag<ResponseAccumulator>?
            XCTAssertNoThrow(maybeRequestBag = try RequestBag(
                request: request,
                eventLoopPreference: .delegate(on: eventLoopGroup.next()),
                task: .init(eventLoop: eventLoopGroup.next(), logger: logger),
                redirectHandler: nil,
                connectionDeadline: .now() + .seconds(30),
                idleReadTimeout: nil,
                delegate: delegate
            ))
            guard let requestBag = maybeRequestBag else { return XCTFail("Expected to be able to create a request bag") }

            connection.executeRequest(requestBag)

            var response: HTTPClient.Response?
            XCTAssertNoThrow(response = try requestBag.task.futureResult.wait())
            XCTAssertEqual(response?.status, .ok)

            if response?.headers.first(name: "connection") == "close" {
                break // the loop
            } else {
                XCTAssertEqual(httpBin.activeConnections, 1)
                XCTAssertEqual(connectionDelegate.hitConnectionReleased, counter)
            }
        }

        XCTAssertNoThrow(try XCTUnwrap(maybeChannel).closeFuture.wait())
        XCTAssertEqual(connectionDelegate.hitConnectionClosed, 1)
        XCTAssertFalse(try XCTUnwrap(maybeChannel).isActive)

        XCTAssertEqual(counter, closeOnRequest)
        XCTAssertEqual(connectionDelegate.hitConnectionClosed, 1)
        XCTAssertEqual(connectionDelegate.hitConnectionReleased, counter - 1,
                       "If a close header is received connection release is not triggered.")

        // we need to wait a small amount of time to see the connection close on the server
        try! eventLoop.scheduleTask(in: .milliseconds(200)) {}.futureResult.wait()
        XCTAssertEqual(httpBin.activeConnections, 0)
    }

    func testConnectionClosesAfterTheRequestWithoutHavingSentAnCloseHeader() {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = eventLoopGroup.next()
        defer { XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully()) }

        let httpBin = HTTPBin(handlerFactory: { _ in AfterRequestCloseConnectionChannelHandler() })

        var maybeChannel: Channel?

        XCTAssertNoThrow(maybeChannel = try ClientBootstrap(group: eventLoop).connect(host: "localhost", port: httpBin.port).wait())
        let connectionDelegate = MockConnectionDelegate()
        let logger = Logger(label: "test")
        var maybeConnection: HTTP1Connection?
        XCTAssertNoThrow(maybeConnection = try eventLoop.submit { try HTTP1Connection.start(
            channel: XCTUnwrap(maybeChannel),
            connectionID: 0,
            delegate: connectionDelegate,
            configuration: .init(),
            logger: logger
        ) }.wait())
        guard let connection = maybeConnection else { return XCTFail("Expected to have a connection here") }

        var maybeRequest: HTTPClient.Request?
        XCTAssertNoThrow(maybeRequest = try HTTPClient.Request(url: "http://localhost:\(httpBin.port)/"))
        guard let request = maybeRequest else { return XCTFail("Expected to be able to create a request") }

        let delegate = ResponseAccumulator(request: request)
        var maybeRequestBag: RequestBag<ResponseAccumulator>?
        XCTAssertNoThrow(maybeRequestBag = try RequestBag(
            request: request,
            eventLoopPreference: .delegate(on: eventLoopGroup.next()),
            task: .init(eventLoop: eventLoopGroup.next(), logger: logger),
            redirectHandler: nil,
            connectionDeadline: .now() + .seconds(30),
            idleReadTimeout: nil,
            delegate: delegate
        ))
        guard let requestBag = maybeRequestBag else { return XCTFail("Expected to be able to create a request bag") }

        connection.executeRequest(requestBag)

        var response: HTTPClient.Response?
        XCTAssertNoThrow(response = try requestBag.task.futureResult.wait())
        XCTAssertEqual(response?.status, .ok)
        XCTAssertEqual(connectionDelegate.hitConnectionReleased, 1)

        XCTAssertNoThrow(try XCTUnwrap(maybeChannel).closeFuture.wait())
        XCTAssertEqual(connectionDelegate.hitConnectionClosed, 1)
        XCTAssertEqual(httpBin.activeConnections, 0)
    }
}

class MockHTTP1ConnectionDelegate: HTTP1ConnectionDelegate {
    var releasePromise: EventLoopPromise<Void>?
    var closePromise: EventLoopPromise<Void>?

    func http1ConnectionReleased(_: HTTP1Connection) {
        self.releasePromise?.succeed(())
    }

    func http1ConnectionClosed(_: HTTP1Connection) {
        self.closePromise?.succeed(())
    }
}

/// A channel handler that sends a connection close header but does not close the connection.
class SuddenlySendsCloseHeaderChannelHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    var counter = 1
    let closeOnRequest: Int

    init(closeOnRequest: Int) {
        self.closeOnRequest = closeOnRequest
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch self.unwrapInboundIn(data) {
        case .head(let head):
            XCTAssertLessThanOrEqual(self.counter, self.closeOnRequest)
            XCTAssertTrue(head.headers.contains(name: "host"))
            XCTAssertEqual(head.method, .GET)
        case .body:
            break
        case .end:
            if self.closeOnRequest == self.counter {
                context.write(self.wrapOutboundOut(.head(.init(version: .http1_1, status: .ok, headers: ["connection": "close"]))), promise: nil)
                context.write(self.wrapOutboundOut(.end(nil)), promise: nil)
                context.flush()
                self.counter += 1
            } else {
                context.write(self.wrapOutboundOut(.head(.init(version: .http1_1, status: .ok))), promise: nil)
                context.write(self.wrapOutboundOut(.end(nil)), promise: nil)
                context.flush()
                self.counter += 1
            }
        }
    }
}

/// A channel handler that closes a connection after a successful request
class AfterRequestCloseConnectionChannelHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    init() {}

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch self.unwrapInboundIn(data) {
        case .head(let head):
            XCTAssertTrue(head.headers.contains(name: "host"))
            XCTAssertEqual(head.method, .GET)
        case .body:
            break
        case .end:
            context.write(self.wrapOutboundOut(.head(.init(version: .http1_1, status: .ok))), promise: nil)
            context.write(self.wrapOutboundOut(.end(nil)), promise: nil)
            context.flush()

            context.eventLoop.scheduleTask(in: .milliseconds(20)) {
                context.close(promise: nil)
            }
        }
    }
}

class MockConnectionDelegate: HTTP1ConnectionDelegate {
    private var lock = Lock()

    private var _hitConnectionReleased = 0
    private var _hitConnectionClosed = 0

    var hitConnectionReleased: Int {
        self.lock.withLock { self._hitConnectionReleased }
    }

    var hitConnectionClosed: Int {
        self.lock.withLock { self._hitConnectionClosed }
    }

    init() {}

    func http1ConnectionReleased(_: HTTP1Connection) {
        self.lock.withLockVoid {
            self._hitConnectionReleased += 1
        }
    }

    func http1ConnectionClosed(_: HTTP1Connection) {
        self.lock.withLockVoid {
            self._hitConnectionClosed += 1
        }
    }
}
