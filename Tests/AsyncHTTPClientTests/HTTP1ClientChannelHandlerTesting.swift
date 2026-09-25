//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2026 Apple Inc. and the AsyncHTTPClient project authors
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
import NIOEmbedded
import NIOHTTP1
import Testing

@testable import AsyncHTTPClient

struct HTTP1ClientChannelHandlerTesting {
    /// If the response end is received before the request body stream is finished, the connection is
    /// marked idle from within the write promise of the request `.end`. On a real channel that write
    /// promise may run synchronously inside `writeAndFlush`. We use that promise to signal to
    /// the pool that the connection has become idle. Therefore the connection pool may schedule the
    /// next request onto the connection synchronously from `onConnectionIdle`. The handler must not
    /// apply the old request's idle timeout transitions to the new request.
    @Test func newRequestScheduledFromOnConnectionIdleDuringRequestEndWrite() throws {
        let eventLoop = EmbeddedEventLoop()
        let handler = HTTP1ClientChannelHandler(
            eventLoop: eventLoop,
            backgroundLogger: Logger(label: "no-op", factory: SwiftLogNoOpLogHandler.init),
            connectionIdLoggerMetadata: "test connection"
        )
        let channel = EmbeddedChannel(handlers: [handler], loop: eventLoop)
        try channel.connect(to: .init(ipAddress: "127.0.0.1", port: 80)).wait()

        let firstRequest = MockHTTPExecutableRequest(
            head: .init(version: .http1_1, method: .POST, uri: "http://localhost/"),
            framingMetadata: RequestFramingMetadata(connectionClose: false, body: .stream),
            requestOptions: .forTests(idleReadTimeout: .milliseconds(200)),
            raiseErrorIfUnimplementedMethodIsCalled: false
        )
        let secondRequest = MockHTTPExecutableRequest(
            head: .init(version: .http1_1, method: .GET, uri: "http://localhost/"),
            framingMetadata: RequestFramingMetadata(connectionClose: false, body: .fixedSize(0)),
            requestOptions: .forTests(idleReadTimeout: .milliseconds(200)),
            raiseErrorIfUnimplementedMethodIsCalled: false
        )

        // Mimic the connection pool, which synchronously executes the next queued request on the
        // connection if it is informed about the idle connection on the connection's event loop.
        var connectionIdleCount = 0
        handler.onConnectionIdle = {
            connectionIdleCount += 1
            if connectionIdleCount == 1 {
                channel.write(secondRequest, promise: nil)
            }
        }

        let executor = handler.requestExecutor
        firstRequest.resumeRequestBodyStreamCallback = {
            executor.writeRequestBodyPart(.byteBuffer(.init(string: "Hello")), request: firstRequest, promise: nil)
        }

        channel.write(firstRequest, promise: nil)
        #expect(try channel.readOutbound(as: HTTPClientRequestPart.self) == .head(firstRequest.requestHead))
        #expect(
            try channel.readOutbound(as: HTTPClientRequestPart.self) == .body(.byteBuffer(.init(string: "Hello")))
        )

        // Receive the full response, while the request body stream is still open.
        try channel.writeInbound(HTTPClientResponsePart.head(.init(version: .http1_1, status: .ok)))
        channel.read()
        try channel.writeInbound(HTTPClientResponsePart.end(nil))

        // Finishing the body stream writes `.end`. The EmbeddedChannel succeeds the write promise
        // synchronously in `flush`, which marks the connection idle, which in turn writes the second
        // request into the handler before `writeAndFlush` has returned.
        executor.finishRequestBodyStream(trailers: nil, request: firstRequest, promise: nil)

        #expect(try channel.readOutbound(as: HTTPClientRequestPart.self) == .end(nil))
        #expect(try channel.readOutbound(as: HTTPClientRequestPart.self) == .head(secondRequest.requestHead))
        #expect(try channel.readOutbound(as: HTTPClientRequestPart.self) == .end(nil))
        #expect(connectionIdleCount == 1)

        #expect(
            firstRequest.events.map(\.kind) == [
                .willExecuteRequest, .requestHeadSent, .resumeRequestBodyStream,
                .receiveResponseHead, .receiveResponseEnd, .requestBodySent,
            ]
        )
        #expect(secondRequest.events.map(\.kind) == [.willExecuteRequest, .requestHeadSent])

        // The second request's idle read timeout must still work as expected.
        eventLoop.advanceTime(by: .milliseconds(250))
        #expect(secondRequest.events.map(\.kind) == [.willExecuteRequest, .requestHeadSent, .fail])
        if case .fail(let error) = secondRequest.events.last {
            #expect(error as? HTTPClientError == .readTimeout)
        }
        #expect(!channel.isActive)
    }
}
