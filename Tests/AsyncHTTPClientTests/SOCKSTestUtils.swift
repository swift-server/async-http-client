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
import NIOSSL
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
        tlsConfiguration: TLSConfiguration? = nil,
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
                        let promise = channel.eventLoop.makePromise(of: Void.self)
                        let socksTestHandler = SOCKSTestHandler(
                            handshakeHandler: handshakeHandler,
                            promise: promise
                        )

                        try channel.pipeline.syncOperations.addHandlers([
                            handshakeHandler,
                            socksTestHandler,
                        ])

                        // The SOCKS handlers must be fully torn down before the origin's TLS
                        // handshake (if any) is set up: adding an `NIOSSLServerHandler` — which
                        // proactively drives the handshake from `handlerAdded` — while the SOCKS
                        // handlers are still mid-removal in the same call stack races with that
                        // teardown and corrupts the connection. Deferring to a completion callback
                        // (mirroring `HTTPBin`'s own HTTP-CONNECT-proxy teardown) avoids that.
                        promise.futureResult.assumeIsolated().flatMap {
                            channel.pipeline.syncOperations.removeHandler(socksTestHandler)
                        }.flatMap { _ in
                            channel.pipeline.syncOperations.removeHandler(handshakeHandler)
                        }.nonisolated().whenComplete { result in
                            switch result {
                            case .failure:
                                channel.close(mode: .all, promise: nil)
                            case .success:
                                do {
                                    let sync = channel.pipeline.syncOperations
                                    if let tlsConfiguration {
                                        let sslContext = try NIOSSLContext(configuration: tlsConfiguration)
                                        try sync.addHandler(NIOSSLServerHandler(context: sslContext))
                                    }
                                    try sync.addHandlers([
                                        ByteToMessageHandler(HTTPRequestDecoder()),
                                        HTTPResponseEncoder(),
                                        TestHTTPServer(
                                            expectedURL: expectedURL,
                                            expectedResponse: expectedResponse,
                                            file: file,
                                            line: line
                                        ),
                                    ])
                                } catch {
                                    channel.close(mode: .all, promise: nil)
                                }
                            }
                        }
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
    let promise: EventLoopPromise<Void>

    init(handshakeHandler: SOCKSServerHandshakeHandler, promise: EventLoopPromise<Void>) {
        self.handshakeHandler = handshakeHandler
        self.promise = promise
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
            self.promise.succeed(())
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        self.promise.fail(error)
        context.fireErrorCaught(error)
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
