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

@Suite struct RejectedUploadHandlerTesting {
    @Test func asyncShortBodyAfterRejectionReturnsResponse() async throws {
        let connection = try await TestConnection()
        let (parts, partsContinuation) = AsyncStream.makeStream(of: ByteBuffer.self)
        defer { partsContinuation.finish() }

        try await connection.withTransaction(
            body: .stream(parts, length: .known(8)),
            requestOptions: .forTests(idleWriteTimeout: .milliseconds(100))
        ) { _, response in
            partsContinuation.yield(.firstPart)
            #expect(try await connection.nextOutbound() == .body(.byteBuffer(.firstPart)))
            try await connection.channel.writeInbound(HTTPClientResponsePart.head(.payloadTooLarge))
            let rejection = try await response()

            partsContinuation.finish()
            await connection.loop.advanceTime(by: .milliseconds(250))
            _ = try? await connection.channel.writeInbound(HTTPClientResponsePart.body(.tooLarge))
            _ = try? await connection.channel.writeInbound(HTTPClientResponsePart.end(nil))

            let responseBody = try await withDeadline { try await rejection.body.collect(upTo: 1024) }
            #expect(responseBody == .tooLarge)
        }
    }
}

private struct TestConnection {
    let loop: NIOAsyncTestingEventLoop
    let channel: NIOAsyncTestingChannel

    init() async throws {
        let loop = NIOAsyncTestingEventLoop()
        self.loop = loop
        self.channel = try await NIOAsyncTestingChannel(loop: loop) { channel in
            let handler = HTTP1ClientChannelHandler(
                eventLoop: channel.eventLoop,
                backgroundLogger: Logger(label: "no-op", factory: SwiftLogNoOpLogHandler.init),
                connectionIdLoggerMetadata: "test connection"
            )
            try channel.pipeline.syncOperations.addHandler(handler)
        }
        try await self.channel.connect(to: .init(ipAddress: "127.0.0.1", port: 80)).get()
    }

    func start(_ request: some HTTPExecutableRequest) async throws {
        try await self.loop.executeInContext {
            self.channel.writeAndFlush(request, promise: nil)
        }
        guard case .head = try await self.nextOutbound() else {
            Issue.record("expected the request head first")
            return
        }
    }

    func nextOutbound() async throws -> HTTPClientRequestPart {
        try await self.channel.waitForOutboundWrite(as: HTTPClientRequestPart.self)
    }

    func withTransaction(
        body requestBody: HTTPClientRequest.Body,
        requestOptions: RequestOptions = .forTests(),
        _ body: (Transaction, _ response: @escaping @Sendable () async throws -> HTTPClientResponse) async throws
            -> Void
    ) async throws {
        var request = HTTPClientRequest(url: "http://localhost/upload")
        request.method = .POST
        request.body = requestBody
        let prepared = try HTTPClientRequest.Prepared(request)
        let (transactions, transactionsContinuation) = AsyncStream.makeStream(of: Transaction.self)
        let (responses, responsesContinuation) = AsyncThrowingStream.makeStream(of: HTTPClientResponse.self)
        let loop = self.loop

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                do {
                    let response = try await withCheckedThrowingContinuation {
                        (continuation: CheckedContinuation<HTTPClientResponse, any Error>) in
                        transactionsContinuation.yield(
                            Transaction(
                                request: prepared,
                                requestOptions: requestOptions,
                                logger: Logger(label: "test"),
                                connectionDeadline: .distantFuture,
                                preferredEventLoop: loop,
                                responseContinuation: continuation
                            )
                        )
                        transactionsContinuation.finish()
                    }
                    responsesContinuation.yield(response)
                    responsesContinuation.finish()
                } catch {
                    responsesContinuation.finish(throwing: error)
                }
            }
            guard let transaction = await transactions.first(where: { _ in true }) else {
                Issue.record("expected a transaction")
                return
            }
            defer { transaction.cancel() }

            try await self.start(transaction)
            try await body(transaction) {
                guard let response = try await responses.first(where: { _ in true }) else {
                    throw MissingResponse()
                }
                return response
            }
        }
    }
}

private struct MissingResponse: Error {}

private struct DeadlineExceeded: Error {}

private func withDeadline<Result: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Result
) async throws -> Result {
    try await withThrowingTaskGroup(of: Result.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(5))
            throw DeadlineExceeded()
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

extension ByteBuffer {
    fileprivate static let firstPart = ByteBuffer(bytes: [0, 1, 2, 3])
    fileprivate static let tooLarge = ByteBuffer(string: "too large")
}

extension HTTPResponseHead {
    fileprivate static let payloadTooLarge = HTTPResponseHead(version: .http1_1, status: .payloadTooLarge)
}
