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

// These tests may require some more context:
//
// TLS (SSL) encrypts, validates, and authenticates all the data that goes through the connection.
// That is a fantastic property to have and solves most issues. TLS however still runs over TCP and
// the control packets of TCP are not encrypted. This means that the one thing an attacker can still
// do on a TLS connection is to close it. The attacker could send RST or FIN packets the other peer
// and the receiving peer has no means to verify if this RST/FIN packet is actually coming from the
// other peer (as opposed to an attacker).
//
// To fix this problem, TLS introduces a close_notify message that is send over connection as
// encrypted data. So if the other peer receives a close_notify it knows that it was truly sent by
// the other peer (and not an attacker). A well behaving peer would then reply to the close_notify
// with its own close_notify and after that both peers can close the TCP connection because they
// know that the respective other peer knows they're okay closing it.
//
// Okay, but what's the issue with having a connection just close. Wouldn't I notice that part of
// the data is missing? The answer is it depends. Many protocols actually send to the other peer how
// much data they will send before sending the data. And they also have a well defined
// "end message". If you're using such a protocol, then an "unclean shutdown" (which is you have
// received a RST/FIN without a close_notify) is totally harmless. The higher level protocol allows
// you to distinguish between a truncated message (when there's still outstanding data) and a close
// after a completed message.
//
// The reason SwiftNIO sends you a NIOSSLError.uncleanShutdown if it sees a connection closing
// without a prior close_notify is because it doesn't know what protocol you're implementing. Maybe
// the protocol you speak doesn't transmit length information so a truncated message cannot be told
// apart from a complete message.
//
// Let's go into some example protocols and their behaviour regarding framing:
//
//  - With HTTP/2 the other peer always knows how much data to expect, so an unclean shutdown is
//    totally harmless, the error can be ignored.
//  - With HTTP/1, the situation is much more complicated: HTTP/1 when using the content-length
//    header is unaffected by truncation attacks because we know the content length. So if the
//    connection closes before we have received that many bytes, we know it was a truncated message
//    (either by an attacker injecting a FIN/RST, or by a software/network problem somewhere along
//    the way)
//  - HTTP/1 with transfer-encoding: chunked is also unaffected by truncation attacks because each
//    chunk sends its length and there's a special "END" chunk (0\r\n\r\n). Unfortunately HTTP/1 can
//    be used without either transfer-encoding: chunked or content-length. It then runs in the "EOF
//    framing" mode which means that the message ends when we receive a connection close 😢 . Very
//    bad, if HTTP/1 is used in "EOF framing" mode, then an unclean shutdown is actually a real
//    error because we cannot tell a truncated message apart from a complete message.
//
// From @weissi in https://github.com/swift-server/async-http-client/issues/238

import AsyncHTTPClient
import Logging
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import XCTest

final class HTTPClientUncleanSSLConnectionShutdownTests: XCTestCase {
    func testEOFFramedSuccess() {
        let httpBin = HTTPBinForSSLUncleanShutdown()
        defer { XCTAssertNoThrow(try httpBin.shutdown()) }

        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully()) }

        let client = HTTPClient(
            eventLoopGroupProvider: .shared(eventLoopGroup),
            configuration: .init(certificateVerification: .none)
        )
        defer { XCTAssertNoThrow(try client.syncShutdown()) }

        XCTAssertThrowsError(try client.get(url: "https://localhost:\(httpBin.port)/nocontentlength").wait()) {
            XCTAssertEqual($0 as? NIOSSLError, .uncleanShutdown)
        }
    }

    func testContentLength() {
        let httpBin = HTTPBinForSSLUncleanShutdown()
        defer { XCTAssertNoThrow(try httpBin.shutdown()) }

        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully()) }

        let client = HTTPClient(
            eventLoopGroupProvider: .shared(eventLoopGroup),
            configuration: .init(certificateVerification: .none)
        )
        defer { XCTAssertNoThrow(try client.syncShutdown()) }

        var response: HTTPClient.Response?
        XCTAssertNoThrow(response = try client.get(url: "https://localhost:\(httpBin.port)/contentlength").wait())
        XCTAssertEqual(response?.status, .notFound)
        XCTAssertEqual(response?.headers["content-length"].first, "9")
    }

    func testContentLengthButTruncated() {
        let httpBin = HTTPBinForSSLUncleanShutdown()
        defer { XCTAssertNoThrow(try httpBin.shutdown()) }

        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully()) }

        let client = HTTPClient(
            eventLoopGroupProvider: .shared(eventLoopGroup),
            configuration: .init(certificateVerification: .none)
        )
        defer { XCTAssertNoThrow(try client.syncShutdown()) }

        XCTAssertThrowsError(try client.get(url: "https://localhost:\(httpBin.port)/wrongcontentlength").wait()) {
            XCTAssertEqual($0 as? HTTPParserError, .invalidEOFState)
        }
    }

    func testTransferEncoding() {
        let httpBin = HTTPBinForSSLUncleanShutdown()
        defer { XCTAssertNoThrow(try httpBin.shutdown()) }

        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully()) }

        let client = HTTPClient(
            eventLoopGroupProvider: .shared(eventLoopGroup),
            configuration: .init(certificateVerification: .none)
        )
        defer { XCTAssertNoThrow(try client.syncShutdown()) }

        var response: HTTPClient.Response?
        XCTAssertNoThrow(response = try client.get(url: "https://localhost:\(httpBin.port)/transferencoding").wait())
        XCTAssertEqual(response?.status, .ok)
        XCTAssertEqual(response?.headers["transfer-encoding"].first, "chunked")
        XCTAssertEqual(response?.body, ByteBuffer(string: "foo"))
    }

    func testTransferEncodingButTruncated() {
        let httpBin = HTTPBinForSSLUncleanShutdown()
        defer { XCTAssertNoThrow(try httpBin.shutdown()) }

        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully()) }

        let client = HTTPClient(
            eventLoopGroupProvider: .shared(eventLoopGroup),
            configuration: .init(certificateVerification: .none)
        )
        defer { XCTAssertNoThrow(try client.syncShutdown()) }

        XCTAssertThrowsError(try client.get(url: "https://localhost:\(httpBin.port)/transferencodingtruncated").wait())
        {
            XCTAssertEqual($0 as? HTTPParserError, .invalidEOFState)
        }
    }

    func testConnectionDrop() {
        let httpBin = HTTPBinForSSLUncleanShutdown()
        defer { XCTAssertNoThrow(try httpBin.shutdown()) }

        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully()) }

        let client = HTTPClient(
            eventLoopGroupProvider: .shared(eventLoopGroup),
            configuration: .init(certificateVerification: .none)
        )
        defer { XCTAssertNoThrow(try client.syncShutdown()) }

        XCTAssertThrowsError(try client.get(url: "https://localhost:\(httpBin.port)/noresponse").wait()) {
            XCTAssertEqual($0 as? HTTPClientError, .remoteConnectionClosed)
        }
    }
}

final class HTTPBinForSSLUncleanShutdown {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let serverChannel: Channel

    var port: Int {
        Int(self.serverChannel.localAddress!.port!)
    }

    init() {
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

                    try sync.addHandler(ConnectionForceCloser())
                    try sync.addHandler(NIOSSLServerHandler(context: context))
                    try sync.addHandler(ByteToMessageHandler(requestDecoder))
                    try sync.addHandler(HTTPBinForSSLUncleanShutdownHandler())
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }.bind(host: "127.0.0.1", port: 0).wait()
    }

    func shutdown() throws {
        try self.group.syncShutdownGracefully()
    }
}

private final class HTTPBinForSSLUncleanShutdownHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = ByteBuffer

    init() {}

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch self.unwrapInboundIn(data) {
        case .head(let req):
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

            case "/transferencoding":
                response = """
                    HTTP/1.1 200 OK\r\n\
                    Connection: close\r\n\
                    Transfer-Encoding: chunked\r\n\
                    \r\n\
                    3\r\n\
                    foo\r\n\
                    0\r\n\
                    \r\n
                    """

            case "/transferencodingtruncated":
                response = """
                    HTTP/1.1 200 OK\r\n\
                    Connection: close\r\n\
                    Transfer-Encoding: chunked\r\n\
                    \r\n\
                    12\r\n\
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

            context.triggerUserOutboundEvent(ConnectionForceCloser.CloseEvent(), promise: nil)
        case .body:
            ()
        case .end:
            ()
        }
    }
}

private final class ConnectionForceCloser: ChannelOutboundHandler {
    typealias OutboundIn = NIOAny

    struct CloseEvent {}

    init() {}

    func triggerUserOutboundEvent(context: ChannelHandlerContext, event: Any, promise: EventLoopPromise<Void>?) {
        switch event {
        case is CloseEvent:
            context.close(promise: promise)
        default:
            context.triggerUserOutboundEvent(event, promise: promise)
        }
    }
}
