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

import AsyncHTTPClient
import NIOCore
import NIOHTTP1
import NIOSSL
import Testing

@Suite(.timeLimit(.minutes(1))) struct AsyncAwaitCancellationTests {
    @Test func cancelBeforeExecuteThrowsCancellationErrorWithoutConnecting() async throws {
        let httpBin = HTTPBin(.http2(compress: false))
        defer { #expect(throws: Never.self) { try httpBin.shutdown() } }
        let httpClient = HTTPClient.makeTestClient()
        let request = HTTPClientRequest(url: "https://localhost:\(httpBin.port)/get")

        await #expect(throws: CancellationError.self) {
            try await withThrowingTaskGroup(of: HTTPClientResponse.self) { group in
                group.cancelAll()
                group.addTask { try await httpClient.execute(request, timeout: .seconds(10)) }
                _ = try await group.next()
            }
        }
        try await httpClient.shutdown()

        #expect(httpBin.createdConnections == 0)
    }

    @Test func cancelWhileInFlightThrowsCancellationError() async throws {
        let (requestURIs, requestURIsContinuation) = AsyncStream.makeStream(of: String.self)
        let httpBin = HTTPBin(.http2(compress: false)) { _ in
            RespondUnlessWaitHandler(requestURIs: requestURIsContinuation)
        }
        defer { #expect(throws: Never.self) { try httpBin.shutdown() } }
        let httpClient = HTTPClient.makeTestClient()
        var requestURIsIterator = requestURIs.makeAsyncIterator()

        await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                defer { requestURIsContinuation.finish() }
                _ = try await httpClient.execute(
                    HTTPClientRequest(url: "https://localhost:\(httpBin.port)/wait"),
                    timeout: .seconds(10)
                )
            }
            #expect(await requestURIsIterator.next() == "/wait")

            group.cancelAll()

            await #expect(throws: CancellationError.self) { try await group.next() }
        }
        await #expect(throws: Never.self) {
            let response = try await httpClient.execute(
                HTTPClientRequest(url: "https://localhost:\(httpBin.port)/ok"),
                timeout: .seconds(10)
            )
            #expect(response.status == .ok)
        }
        try await httpClient.shutdown()
    }
}

final class RespondUnlessWaitHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let requestURIs: AsyncStream<String>.Continuation
    private var uri: String?

    init(requestURIs: AsyncStream<String>.Continuation) {
        self.requestURIs = requestURIs
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch self.unwrapInboundIn(data) {
        case .head(let head):
            self.uri = head.uri
            self.requestURIs.yield(head.uri)
        case .body:
            break
        case .end:
            guard self.uri != "/wait" else {
                return
            }
            context.write(self.wrapOutboundOut(.head(.init(version: .http1_1, status: .ok))), promise: nil)
            context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
        }
    }
}

extension HTTPClient {
    fileprivate static func makeTestClient() -> HTTPClient {
        var configuration = HTTPClient.Configuration()
        configuration.tlsConfiguration = .clientDefault
        configuration.tlsConfiguration?.certificateVerification = .none
        configuration.timeout.read = .seconds(5)
        return HTTPClient(eventLoopGroupProvider: .singleton, configuration: configuration)
    }
}
