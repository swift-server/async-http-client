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
import NIOPosix
import NIOTestUtils
import Testing

@Suite struct RejectedUploadTesting {
    /// A server may reject an upload with a status >= 300 while the caller is still producing the
    /// body. The client then drops the body parts the caller still hands it. When the caller finishes
    /// the body afterwards, it must still get the server's whole response.
    @Test func contentLengthUploadRejectedMidStreamReturnsResponse() throws {
        try withRejectedUpload(contentLength: 4) { task, server in
            var response: HTTPClient.Response?
            #expect(throws: Never.self) { response = try task.wait() }
            #expect(throws: HTTPParserError.invalidEOFState) { try server.readInbound() }
            guard let response else { return }
            #expect(response.status == .payloadTooLarge)
            #expect(response.body == ByteBuffer(string: "too large"))
        }
    }

    /// A caller that writes fewer bytes than it declared made a mistake, even if the server has
    /// already rejected the upload. The client dropped none of the caller's parts, so it reports the
    /// mismatch instead of the response.
    @Test func tooShortBodyAfterRejectionFailsRequest() throws {
        try withClientAndServer { client, server, clientLoop in
            let finishBody = clientLoop.makePromise(of: Void.self)
            let request = try HTTPClient.Request(
                url: "http://localhost:\(server.serverPort)/upload",
                method: .POST,
                body: .stream(contentLength: 4) { writer in
                    writer.write(.byteBuffer(ByteBuffer(bytes: [0, 1]))).flatMap { finishBody.futureResult }
                }
            )
            let headReceived = clientLoop.makePromise(of: Void.self)
            let task = client.execute(
                request: request,
                delegate: HeadSignallingDelegate(request: request, headReceived: headReceived)
            )

            _ = try server.receiveHead()
            #expect(try server.receiveBody() == ByteBuffer(bytes: [0, 1]))
            try server.writeOutbound(.head(.payloadTooLarge))
            try headReceived.futureResult.wait()

            try clientLoop.submit { finishBody.succeed() }.wait()

            #expect(throws: HTTPClientError.bodyLengthMismatch) { try task.wait() }
            #expect(throws: HTTPParserError.invalidEOFState) { try server.readInbound() }
        }
    }
}

private func withClientAndServer(
    _ body: (HTTPClient, NIOHTTP1TestServer, any EventLoop) throws -> Void
) throws {
    let clientGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let serverGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let server = NIOHTTP1TestServer(group: serverGroup, aggregateBody: false)
    let client = HTTPClient(eventLoopGroupProvider: .shared(clientGroup))
    defer {
        #expect(throws: Never.self) { try client.syncShutdown() }
        #expect(throws: Never.self) { try server.stop() }
        #expect(throws: Never.self) { try serverGroup.syncShutdownGracefully() }
        #expect(throws: Never.self) { try clientGroup.syncShutdownGracefully() }
    }
    try body(client, server, clientGroup.next())
}

private func withRejectedUpload(
    contentLength: Int64?,
    _ body: (HTTPClient.Task<HTTPClient.Response>, NIOHTTP1TestServer) throws -> Void
) throws {
    try withClientAndServer { client, server, clientLoop in
        let sendBody = clientLoop.makePromise(of: Void.self)
        let request = try HTTPClient.Request(
            url: "http://localhost:\(server.serverPort)/upload",
            method: .POST,
            body: .stream(contentLength: contentLength) { writer in
                sendBody.futureResult.map {
                    _ = writer.write(.byteBuffer(ByteBuffer(bytes: [0, 1, 2, 3])))
                }
            }
        )
        let headReceived = clientLoop.makePromise(of: Void.self)
        let task = client.execute(
            request: request,
            delegate: HeadSignallingDelegate(request: request, headReceived: headReceived)
        )
        _ = try server.receiveHead()
        try server.writeOutbound(.head(.payloadTooLarge))
        try server.writeOutbound(.body(.byteBuffer(ByteBuffer(string: "too large"))))
        try headReceived.futureResult.wait()
        try clientLoop.submit { sendBody.succeed() }.wait()
        try? server.writeOutbound(.end(nil))
        try body(task, server)
    }
}

private final class HeadSignallingDelegate: HTTPClientResponseDelegate {
    typealias Response = HTTPClient.Response

    private let accumulator: ResponseAccumulator
    private let headReceived: EventLoopPromise<Void>

    init(request: HTTPClient.Request, headReceived: EventLoopPromise<Void>) {
        self.accumulator = ResponseAccumulator(request: request)
        self.headReceived = headReceived
    }

    func didReceiveHead(task: HTTPClient.Task<Response>, _ head: HTTPResponseHead) -> EventLoopFuture<Void> {
        defer { self.headReceived.succeed() }
        return self.accumulator.didReceiveHead(task: task, head)
    }

    func didReceiveBodyPart(task: HTTPClient.Task<Response>, _ buffer: ByteBuffer) -> EventLoopFuture<Void> {
        self.accumulator.didReceiveBodyPart(task: task, buffer)
    }

    func didReceiveError(task: HTTPClient.Task<Response>, _ error: any Error) {
        self.headReceived.fail(error)
        self.accumulator.didReceiveError(task: task, error)
    }

    func didFinishRequest(task: HTTPClient.Task<Response>) throws -> Response {
        try self.accumulator.didFinishRequest(task: task)
    }
}

extension HTTPResponseHead {
    fileprivate static let payloadTooLarge = HTTPResponseHead(version: .http1_1, status: .payloadTooLarge)
}
