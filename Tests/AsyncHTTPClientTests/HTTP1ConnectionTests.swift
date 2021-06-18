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
import NIO
import NIOHTTP1
import NIOHTTPCompression
import NIOTestUtils
import XCTest

class HTTP1ConnectionTests: XCTestCase {
    func testCreateNewConnectionWithDecompression() {
        let embedded = EmbeddedChannel()
        let logger = Logger(label: "test.http1.connection")

        XCTAssertNoThrow(try embedded.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 3000)).wait())

        var connection: HTTP1Connection?
        XCTAssertNoThrow(connection = try HTTP1Connection(
            channel: embedded,
            connectionID: 0,
            configuration: .init(decompression: .enabled(limit: .ratio(4))),
            delegate: MockHTTP1ConnectionDelegate(),
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

        XCTAssertNoThrow(try HTTP1Connection(
            channel: embedded,
            connectionID: 0,
            configuration: .init(decompression: .disabled),
            delegate: MockHTTP1ConnectionDelegate(),
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

        XCTAssertThrowsError(try HTTP1Connection(
            channel: embedded,
            connectionID: 0,
            configuration: .init(),
            delegate: MockHTTP1ConnectionDelegate(),
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

        var logger = Logger(label: "test")
        logger.logLevel = .trace
        let delegate = MockHTTP1ConnectionDelegate()
        delegate.closePromise = clientEL.makePromise(of: Void.self)

        let connection = try! ClientBootstrap(group: clientEL)
            .connect(to: .init(ipAddress: "127.0.0.1", port: server.serverPort))
            .flatMapThrowing {
                try HTTP1Connection(
                    channel: $0,
                    connectionID: 0,
                    configuration: .init(decompression: .disabled),
                    delegate: delegate,
                    logger: logger
                )
            }
            .wait()

        var maybeRequest: HTTPClient.Request?
        XCTAssertNoThrow(maybeRequest = try HTTPClient.Request(
            url: "http://localhost/hello/swift",
            method: .POST, headers: HTTPHeaders([("content-length", "4")]),
            body: .stream { writer -> EventLoopFuture<Void> in
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

        let requestBag = RequestBag(
            request: request,
            eventLoopPreference: .delegate(on: clientEL),
            task: task,
            redirectHandler: nil,
            connectionDeadline: .now() + .seconds(60),
            idleReadTimeout: nil,
            delegate: ResponseAccumulator(request: request)
        )
        connection.execute(request: requestBag)

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
