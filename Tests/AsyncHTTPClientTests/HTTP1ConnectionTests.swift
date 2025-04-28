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

import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOHTTPCompression
import NIOPosix
import NIOTestUtils
import XCTest

@testable import AsyncHTTPClient

class HTTP1ConnectionTests: XCTestCase {
    func testCreateNewConnectionWithDecompression() {
        let embedded = EmbeddedChannel()
        let logger = Logger(label: "test.http1.connection")

        XCTAssertNoThrow(try embedded.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 3000)).wait())

        var connection: HTTP1Connection?
        XCTAssertNoThrow(
            connection = try HTTP1Connection.start(
                channel: embedded,
                connectionID: 0,
                delegate: MockHTTP1ConnectionDelegate(),
                decompression: .enabled(limit: .ratio(4)),
                logger: logger
            )
        )

        XCTAssertNotNil(try embedded.pipeline.syncOperations.handler(type: HTTPRequestEncoder.self))
        XCTAssertNotNil(
            try embedded.pipeline.syncOperations.handler(type: ByteToMessageHandler<HTTPResponseDecoder>.self)
        )
        XCTAssertNotNil(try embedded.pipeline.syncOperations.handler(type: NIOHTTPResponseDecompressor.self))

        XCTAssertNoThrow(try connection?.sendableView.close().wait())
        embedded.embeddedEventLoop.run()
        XCTAssert(!embedded.isActive)
    }

    func testCreateNewConnectionWithoutDecompression() {
        let embedded = EmbeddedChannel()
        let logger = Logger(label: "test.http1.connection")

        XCTAssertNoThrow(try embedded.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 3000)).wait())

        XCTAssertNoThrow(
            try HTTP1Connection.start(
                channel: embedded,
                connectionID: 0,
                delegate: MockHTTP1ConnectionDelegate(),
                decompression: .disabled,
                logger: logger
            )
        )

        XCTAssertNotNil(try embedded.pipeline.syncOperations.handler(type: HTTPRequestEncoder.self))
        XCTAssertNotNil(
            try embedded.pipeline.syncOperations.handler(type: ByteToMessageHandler<HTTPResponseDecoder>.self)
        )
        XCTAssertThrowsError(try embedded.pipeline.syncOperations.handler(type: NIOHTTPResponseDecompressor.self)) {
            error in
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

        XCTAssertThrowsError(
            try HTTP1Connection.start(
                channel: embedded,
                connectionID: 0,
                delegate: MockHTTP1ConnectionDelegate(),
                decompression: .disabled,
                logger: logger
            )
        )
    }

    func testGETRequest() {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let clientEL = elg.next()
        let serverEL = elg.next()
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }
        let server = NIOHTTP1TestServer(group: serverEL)
        defer { XCTAssertNoThrow(try server.stop()) }

        let logger = Logger(label: "test")
        let delegate = MockHTTP1ConnectionDelegate(closePromise: clientEL.makePromise())

        let connection = try! ClientBootstrap(group: clientEL)
            .connect(to: .init(ipAddress: "127.0.0.1", port: server.serverPort))
            .flatMapThrowing {
                try HTTP1Connection.start(
                    channel: $0,
                    connectionID: 0,
                    delegate: delegate,
                    decompression: .disabled,
                    logger: logger
                ).sendableView
            }
            .wait()

        var maybeRequest: HTTPClient.Request?
        XCTAssertNoThrow(
            maybeRequest = try HTTPClient.Request(
                url: "http://localhost/hello/swift",
                method: .POST,
                body: .stream(contentLength: 4) { writer -> EventLoopFuture<Void> in
                    @Sendable func recursive(count: UInt8, promise: EventLoopPromise<Void>) {
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
            )
        )

        guard let request = maybeRequest else {
            return XCTFail("Expected to have a connection and a request")
        }

        let task = HTTPClient.Task<HTTPClient.Response>(eventLoop: clientEL, logger: logger)

        var maybeRequestBag: RequestBag<ResponseAccumulator>?
        XCTAssertNoThrow(
            maybeRequestBag = try RequestBag(
                request: request,
                eventLoopPreference: .delegate(on: clientEL),
                task: task,
                redirectHandler: nil,
                connectionDeadline: .now() + .seconds(60),
                requestOptions: .forTests(),
                delegate: ResponseAccumulator(request: request)
            )
        )
        guard let requestBag = maybeRequestBag else { return XCTFail("Expected to be able to create a request bag.") }
        connection.executeRequest(requestBag)

        XCTAssertNoThrow(
            try server.receiveHeadAndVerify { head in
                XCTAssertEqual(head.method, .POST)
                XCTAssertEqual(head.uri, "/hello/swift")
                XCTAssertEqual(head.headers["content-length"].first, "4")
            }
        )

        var received: UInt8 = 0
        while received < 4 {
            XCTAssertNoThrow(
                try server.receiveBodyAndVerify { body in
                    var body = body
                    while let read = body.readInteger(as: UInt8.self) {
                        XCTAssertEqual(received, read)
                        received += 1
                    }
                }
            )
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

        XCTAssertNoThrow(
            maybeChannel = try ClientBootstrap(group: eventLoop).connect(host: "localhost", port: httpBin.port).wait()
        )
        let connectionDelegate = MockConnectionDelegate()
        let logger = Logger(label: "test")
        var maybeConnection: HTTP1Connection.SendableView?
        XCTAssertNoThrow(
            maybeConnection = try eventLoop.submit { [maybeChannel] in
                try HTTP1Connection.start(
                    channel: XCTUnwrap(maybeChannel),
                    connectionID: 0,
                    delegate: connectionDelegate,
                    decompression: .disabled,
                    logger: logger
                ).sendableView
            }.wait()
        )
        guard let connection = maybeConnection else { return XCTFail("Expected to have a connection here") }

        var maybeRequest: HTTPClient.Request?
        XCTAssertNoThrow(maybeRequest = try HTTPClient.Request(url: "http://localhost:\(httpBin.port)/"))
        guard let request = maybeRequest else { return XCTFail("Expected to be able to create a request") }

        let delegate = ResponseAccumulator(request: request)
        var maybeRequestBag: RequestBag<ResponseAccumulator>?
        XCTAssertNoThrow(
            maybeRequestBag = try RequestBag(
                request: request,
                eventLoopPreference: .delegate(on: eventLoopGroup.next()),
                task: .init(eventLoop: eventLoopGroup.next(), logger: logger),
                redirectHandler: nil,
                connectionDeadline: .now() + .seconds(30),
                requestOptions: .forTests(),
                delegate: delegate
            )
        )
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
        let httpBin = HTTPBin(handlerFactory: { _ in
            SuddenlySendsCloseHeaderChannelHandler(closeOnRequest: closeOnRequest)
        })

        var maybeChannel: Channel?

        XCTAssertNoThrow(
            maybeChannel = try ClientBootstrap(group: eventLoop).connect(host: "localhost", port: httpBin.port).wait()
        )
        let connectionDelegate = MockConnectionDelegate()
        let logger = Logger(label: "test")
        var maybeConnection: HTTP1Connection.SendableView?
        XCTAssertNoThrow(
            maybeConnection = try eventLoop.submit { [maybeChannel] in
                try HTTP1Connection.start(
                    channel: XCTUnwrap(maybeChannel),
                    connectionID: 0,
                    delegate: connectionDelegate,
                    decompression: .disabled,
                    logger: logger
                ).sendableView
            }.wait()
        )
        guard let connection = maybeConnection else { return XCTFail("Expected to have a connection here") }

        var counter = 0
        while true {
            counter += 1

            var maybeRequest: HTTPClient.Request?
            XCTAssertNoThrow(maybeRequest = try HTTPClient.Request(url: "http://localhost:\(httpBin.port)/"))
            guard let request = maybeRequest else { return XCTFail("Expected to be able to create a request") }

            let delegate = ResponseAccumulator(request: request)
            var maybeRequestBag: RequestBag<ResponseAccumulator>?
            XCTAssertNoThrow(
                maybeRequestBag = try RequestBag(
                    request: request,
                    eventLoopPreference: .delegate(on: eventLoopGroup.next()),
                    task: .init(eventLoop: eventLoopGroup.next(), logger: logger),
                    redirectHandler: nil,
                    connectionDeadline: .now() + .seconds(30),
                    requestOptions: .forTests(),
                    delegate: delegate
                )
            )
            guard let requestBag = maybeRequestBag else {
                return XCTFail("Expected to be able to create a request bag")
            }

            connection.executeRequest(requestBag)

            var response: HTTPClient.Response?
            XCTAssertNoThrow(response = try requestBag.task.futureResult.wait())
            XCTAssertEqual(response?.status, .ok)

            if response?.headers.first(name: "connection") == "close" {
                break  // the loop
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
        XCTAssertEqual(
            connectionDelegate.hitConnectionReleased,
            counter - 1,
            "If a close header is received connection release is not triggered."
        )

        // we need to wait a small amount of time to see the connection close on the server
        try! eventLoop.scheduleTask(in: .milliseconds(200)) {}.futureResult.wait()
        XCTAssertEqual(httpBin.activeConnections, 0)
    }

    func testConnectionClosesAfterTheRequestWithoutHavingSentAnCloseHeader() {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = eventLoopGroup.next()
        defer { XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully()) }

        let httpBin = HTTPBin(handlerFactory: { _ in AfterRequestCloseConnectionChannelHandler() })
        defer { XCTAssertNoThrow(try httpBin.shutdown()) }

        var maybeChannel: Channel?

        XCTAssertNoThrow(
            maybeChannel = try ClientBootstrap(group: eventLoop).connect(host: "localhost", port: httpBin.port).wait()
        )
        let connectionDelegate = MockConnectionDelegate()
        let logger = Logger(label: "test")
        var maybeConnection: HTTP1Connection.SendableView?
        XCTAssertNoThrow(
            maybeConnection = try eventLoop.submit { [maybeChannel] in
                try HTTP1Connection.start(
                    channel: XCTUnwrap(maybeChannel),
                    connectionID: 0,
                    delegate: connectionDelegate,
                    decompression: .disabled,
                    logger: logger
                ).sendableView
            }.wait()
        )
        guard let connection = maybeConnection else { return XCTFail("Expected to have a connection here") }

        var maybeRequest: HTTPClient.Request?
        XCTAssertNoThrow(maybeRequest = try HTTPClient.Request(url: "http://localhost:\(httpBin.port)/"))
        guard let request = maybeRequest else { return XCTFail("Expected to be able to create a request") }

        let delegate = ResponseAccumulator(request: request)
        var maybeRequestBag: RequestBag<ResponseAccumulator>?
        XCTAssertNoThrow(
            maybeRequestBag = try RequestBag(
                request: request,
                eventLoopPreference: .delegate(on: eventLoopGroup.next()),
                task: .init(eventLoop: eventLoopGroup.next(), logger: logger),
                redirectHandler: nil,
                connectionDeadline: .now() + .seconds(30),
                requestOptions: .forTests(),
                delegate: delegate
            )
        )
        guard let requestBag = maybeRequestBag else { return XCTFail("Expected to be able to create a request bag") }

        connection.executeRequest(requestBag)

        var response: HTTPClient.Response?
        XCTAssertNoThrow(response = try requestBag.task.futureResult.wait())
        XCTAssertEqual(response?.status, .ok)
        XCTAssertEqual(connectionDelegate.hitConnectionReleased, 1)

        XCTAssertNoThrow(try XCTUnwrap(maybeChannel).closeFuture.wait())
        XCTAssertEqual(connectionDelegate.hitConnectionClosed, 1)
    }

    func testConnectionIsClosedAfterSwitchingProtocols() {
        let embedded = EmbeddedChannel()
        let logger = Logger(label: "test.http1.connection")

        XCTAssertNoThrow(try embedded.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 3000)).wait())

        var maybeConnection: HTTP1Connection?
        let connectionDelegate = MockConnectionDelegate()
        XCTAssertNoThrow(
            maybeConnection = try HTTP1Connection.start(
                channel: embedded,
                connectionID: 0,
                delegate: connectionDelegate,
                decompression: .enabled(limit: .ratio(4)),
                logger: logger
            )
        )
        guard let connection = maybeConnection else { return XCTFail("Expected to have a connection at this point.") }

        var maybeRequest: HTTPClient.Request?
        XCTAssertNoThrow(maybeRequest = try HTTPClient.Request(url: "http://swift.org/"))
        guard let request = maybeRequest else { return XCTFail("Expected to be able to create a request") }

        let delegate = ResponseAccumulator(request: request)
        var maybeRequestBag: RequestBag<ResponseAccumulator>?
        XCTAssertNoThrow(
            maybeRequestBag = try RequestBag(
                request: request,
                eventLoopPreference: .delegate(on: embedded.eventLoop),
                task: .init(eventLoop: embedded.eventLoop, logger: logger),
                redirectHandler: nil,
                connectionDeadline: .now() + .seconds(30),
                requestOptions: .forTests(),
                delegate: delegate
            )
        )
        guard let requestBag = maybeRequestBag else { return XCTFail("Expected to be able to create a request bag") }

        connection.sendableView.executeRequest(requestBag)

        XCTAssertNoThrow(try embedded.readOutbound(as: ByteBuffer.self))  // head
        XCTAssertNoThrow(try embedded.readOutbound(as: ByteBuffer.self))  // end

        let responseString = """
            HTTP/1.1 101 Switching Protocols\r\n\
            Upgrade: websocket\r\n\
            Sec-WebSocket-Accept: xAMUK7/Il9bLRFJrikq6mm8CNZI=\r\n\
            Connection: upgrade\r\n\
            date: Mon, 27 Sep 2021 17:53:14 GMT\r\n\
            \r\n\
            \r\nfoo bar baz
            """

        XCTAssertTrue(embedded.isActive)
        XCTAssertEqual(connectionDelegate.hitConnectionClosed, 0)
        XCTAssertEqual(connectionDelegate.hitConnectionReleased, 0)
        XCTAssertNoThrow(try embedded.writeInbound(ByteBuffer(string: responseString)))
        XCTAssertFalse(embedded.isActive)
        (embedded.eventLoop as! EmbeddedEventLoop).run()  // tick once to run futures.
        XCTAssertEqual(connectionDelegate.hitConnectionClosed, 1)
        XCTAssertEqual(connectionDelegate.hitConnectionReleased, 0)

        var response: HTTPClient.Response?
        XCTAssertNoThrow(response = try requestBag.task.futureResult.wait())
        XCTAssertEqual(response?.status, .switchingProtocols)
        XCTAssertEqual(response?.headers.count, 4)
        XCTAssertEqual(response?.body, nil)
    }

    func testConnectionDropAfterEarlyHints() {
        let embedded = EmbeddedChannel()
        let logger = Logger(label: "test.http1.connection")

        XCTAssertNoThrow(try embedded.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 3000)).wait())

        var maybeConnection: HTTP1Connection?
        let connectionDelegate = MockConnectionDelegate()
        XCTAssertNoThrow(
            maybeConnection = try HTTP1Connection.start(
                channel: embedded,
                connectionID: 0,
                delegate: connectionDelegate,
                decompression: .enabled(limit: .ratio(4)),
                logger: logger
            )
        )
        guard let connection = maybeConnection else { return XCTFail("Expected to have a connection at this point.") }

        var maybeRequest: HTTPClient.Request?
        XCTAssertNoThrow(maybeRequest = try HTTPClient.Request(url: "http://swift.org/"))
        guard let request = maybeRequest else { return XCTFail("Expected to be able to create a request") }

        let delegate = ResponseAccumulator(request: request)
        var maybeRequestBag: RequestBag<ResponseAccumulator>?
        XCTAssertNoThrow(
            maybeRequestBag = try RequestBag(
                request: request,
                eventLoopPreference: .delegate(on: embedded.eventLoop),
                task: .init(eventLoop: embedded.eventLoop, logger: logger),
                redirectHandler: nil,
                connectionDeadline: .now() + .seconds(30),
                requestOptions: .forTests(),
                delegate: delegate
            )
        )
        guard let requestBag = maybeRequestBag else { return XCTFail("Expected to be able to create a request bag") }

        connection.sendableView.executeRequest(requestBag)

        XCTAssertNoThrow(try embedded.readOutbound(as: ByteBuffer.self))  // head
        XCTAssertNoThrow(try embedded.readOutbound(as: ByteBuffer.self))  // end

        let responseString = """
            HTTP/1.1 103 Early Hints\r\n\
            date: Mon, 27 Sep 2021 17:53:14 GMT\r\n\
            \r\n\
            \r\n
            """

        XCTAssertTrue(embedded.isActive)
        XCTAssertEqual(connectionDelegate.hitConnectionClosed, 0)
        XCTAssertEqual(connectionDelegate.hitConnectionReleased, 0)
        XCTAssertNoThrow(try embedded.writeInbound(ByteBuffer(string: responseString)))

        XCTAssertTrue(embedded.isActive, "The connection remains active after the informational response head")
        XCTAssertNoThrow(try embedded.close().wait(), "the connection was closed")

        embedded.embeddedEventLoop.run()  // tick once to run futures.
        XCTAssertEqual(connectionDelegate.hitConnectionClosed, 1)
        XCTAssertEqual(connectionDelegate.hitConnectionReleased, 0)

        XCTAssertThrowsError(try requestBag.task.futureResult.wait()) {
            XCTAssertEqual($0 as? HTTPClientError, .remoteConnectionClosed)
        }
    }

    func testConnectionIsClosedIfResponseIsReceivedBeforeRequest() {
        let embedded = EmbeddedChannel()
        let logger = Logger(label: "test.http1.connection")

        XCTAssertNoThrow(try embedded.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 0)).wait())

        let connectionDelegate = MockConnectionDelegate()
        XCTAssertNoThrow(
            try HTTP1Connection.start(
                channel: embedded,
                connectionID: 0,
                delegate: connectionDelegate,
                decompression: .enabled(limit: .ratio(4)),
                logger: logger
            )
        )

        let responseString = """
            HTTP/1.1 200 OK\r\n\
            date: Mon, 27 Sep 2021 17:53:14 GMT\r\n\
            \r\n\
            \r\n
            """

        XCTAssertEqual(connectionDelegate.hitConnectionClosed, 0)
        XCTAssertEqual(connectionDelegate.hitConnectionReleased, 0)

        XCTAssertThrowsError(try embedded.writeInbound(ByteBuffer(string: responseString))) {
            XCTAssertEqual($0 as? NIOHTTPDecoderError, .unsolicitedResponse)
        }
        XCTAssertFalse(embedded.isActive)
        (embedded.eventLoop as! EmbeddedEventLoop).run()  // tick once to run futures.
        XCTAssertEqual(connectionDelegate.hitConnectionClosed, 1)
        XCTAssertEqual(connectionDelegate.hitConnectionReleased, 0)
    }

    func testDoubleHTTPResponseLine() {
        let embedded = EmbeddedChannel()
        let logger = Logger(label: "test.http1.connection")

        XCTAssertNoThrow(try embedded.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 0)).wait())

        var maybeConnection: HTTP1Connection?
        let connectionDelegate = MockConnectionDelegate()
        XCTAssertNoThrow(
            maybeConnection = try HTTP1Connection.start(
                channel: embedded,
                connectionID: 0,
                delegate: connectionDelegate,
                decompression: .enabled(limit: .ratio(4)),
                logger: logger
            )
        )
        guard let connection = maybeConnection else { return XCTFail("Expected to have a connection at this point.") }

        var maybeRequest: HTTPClient.Request?
        XCTAssertNoThrow(maybeRequest = try HTTPClient.Request(url: "http://swift.org/"))
        guard let request = maybeRequest else { return XCTFail("Expected to be able to create a request") }

        let delegate = ResponseAccumulator(request: request)
        var maybeRequestBag: RequestBag<ResponseAccumulator>?
        XCTAssertNoThrow(
            maybeRequestBag = try RequestBag(
                request: request,
                eventLoopPreference: .delegate(on: embedded.eventLoop),
                task: .init(eventLoop: embedded.eventLoop, logger: logger),
                redirectHandler: nil,
                connectionDeadline: .now() + .seconds(30),
                requestOptions: .forTests(),
                delegate: delegate
            )
        )
        guard let requestBag = maybeRequestBag else { return XCTFail("Expected to be able to create a request bag") }

        connection.sendableView.executeRequest(requestBag)

        let responseString = """
            HTTP/1.0 200 OK\r\n\
            HTTP/1.0 200 OK\r\n\r\n
            """

        XCTAssertNoThrow(try embedded.readOutbound(as: ByteBuffer.self))  // head
        XCTAssertNoThrow(try embedded.readOutbound(as: ByteBuffer.self))  // end

        XCTAssertEqual(connectionDelegate.hitConnectionClosed, 0)
        XCTAssertEqual(connectionDelegate.hitConnectionReleased, 0)
        XCTAssertNoThrow(try embedded.writeInbound(ByteBuffer(string: responseString)))
        XCTAssertFalse(embedded.isActive)
        (embedded.eventLoop as! EmbeddedEventLoop).run()  // tick once to run futures.
        XCTAssertEqual(connectionDelegate.hitConnectionClosed, 1)
        XCTAssertEqual(connectionDelegate.hitConnectionReleased, 0)
    }

    // In order to test backpressure we need to make sure that reads will not happen
    // until the backpressure promise is succeeded. Since we cannot guarantee when
    // messages will be delivered to a client pipeline and we need this test to be
    // fast (no waiting for arbitrary amounts of time), we do the following.
    // First, we enforce NIO to send us only 1 byte at a time. Then we send a message
    // of 4 bytes. This will guarantee that if we see first byte of the message, other
    // bytes a ready to be read as well. This will allow us to test if subsequent reads
    // are waiting for backpressure promise.
    func testDownloadStreamingBackpressure() {
        final class BackpressureTestDelegate: HTTPClientResponseDelegate {
            typealias Response = Void

            private struct State: Sendable {
                var reads = 0
                var channel: Channel?
            }

            private let state = NIOLockedValueBox(State())

            var reads: Int {
                self.state.withLockedValue { $0.reads }
            }

            let backpressurePromise: EventLoopPromise<Void>
            let messageReceived: EventLoopPromise<Void>

            init(eventLoop: EventLoop) {
                self.backpressurePromise = eventLoop.makePromise()
                self.messageReceived = eventLoop.makePromise()
            }

            func willExecuteOnChannel(_ channel: Channel) {
                self.state.withLockedValue {
                    $0.channel = channel
                }
            }

            func didReceiveHead(task: HTTPClient.Task<Void>, _ head: HTTPResponseHead) -> EventLoopFuture<Void> {
                task.futureResult.eventLoop.makeSucceededVoidFuture()
            }

            func didReceiveBodyPart(task: HTTPClient.Task<Response>, _ buffer: ByteBuffer) -> EventLoopFuture<Void> {
                // We count a number of reads received.
                self.state.withLockedValue {
                    $0.reads += 1
                }
                // We need to notify the test when first byte of the message is arrived.
                self.messageReceived.succeed(())
                return self.backpressurePromise.futureResult
            }

            func didFinishRequest(task: HTTPClient.Task<Response>) throws {}
        }

        final class WriteAfterFutureSucceedsHandler: ChannelInboundHandler {
            typealias InboundIn = HTTPServerRequestPart
            typealias OutboundOut = HTTPServerResponsePart

            let endFuture: EventLoopFuture<Void>

            init(endFuture: EventLoopFuture<Void>) {
                self.endFuture = endFuture
            }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                switch self.unwrapInboundIn(data) {
                case .head:
                    let head = HTTPResponseHead(version: HTTPVersion(major: 1, minor: 1), status: .ok)
                    context.writeAndFlush(wrapOutboundOut(.head(head)), promise: nil)
                case .body:
                    // ignore
                    break
                case .end:
                    let buffer = context.channel.allocator.buffer(string: "1234")
                    context.writeAndFlush(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)

                    self.endFuture.hop(to: context.eventLoop).assumeIsolated().whenSuccess {
                        context.writeAndFlush(Self.wrapOutboundOut(.end(nil)), promise: nil)
                    }
                }
            }
        }

        let logger = Logger(label: "test")

        // cannot test with NIOTS as `maxMessagesPerRead` is not supported
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully()) }
        let requestEventLoop = eventLoopGroup.next()
        let backpressureDelegate = BackpressureTestDelegate(eventLoop: requestEventLoop)

        let httpBin = HTTPBin { _ in
            WriteAfterFutureSucceedsHandler(
                endFuture: backpressureDelegate.backpressurePromise.futureResult
            )
        }
        defer { XCTAssertNoThrow(try httpBin.shutdown()) }

        var maybeChannel: Channel?
        XCTAssertNoThrow(
            maybeChannel = try ClientBootstrap(group: eventLoopGroup)
                .channelOption(ChannelOptions.maxMessagesPerRead, value: 1)
                .channelOption(ChannelOptions.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 1))
                .connect(host: "localhost", port: httpBin.port)
                .wait()
        )
        guard let channel = maybeChannel else { return XCTFail("Expected to have a channel at this point") }
        let connectionDelegate = MockConnectionDelegate()
        var maybeConnection: HTTP1Connection.SendableView?
        XCTAssertNoThrow(
            maybeConnection = try channel.eventLoop.submit {
                try HTTP1Connection.start(
                    channel: channel,
                    connectionID: 0,
                    delegate: connectionDelegate,
                    decompression: .disabled,
                    logger: logger
                ).sendableView
            }.wait()
        )
        guard let connection = maybeConnection else { return XCTFail("Expected to have a connection at this point") }

        var maybeRequestBag: RequestBag<BackpressureTestDelegate>?

        XCTAssertNoThrow(
            maybeRequestBag = try RequestBag(
                request: HTTPClient.Request(url: "http://localhost:\(httpBin.port)/custom"),
                eventLoopPreference: .delegate(on: requestEventLoop),
                task: .init(eventLoop: requestEventLoop, logger: logger),
                redirectHandler: nil,
                connectionDeadline: .now() + .seconds(30),
                requestOptions: .forTests(),
                delegate: backpressureDelegate
            )
        )
        guard let requestBag = maybeRequestBag else { return XCTFail("Expected to be able to create a request bag") }
        backpressureDelegate.willExecuteOnChannel(connection.channel)

        connection.executeRequest(requestBag)

        let requestFuture = requestBag.task.futureResult

        // Send 4 bytes, but only one should be received until the backpressure promise is succeeded.

        // Now we wait until message is delivered to client channel pipeline
        XCTAssertNoThrow(try backpressureDelegate.messageReceived.futureResult.wait())
        XCTAssertEqual(backpressureDelegate.reads, 1)

        // Succeed the backpressure promise.
        backpressureDelegate.backpressurePromise.succeed(())
        XCTAssertNoThrow(try requestFuture.wait())

        // At this point all other bytes should be delivered.
        XCTAssertEqual(backpressureDelegate.reads, 4)
    }
}

final class MockHTTP1ConnectionDelegate: HTTP1ConnectionDelegate {
    let releasePromise: EventLoopPromise<Void>?
    let closePromise: EventLoopPromise<Void>?

    init(releasePromise: EventLoopPromise<Void>? = nil, closePromise: EventLoopPromise<Void>? = nil) {
        self.releasePromise = releasePromise
        self.closePromise = closePromise
    }

    func http1ConnectionReleased(_: HTTPConnectionPool.Connection.ID) {
        self.releasePromise?.succeed(())
    }

    func http1ConnectionClosed(_: HTTPConnectionPool.Connection.ID) {
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
                context.write(
                    self.wrapOutboundOut(
                        .head(.init(version: .http1_1, status: .ok, headers: ["connection": "close"]))
                    ),
                    promise: nil
                )
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

            context.eventLoop.assumeIsolated().scheduleTask(in: .milliseconds(20)) {
                context.close(promise: nil)
            }
        }
    }
}

final class MockConnectionDelegate: HTTP1ConnectionDelegate {
    private let counts = NIOLockedValueBox<Counts>(Counts())

    private struct Counts: Sendable {
        var hitConnectionReleased = 0
        var hitConnectionClosed = 0
    }

    var hitConnectionReleased: Int {
        self.counts.withLockedValue { $0.hitConnectionReleased }
    }

    var hitConnectionClosed: Int {
        self.counts.withLockedValue { $0.hitConnectionClosed }
    }

    init() {}

    func http1ConnectionReleased(_: HTTPConnectionPool.Connection.ID) {
        self.counts.withLockedValue {
            $0.hitConnectionReleased += 1
        }
    }

    func http1ConnectionClosed(_: HTTPConnectionPool.Connection.ID) {
        self.counts.withLockedValue {
            $0.hitConnectionClosed += 1
        }
    }
}
