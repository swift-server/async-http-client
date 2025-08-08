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

import AsyncHTTPClient
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSOCKS
import XCTest

struct MockSOCKSError: Error, Hashable {
    var description: String
}

class TestSOCKSBadServerHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // just write some nonsense bytes
        let buffer = context.channel.allocator.buffer(bytes: [0xAA, 0xBB, 0xCC, 0xDD, 0xEE])
        context.writeAndFlush(.init(buffer), promise: nil)
    }
}

class MockSOCKSServer {
    let channel: Channel

    var port: Int {
        self.channel.localAddress!.port!
    }

    init(
        expectedURL: String,
        expectedResponse: String,
        misbehave: Bool = false,
        file: String = #filePath,
        line: UInt = #line
    ) throws {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let bootstrap: ServerBootstrap
        if misbehave {
            bootstrap = ServerBootstrap(group: elg)
                .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(TestSOCKSBadServerHandler())
                    }
                }
        } else {
            bootstrap = ServerBootstrap(group: elg)
                .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        let handshakeHandler = SOCKSServerHandshakeHandler()
                        try channel.pipeline.syncOperations.addHandlers([
                            handshakeHandler,
                            SOCKSTestHandler(handshakeHandler: handshakeHandler),
                            TestHTTPServer(
                                expectedURL: expectedURL,
                                expectedResponse: expectedResponse,
                                file: file,
                                line: line
                            ),
                        ])
                    }
                }
        }
        self.channel = try bootstrap.bind(host: "localhost", port: 0).wait()
    }

    func shutdown() throws {
        try self.channel.close().wait()
    }
}

class SOCKSTestHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ClientMessage

    let handshakeHandler: SOCKSServerHandshakeHandler

    init(handshakeHandler: SOCKSServerHandshakeHandler) {
        self.handshakeHandler = handshakeHandler
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard context.channel.isActive else {
            return
        }

        let message = self.unwrapInboundIn(data)
        switch message {
        case .greeting:
            context.writeAndFlush(
                .init(
                    ServerMessage.selectedAuthenticationMethod(.init(method: .noneRequired))
                ),
                promise: nil
            )
        case .authenticationData:
            context.fireErrorCaught(MockSOCKSError(description: "Received authentication data but didn't receive any."))
        case .request(let request):
            context.writeAndFlush(
                .init(
                    ServerMessage.response(.init(reply: .succeeded, boundAddress: request.addressType))
                ),
                promise: nil
            )

            do {
                try context.channel.pipeline.syncOperations.addHandlers(
                    [
                        ByteToMessageHandler(HTTPRequestDecoder()),
                        HTTPResponseEncoder(),
                    ],
                    position: .after(self)
                )
                context.channel.pipeline.syncOperations.removeHandler(self, promise: nil)
                context.channel.pipeline.syncOperations.removeHandler(self.handshakeHandler, promise: nil)
            } catch {
                context.fireErrorCaught(error)
            }
        }
    }
}

class TestHTTPServer: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    let expectedURL: String
    let expectedResponse: String
    let file: String
    let line: UInt
    var requestCount = 0

    init(expectedURL: String, expectedResponse: String, file: String, line: UInt) {
        self.expectedURL = expectedURL
        self.expectedResponse = expectedResponse
        self.file = file
        self.line = line
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = self.unwrapInboundIn(data)
        switch message {
        case .head(let head):
            guard self.requestCount == 0 else {
                return
            }
            XCTAssertEqual(head.uri, self.expectedURL)
            self.requestCount += 1
        case .body:
            break
        case .end:
            context.write(self.wrapOutboundOut(.head(.init(version: .http1_1, status: .ok))), promise: nil)
            context.write(
                self.wrapOutboundOut(
                    .body(.byteBuffer(context.channel.allocator.buffer(string: self.expectedResponse)))
                ),
                promise: nil
            )
            context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.fireErrorCaught(error)
        context.close(promise: nil)
    }
}
