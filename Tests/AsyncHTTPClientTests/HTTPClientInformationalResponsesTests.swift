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
import NIOCore
import NIOHTTP1
import XCTest

final class HTTPClientReproTests: XCTestCase {
    func testServerSends100ContinueFirst() {
        final class HTTPInformationalResponseHandler: ChannelInboundHandler {
            typealias InboundIn = HTTPServerRequestPart
            typealias OutboundOut = HTTPServerResponsePart

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                switch self.unwrapInboundIn(data) {
                case .head:
                    context.writeAndFlush(
                        self.wrapOutboundOut(.head(.init(version: .http1_1, status: .continue))),
                        promise: nil
                    )
                case .body:
                    break
                case .end:
                    context.write(self.wrapOutboundOut(.head(.init(version: .http1_1, status: .ok))), promise: nil)
                    context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
                }
            }
        }

        let client = HTTPClient(eventLoopGroupProvider: .singleton)
        defer { XCTAssertNoThrow(try client.syncShutdown()) }

        let httpBin = HTTPBin(.http1_1(ssl: false, compress: false)) { _ in
            HTTPInformationalResponseHandler()
        }

        let body = #"{"foo": "bar"}"#

        var maybeRequest: HTTPClient.Request?
        XCTAssertNoThrow(
            maybeRequest = try HTTPClient.Request(
                url: "http://localhost:\(httpBin.port)/",
                method: .POST,
                headers: [
                    "Content-Type": "application/json"
                ],
                body: .string(body)
            )
        )
        guard let request = maybeRequest else { return XCTFail("Expected to have a request here") }

        var logger = Logger(label: "test")
        logger.logLevel = .trace

        var response: HTTPClient.Response?
        XCTAssertNoThrow(response = try client.execute(request: request, logger: logger).wait())
        XCTAssertEqual(response?.status, .ok)
    }

    func testServerSendsSwitchingProtocols() {
        final class HTTPInformationalResponseHandler: ChannelInboundHandler {
            typealias InboundIn = HTTPServerRequestPart
            typealias OutboundOut = HTTPServerResponsePart

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                switch self.unwrapInboundIn(data) {
                case .head:
                    let head = HTTPResponseHead(
                        version: .http1_1,
                        status: .switchingProtocols,
                        headers: [
                            "Connection": "Upgrade",
                            "Upgrade": "Websocket",
                        ]
                    )
                    let body = context.channel.allocator.buffer(string: "foo bar")

                    context.write(self.wrapOutboundOut(.head(head)), promise: nil)
                    context.write(self.wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
                    // we purposefully don't send an `.end` here.
                    context.flush()
                case .body:
                    break
                case .end:
                    break
                }
            }
        }

        let client = HTTPClient(eventLoopGroupProvider: .singleton)
        defer { XCTAssertNoThrow(try client.syncShutdown()) }

        let httpBin = HTTPBin(.http1_1(ssl: false, compress: false)) { _ in
            HTTPInformationalResponseHandler()
        }

        let body = #"{"foo": "bar"}"#

        var maybeRequest: HTTPClient.Request?
        XCTAssertNoThrow(
            maybeRequest = try HTTPClient.Request(
                url: "http://localhost:\(httpBin.port)/",
                method: .POST,
                headers: [
                    "Content-Type": "application/json"
                ],
                body: .string(body)
            )
        )
        guard let request = maybeRequest else { return XCTFail("Expected to have a request here") }

        var logger = Logger(label: "test")
        logger.logLevel = .trace

        var response: HTTPClient.Response?
        XCTAssertNoThrow(response = try client.execute(request: request, logger: logger).wait())
        XCTAssertEqual(response?.status, .switchingProtocols)
        XCTAssertNil(response?.body)
    }
}
