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

import Testing
import AsyncHTTPClient
import NIOCore
import NIOHTTP1

@Suite("Request and response streaming")
struct BidirectionalStreamingTests {
    @Test func requestStreamCanOutliveResponse() async throws {
        let (bodyStream, bodyWriteContinuation) = AsyncStream.makeStream(of: AsyncStream<ByteBuffer>.self)
        let httpBin = HTTPBin { _ in
            let (stream, continuation) = AsyncStream.makeStream(of: ByteBuffer.self)
            bodyWriteContinuation.yield(stream)
            return HTTPRequestStreamingChannel(bodyStreamContinuation: continuation)
        }

        defer { #expect(throws: Never.self) { try httpBin.shutdown() } }

        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)

        var request = HTTPClientRequest(url: "http://localhost:\(httpBin.port)")
        let (stream, continuation) = AsyncStream.makeStream(of: ByteBuffer.self)
        request.body = .stream(stream, length: .unknown)

        await #expect(throws: Never.self) {
            let response = try await httpClient.execute(request, timeout: .seconds(60), logger: nil)
            var iterator = response.body.makeAsyncIterator()
            #expect(try await iterator.next() == nil)
        }

        var bodyStreamIterator = bodyStream.makeAsyncIterator()

        let serverRequestStream = await bodyStreamIterator.next()
        guard let serverRequestStream else {
            Issue.record("Could not get the server request stream")
            return
        }
        var receivedWritesIterator = serverRequestStream.makeAsyncIterator()

        let payload1 = ByteBuffer(string: "Hello World! 1")
        continuation.yield(payload1)
        #expect(await receivedWritesIterator.next() == payload1)
        let payload2 = ByteBuffer(string: "Hello World! 2")
        continuation.yield(payload2)
        #expect(await receivedWritesIterator.next() == payload2)
        let payload3 = ByteBuffer(string: "Hello World! 3")
        continuation.yield(payload3)
        #expect(await receivedWritesIterator.next() == payload3)
        let payload4 = ByteBuffer(string: "Hello World! 4")
        continuation.yield(payload4)
        #expect(await receivedWritesIterator.next() == payload4)
        continuation.finish()
        #expect(await receivedWritesIterator.next() == nil)
    }
}

final class HTTPRequestStreamingChannel: ChannelInboundHandler & AHCTestSendableMetatype {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    let bodyStreamContinuation: AsyncStream<ByteBuffer>.Continuation

    init(bodyStreamContinuation: AsyncStream<ByteBuffer>.Continuation) {
        self.bodyStreamContinuation = bodyStreamContinuation
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let reqPart = self.unwrapInboundIn(data)
        switch reqPart {
        case .head:
            let responseHead = HTTPResponseHead(version: .http1_1, status: .ok)
            context.write(self.wrapOutboundOut(.head(responseHead)), promise: nil)
            context.write(self.wrapOutboundOut(.end(nil)), promise: nil)
            context.flush()
        case .body(let body):
            self.bodyStreamContinuation.yield(body)
        case .end:
            self.bodyStreamContinuation.finish()
        @unknown default:
            Issue.record("Unhandled case: \(reqPart)")
        }
    }
}
