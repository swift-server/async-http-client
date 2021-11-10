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
import Logging
import XCTest
import NIOSSL
import NIOCore
import NIOPosix
import NIOHTTP1

final class HTTPClientUncleanShutdownTests: XCTestCase {
    
}

final class HttpBinForSSLUncleanShutdown {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let serverChannel: Channel

    var port: Int {
        return Int(self.serverChannel.localAddress!.port!)
    }

    init(channelPromise: EventLoopPromise<Channel>? = nil) {
        
        let configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(TestTLS.certificate)],
            privateKey: .privateKey(TestTLS.privateKey)
        )
        let context = try! NIOSSLContext(configuration: configuration)
        
        self.serverChannel = try! ServerBootstrap(group: self.group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
            .childChannelInitializer { channel in
                do {
                    let requestDecoder = HTTPRequestDecoder()
                    let sync = channel.pipeline.syncOperations
                    
                    try sync.addHandler(NIOSSLServerHandler(context: context))
                    try sync.addHandler(ByteToMessageHandler(requestDecoder))
                    try sync.addHandler(HttpBinForSSLUncleanShutdownHandler(channelPromise: channelPromise))
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }.bind(host: "127.0.0.1", port: 0).wait()
    }

    func shutdown() {
        try! self.group.syncShutdownGracefully()
    }
}

final class HttpBinForSSLUncleanShutdownHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = ByteBuffer

    let channelPromise: EventLoopPromise<Channel>?

    init(channelPromise: EventLoopPromise<Channel>? = nil) {
        self.channelPromise = channelPromise
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch self.unwrapInboundIn(data) {
        case .head(let req):
            self.channelPromise?.succeed(context.channel)

            let response: String?
            switch req.uri {
            case "/nocontentlength":
                response = """
                HTTP/1.1 200 OK\r\n\
                Connection: close\r\n\
                \r\n\
                foo
                """
            case "/nocontent":
                response = """
                HTTP/1.1 204 OK\r\n\
                Connection: close\r\n\
                \r\n
                """
            case "/noresponse":
                response = nil
            case "/wrongcontentlength":
                response = """
                HTTP/1.1 200 OK\r\n\
                Connection: close\r\n\
                Content-Length: 6\r\n\
                \r\n\
                foo
                """
            default:
                response = """
                HTTP/1.1 404 OK\r\n\
                Connection: close\r\n\
                Content-Length: 9\r\n\
                \r\n\
                Not Found
                """
            }

            if let response = response {
                var buffer = context.channel.allocator.buffer(capacity: response.count)
                buffer.writeString(response)
                context.writeAndFlush(self.wrapOutboundOut(buffer), promise: nil)
            }

            context.channel.pipeline.removeHandler(name: "NIOSSLServerHandler").whenSuccess {
                context.close(promise: nil)
            }
        case .body:
            ()
        case .end:
            ()
        }
    }
}
