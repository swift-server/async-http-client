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
import NIOCore
import NIOPosix
import NIOSOCKS
import NIOSSL
import XCTest

@testable import AsyncHTTPClient

class HTTPConnectionPool_FactoryTests: XCTestCase {
    func testConnectionCreationTimesoutIfDeadlineIsInThePast() {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }

        var server: Channel?
        XCTAssertNoThrow(
            server = try ServerBootstrap(group: group)
                .childChannelInitializer { channel in
                    channel.pipeline.addHandler(NeverrespondServerHandler())
                }
                .bind(to: .init(ipAddress: "127.0.0.1", port: 0))
                .wait()
        )
        defer {
            XCTAssertNoThrow(try server?.close().wait())
        }

        let request = try! HTTPClient.Request(url: "https://apple.com")

        let factory = HTTPConnectionPool.ConnectionFactory(
            key: .init(request),
            tlsConfiguration: nil,
            clientConfiguration: .init(proxy: .socksServer(host: "127.0.0.1", port: server!.localAddress!.port!)),
            sslContextCache: .init()
        )

        XCTAssertThrowsError(
            try factory.makeChannel(
                requester: ExplodingRequester(),
                connectionID: 1,
                deadline: .now() - .seconds(1),
                eventLoop: group.next(),
                logger: .init(label: "test")
            ).wait()
        ) {
            guard let error = $0 as? ChannelError, case .connectTimeout = error else {
                XCTFail("Unexpected error: \($0)")
                return
            }
        }
    }

    func testSOCKSConnectionCreationTimesoutIfRemoteIsUnresponsive() {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }

        var server: Channel?
        XCTAssertNoThrow(
            server = try ServerBootstrap(group: group)
                .childChannelInitializer { channel in
                    channel.pipeline.addHandler(NeverrespondServerHandler())
                }
                .bind(to: .init(ipAddress: "127.0.0.1", port: 0))
                .wait()
        )
        defer {
            XCTAssertNoThrow(try server?.close().wait())
        }

        let request = try! HTTPClient.Request(url: "https://apple.com")

        let factory = HTTPConnectionPool.ConnectionFactory(
            key: .init(request),
            tlsConfiguration: nil,
            clientConfiguration: .init(proxy: .socksServer(host: "127.0.0.1", port: server!.localAddress!.port!))
                .enableFastFailureModeForTesting(),
            sslContextCache: .init()
        )

        XCTAssertThrowsError(
            try factory.makeChannel(
                requester: ExplodingRequester(),
                connectionID: 1,
                deadline: .now() + .seconds(1),
                eventLoop: group.next(),
                logger: .init(label: "test")
            ).wait()
        ) {
            XCTAssertEqual($0 as? HTTPClientError, .socksHandshakeTimeout)
        }
    }

    func testHTTPProxyConnectionCreationTimesoutIfRemoteIsUnresponsive() {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }

        var server: Channel?
        XCTAssertNoThrow(
            server = try ServerBootstrap(group: group)
                .childChannelInitializer { channel in
                    channel.pipeline.addHandler(NeverrespondServerHandler())
                }
                .bind(to: .init(ipAddress: "127.0.0.1", port: 0))
                .wait()
        )
        defer {
            XCTAssertNoThrow(try server?.close().wait())
        }

        let request = try! HTTPClient.Request(url: "https://localhost:\(server!.localAddress!.port!)")

        let factory = HTTPConnectionPool.ConnectionFactory(
            key: .init(request),
            tlsConfiguration: nil,
            clientConfiguration: .init(proxy: .server(host: "127.0.0.1", port: server!.localAddress!.port!))
                .enableFastFailureModeForTesting(),
            sslContextCache: .init()
        )

        XCTAssertThrowsError(
            try factory.makeChannel(
                requester: ExplodingRequester(),
                connectionID: 1,
                deadline: .now() + .seconds(1),
                eventLoop: group.next(),
                logger: .init(label: "test")
            ).wait()
        ) {
            XCTAssertEqual($0 as? HTTPClientError, .httpProxyHandshakeTimeout)
        }
    }

    func testTLSConnectionCreationTimesoutIfRemoteIsUnresponsive() {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }

        var server: Channel?
        XCTAssertNoThrow(
            server = try ServerBootstrap(group: group)
                .childChannelInitializer { channel in
                    channel.pipeline.addHandler(NeverrespondServerHandler())
                }
                .bind(to: .init(ipAddress: "127.0.0.1", port: 0))
                .wait()
        )
        defer {
            XCTAssertNoThrow(try server?.close().wait())
        }

        let request = try! HTTPClient.Request(url: "https://localhost:\(server!.localAddress!.port!)")

        var tlsConfig = TLSConfiguration.makeClientConfiguration()
        tlsConfig.certificateVerification = .none
        let factory = HTTPConnectionPool.ConnectionFactory(
            key: .init(request),
            tlsConfiguration: nil,
            clientConfiguration: .init(tlsConfiguration: tlsConfig)
                .enableFastFailureModeForTesting(),
            sslContextCache: .init()
        )

        XCTAssertThrowsError(
            try factory.makeChannel(
                requester: ExplodingRequester(),
                connectionID: 1,
                deadline: .now() + .seconds(1),
                eventLoop: group.next(),
                logger: .init(label: "test")
            ).wait()
        ) {
            XCTAssertEqual($0 as? HTTPClientError, .tlsHandshakeTimeout)
        }
    }
}

final class NeverrespondServerHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = NIOAny

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // do nothing
    }
}

/// A `HTTPConnectionRequester` that will fail a test if any of its methods are ever called.
final class ExplodingRequester: HTTPConnectionRequester {
    func http1ConnectionCreated(_: HTTP1Connection.SendableView) {
        XCTFail("http1ConnectionCreated called unexpectedly")
    }

    func http2ConnectionCreated(_: HTTP2Connection.SendableView, maximumStreams: Int) {
        XCTFail("http2ConnectionCreated called unexpectedly")
    }

    func failedToCreateHTTPConnection(_: HTTPConnectionPool.Connection.ID, error: Error) {
        XCTFail("failedToCreateHTTPConnection called unexpectedly")
    }

    func waitingForConnectivity(_: HTTPConnectionPool.Connection.ID, error: Error) {
        XCTFail("waitingForConnectivity called unexpectedly")
    }
}

extension HTTPConnectionPool.ConnectionFactory {
    fileprivate func makeChannel<Requester: HTTPConnectionRequester>(
        requester: Requester,
        connectionID: HTTPConnectionPool.Connection.ID,
        deadline: NIODeadline,
        eventLoop: EventLoop,
        logger: Logger
    ) -> EventLoopFuture<NegotiatedProtocol> {
        let promise = eventLoop.makePromise(of: NegotiatedProtocol.self)
        self.makeChannel(
            requester: requester,
            connectionID: connectionID,
            deadline: deadline,
            eventLoop: eventLoop,
            logger: logger,
            promise: promise
        )
        return promise.futureResult
    }
}
