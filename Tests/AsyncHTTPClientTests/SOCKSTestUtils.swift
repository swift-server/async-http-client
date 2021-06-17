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
import NIO
import NIOHTTP1
import NIOSOCKS
import XCTest

struct MockSOCKSError: Error, Hashable {
    var description: String
}

class MockSOCKSServer {
    
    let channel: Channel
    
    public init(expectedURL: String, expectedResponse: String, file: String = (#file), line: UInt = #line) throws {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let bootstrap = ServerBootstrap.init(group: elg)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelInitializer { channel in
                let handshakeHandler = SOCKSServerHandshakeHandler()
                return channel.pipeline.addHandlers([
                    handshakeHandler,
                    SOCKSTestHandler(handshakeHandler: handshakeHandler),
                    SOCKSTestHTTPClient(expectedURL: expectedURL, expectedResponse: expectedResponse, file: file, line: line)
                ])
            }
        self.channel = try bootstrap.bind(host: "127.0.0.1", port: 1080).wait()
    }
    
    func shutdown() throws {
        try self.channel.close().wait()
    }
    
}

class SOCKSTestHTTPClient: ChannelInboundHandler {
    
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    
    let expectedURL: String
    let expectedResponse: String
    let file: String
    let line: UInt
    
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
            XCTAssertEqual(head.uri, self.expectedURL)
        case .body:
            break
        case .end:
            context.write(self.wrapOutboundOut(.head(.init(version: .http1_1, status: .ok))), promise: nil)
            context.write(self.wrapOutboundOut(.body(.byteBuffer(context.channel.allocator.buffer(string: self.expectedResponse)))), promise: nil)
            context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
        }
    }
}

class SOCKSTestHandler: ChannelInboundHandler, RemovableChannelHandler {
    
    typealias InboundIn = ClientMessage
    
    let handshakeHandler: SOCKSServerHandshakeHandler
    
    init(handshakeHandler: SOCKSServerHandshakeHandler) {
        self.handshakeHandler = handshakeHandler
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = self.unwrapInboundIn(data)
        switch message {
        case .greeting:
            context.write(.init(
                ServerMessage.selectedAuthenticationMethod(.init(method: .noneRequired))), promise: nil)
            context.writeAndFlush(.init(
                ServerMessage.authenticationData(context.channel.allocator.buffer(capacity: 0), complete: true)), promise: nil)
        case .authenticationData:
            context.fireErrorCaught(MockSOCKSError(description: "Received authentication data but didn't receive any."))
        case .request(let request):
            context.writeAndFlush(.init(
                ServerMessage.response(.init(reply: .succeeded, boundAddress: request.addressType))), promise: nil)
            context.channel.pipeline.addHandlers([
                ByteToMessageHandler(HTTPRequestDecoder()),
                HTTPResponseEncoder(),
            ], position: .after(self)).whenSuccess {
                context.channel.pipeline.removeHandler(self, promise: nil)
                context.channel.pipeline.removeHandler(self.handshakeHandler, promise: nil)
            }
        }
    }
    
}
