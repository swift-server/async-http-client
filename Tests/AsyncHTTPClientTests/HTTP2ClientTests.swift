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

import AsyncHTTPClient  // NOT @testable - tests that really need @testable go into HTTP2ClientInternalTests.swift
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOFoundationCompat
import NIOHTTP1
import NIOHTTP2
import NIOPosix
import NIOSSL
import XCTest

#if canImport(Network)
import Network
#endif

class HTTP2ClientTests: XCTestCase {
    func makeDefaultHTTPClient(
        eventLoopGroupProvider: HTTPClient.EventLoopGroupProvider = .singleton
    ) -> HTTPClient {
        var config = HTTPClient.Configuration()
        config.tlsConfiguration = .clientDefault
        config.tlsConfiguration?.certificateVerification = .none
        config.httpVersion = .automatic
        return HTTPClient(
            eventLoopGroupProvider: eventLoopGroupProvider,
            configuration: config,
            backgroundActivityLogger: Logger(label: "HTTPClient", factory: StreamLogHandler.standardOutput(label:))
        )
    }

    func makeClientWithActiveHTTP2Connection<RequestHandler>(
        to bin: HTTPBin<RequestHandler>,
        eventLoopGroupProvider: HTTPClient.EventLoopGroupProvider = .singleton
    ) -> HTTPClient {
        let client = self.makeDefaultHTTPClient(eventLoopGroupProvider: eventLoopGroupProvider)
        var response: HTTPClient.Response?
        XCTAssertNoThrow(response = try client.get(url: "https://localhost:\(bin.port)/get").wait())
        XCTAssertEqual(.ok, response?.status)
        XCTAssertEqual(response?.version, .http2)
        return client
    }

    func testSimpleGet() {
        let bin = HTTPBin(.http2(compress: false))
        defer { XCTAssertNoThrow(try bin.shutdown()) }
        let client = self.makeDefaultHTTPClient()
        defer { XCTAssertNoThrow(try client.syncShutdown()) }
        var response: HTTPClient.Response?
        XCTAssertNoThrow(response = try client.get(url: "https://localhost:\(bin.port)/get").wait())

        XCTAssertEqual(.ok, response?.status)
        XCTAssertEqual(response?.version, .http2)
    }

    func testStreamRequestBodyWithoutKnowledgeAboutLength() {
        let bin = HTTPBin(.http2(compress: false)) { _ in HTTPEchoHandler() }
        defer { XCTAssertNoThrow(try bin.shutdown()) }
        let client = self.makeDefaultHTTPClient()
        defer { XCTAssertNoThrow(try client.syncShutdown()) }
        var response: HTTPClient.Response?
        let body = HTTPClient.Body.stream(contentLength: nil) { writer in
            writer.write(.byteBuffer(ByteBuffer(integer: UInt64(0)))).flatMap {
                writer.write(.byteBuffer(ByteBuffer(integer: UInt64(0))))
            }
        }
        XCTAssertNoThrow(response = try client.post(url: "https://localhost:\(bin.port)", body: body).wait())

        XCTAssertEqual(.ok, response?.status)
        XCTAssertEqual(response?.version, .http2)
    }

    func testStreamRequestBodyWithFalseKnowledgeAboutLength() {
        let bin = HTTPBin(.http2(compress: false)) { _ in HTTPEchoHandler() }
        defer { XCTAssertNoThrow(try bin.shutdown()) }
        let client = self.makeDefaultHTTPClient()
        defer { XCTAssertNoThrow(try client.syncShutdown()) }
        let body = HTTPClient.Body.stream(contentLength: 12) { writer in
            writer.write(.byteBuffer(ByteBuffer(integer: UInt64(0)))).flatMap {
                writer.write(.byteBuffer(ByteBuffer(integer: UInt64(0))))
            }
        }
        XCTAssertThrowsError(try client.post(url: "https://localhost:\(bin.port)", body: body).wait()) {
            XCTAssertEqual($0 as? HTTPClientError, .bodyLengthMismatch)
        }
    }

    func testConcurrentRequests() {
        let bin = HTTPBin(.http2(compress: false))
        defer { XCTAssertNoThrow(try bin.shutdown()) }
        let client = self.makeDefaultHTTPClient()
        defer { XCTAssertNoThrow(try client.syncShutdown()) }
        let el = client.eventLoopGroup.next()
        let requestPromises = (0..<1000).map { _ in
            client.get(url: "https://localhost:\(bin.port)/get")
                .map { result -> Void in
                    XCTAssertEqual(result.version, .http2)
                }
        }
        XCTAssertNoThrow(try EventLoopFuture.whenAllComplete(requestPromises, on: el).wait())
    }

    func testConcurrentRequestsFromDifferentThreads() {
        let bin = HTTPBin(.http2(compress: false))
        defer { XCTAssertNoThrow(try bin.shutdown()) }
        let client = self.makeDefaultHTTPClient()
        defer { XCTAssertNoThrow(try client.syncShutdown()) }
        let numberOfWorkers = 20
        let numberOfRequestsPerWorkers = 20
        let allWorkersReady = DispatchSemaphore(value: 0)
        let allWorkersGo = DispatchSemaphore(value: 0)
        let allDone = DispatchGroup()

        let url = "https://localhost:\(bin.port)/get"

        var response: HTTPClient.Response?
        XCTAssertNoThrow(response = try client.get(url: url).wait())

        XCTAssertEqual(.ok, response?.status)
        XCTAssertEqual(response?.version, .http2)

        for w in 0..<numberOfWorkers {
            let q = DispatchQueue(label: "worker \(w)")
            q.async(group: allDone) {
                func go() {
                    allWorkersReady.signal()  // tell the driver we're ready
                    allWorkersGo.wait()  // wait for the driver to let us go

                    for _ in 0..<numberOfRequestsPerWorkers {
                        var response: HTTPClient.Response?
                        XCTAssertNoThrow(response = try client.get(url: "https://localhost:\(bin.port)/get").wait())

                        XCTAssertEqual(.ok, response?.status)
                        XCTAssertEqual(response?.version, .http2)
                    }
                }
                go()
            }
        }

        for _ in 0..<numberOfWorkers {
            allWorkersReady.wait()
        }
        // now all workers should be waiting for the go signal

        for _ in 0..<numberOfWorkers {
            allWorkersGo.signal()
        }
        // all workers should be running, let's wait for them to finish
        allDone.wait()
    }

    func testConcurrentRequestsWorkWithRequiredEventLoop() {
        let numberOfWorkers = 20
        let numberOfRequestsPerWorkers = 20
        let allWorkersReady = DispatchSemaphore(value: 0)
        let allWorkersGo = DispatchSemaphore(value: 0)
        let allDone = DispatchGroup()

        let localHTTPBin = HTTPBin(.http2(compress: false))
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: numberOfWorkers)
        var config = HTTPClient.Configuration()
        config.tlsConfiguration = .clientDefault
        config.tlsConfiguration?.certificateVerification = .none
        config.httpVersion = .automatic
        let localClient = HTTPClient(
            eventLoopGroupProvider: .shared(elg),
            configuration: config,
            backgroundActivityLogger: Logger(label: "HTTPClient", factory: StreamLogHandler.standardOutput(label:))
        )
        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            XCTAssertNoThrow(try localHTTPBin.shutdown())
        }

        let url = "https://localhost:\(localHTTPBin.port)/get"

        var response: HTTPClient.Response?
        XCTAssertNoThrow(response = try localClient.get(url: url).wait())

        XCTAssertEqual(.ok, response?.status)
        XCTAssertEqual(response?.version, .http2)

        for w in 0..<numberOfWorkers {
            let q = DispatchQueue(label: "worker \(w)")
            let el = elg.next()
            q.async(group: allDone) {
                func go() {
                    allWorkersReady.signal()  // tell the driver we're ready
                    allWorkersGo.wait()  // wait for the driver to let us go

                    for _ in 0..<numberOfRequestsPerWorkers {
                        var response: HTTPClient.Response?
                        let request = try! HTTPClient.Request(url: url)
                        let requestPromise =
                            localClient
                            .execute(
                                request: request,
                                eventLoop: .delegateAndChannel(on: el)
                            )
                            .map { response -> HTTPClient.Response in
                                XCTAssertTrue(el.inEventLoop)
                                return response
                            }
                        XCTAssertNoThrow(response = try requestPromise.wait())

                        XCTAssertEqual(.ok, response?.status)
                        XCTAssertEqual(response?.version, .http2)
                    }
                }
                go()
            }
        }

        for _ in 0..<numberOfWorkers {
            allWorkersReady.wait()
        }
        // now all workers should be waiting for the go signal

        for _ in 0..<numberOfWorkers {
            allWorkersGo.signal()
        }
        // all workers should be running, let's wait for them to finish
        allDone.wait()
    }

    func testUncleanShutdownCancelsExecutingAndQueuedTasks() {
        let bin = HTTPBin(.http2(compress: false))
        defer { XCTAssertNoThrow(try bin.shutdown()) }
        let clientGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try clientGroup.syncShutdownGracefully()) }
        // we need an active connection to guarantee that requests are executed immediately
        // without waiting for connection establishment
        let client = self.makeClientWithActiveHTTP2Connection(to: bin, eventLoopGroupProvider: .shared(clientGroup))

        // start 20 requests which are guaranteed to never get any response
        // 10 of them will executed and the other 10 will be queued
        // because HTTPBin has a default `maxConcurrentStreams` limit of 10
        let responses = (0..<20).map { _ in
            client.get(url: "https://localhost:\(bin.port)/wait")
        }

        XCTAssertNoThrow(try client.syncShutdown())

        var results: [Result<HTTPClient.Response, Error>] = []
        XCTAssertNoThrow(
            results =
                try EventLoopFuture
                .whenAllComplete(responses, on: clientGroup.next())
                .timeout(after: .seconds(2))
                .wait()
        )

        for result in results {
            switch result {
            case .success:
                XCTFail("Shouldn't succeed")
            case .failure(let error):
                XCTAssertEqual(error as? HTTPClientError, .cancelled)
            }
        }
    }

    func testCancelingRunningRequest() {
        let bin = HTTPBin(.http2(compress: false)) { _ in SendHeaderAndWaitChannelHandler() }
        defer { XCTAssertNoThrow(try bin.shutdown()) }
        let client = self.makeDefaultHTTPClient()
        defer { XCTAssertNoThrow(try client.syncShutdown()) }

        var maybeRequest: HTTPClient.Request?
        XCTAssertNoThrow(maybeRequest = try HTTPClient.Request(url: "https://localhost:\(bin.port)"))
        guard let request = maybeRequest else { return }

        let taskBox = NIOLockedValueBox<HTTPClient.Task<Void>?>(nil)
        let delegate = HeadReceivedCallback { _ in
            // request is definitely running because we just received a head from the server
            taskBox.withLockedValue { $0 }!.cancel()
        }
        let task = client.execute(
            request: request,
            delegate: delegate
        )
        taskBox.withLockedValue { $0 = task }

        XCTAssertThrowsError(try task.futureResult.timeout(after: .seconds(2)).wait()) {
            XCTAssertEqualTypeAndValue($0, HTTPClientError.cancelled)
        }
    }

    func testReadTimeout() {
        let bin = HTTPBin(.http2(compress: false)) { _ in SendHeaderAndWaitChannelHandler() }
        defer { XCTAssertNoThrow(try bin.shutdown()) }
        var config = HTTPClient.Configuration()
        var tlsConfig = TLSConfiguration.makeClientConfiguration()
        tlsConfig.certificateVerification = .none
        config.tlsConfiguration = tlsConfig
        config.httpVersion = .automatic
        config.timeout.read = .milliseconds(100)
        let client = HTTPClient(
            eventLoopGroupProvider: .singleton,
            configuration: config,
            backgroundActivityLogger: Logger(label: "HTTPClient", factory: StreamLogHandler.standardOutput(label:))
        )
        defer { XCTAssertNoThrow(try client.syncShutdown()) }

        let response = client.get(url: "https://localhost:\(bin.port)")
        XCTAssertThrowsError(try response.timeout(after: .seconds(2)).wait()) { error in
            XCTAssertEqual(error as? HTTPClientError, .readTimeout)
        }
    }

    func testH2CanHandleRequestsThatHaveAlreadyHitTheDeadline() {
        let bin = HTTPBin(.http2(compress: false))
        defer { XCTAssertNoThrow(try bin.shutdown()) }
        var config = HTTPClient.Configuration()
        var tlsConfig = TLSConfiguration.makeClientConfiguration()
        tlsConfig.certificateVerification = .none
        config.tlsConfiguration = tlsConfig
        config.httpVersion = .automatic
        let client = HTTPClient(
            // TODO: Test fails if the provided ELG is a multi-threaded NIOTSEventLoopGroup (probably racy)
            eventLoopGroupProvider: .shared(bin.group),
            configuration: config,
            backgroundActivityLogger: Logger(label: "HTTPClient", factory: StreamLogHandler.standardOutput(label:))
        )
        defer { XCTAssertNoThrow(try client.syncShutdown()) }

        var request: HTTPClient.Request?
        XCTAssertNoThrow(request = try HTTPClient.Request(url: "https://localhost:\(bin.port)"))

        // just to establish an existing connection
        XCTAssertNoThrow(try client.execute(request: XCTUnwrap(request)).wait())

        XCTAssertThrowsError(try client.execute(request: XCTUnwrap(request), deadline: .now() - .seconds(2)).wait()) {
            XCTAssertEqual($0 as? HTTPClientError, .deadlineExceeded)
        }
    }

    func testStressCancelingRunningRequestFromDifferentThreads() {
        let bin = HTTPBin(.http2(compress: false)) { _ in SendHeaderAndWaitChannelHandler() }
        defer { XCTAssertNoThrow(try bin.shutdown()) }
        let client = self.makeDefaultHTTPClient()
        defer { XCTAssertNoThrow(try client.syncShutdown()) }
        let cancelPool = MultiThreadedEventLoopGroup(numberOfThreads: 10)
        defer { XCTAssertNoThrow(try cancelPool.syncShutdownGracefully()) }

        var maybeRequest: HTTPClient.Request?
        XCTAssertNoThrow(maybeRequest = try HTTPClient.Request(url: "https://localhost:\(bin.port)"))
        guard let request = maybeRequest else { return }

        let tasks = (0..<100).map { _ -> HTTPClient.Task<TestHTTPDelegate.Response> in
            let taskBox = NIOLockedValueBox<HTTPClient.Task<Void>?>(nil)

            let delegate = HeadReceivedCallback { _ in
                // request is definitely running because we just received a head from the server
                cancelPool.next().execute {
                    // canceling from a different thread
                    taskBox.withLockedValue { $0 }!.cancel()
                }
            }
            let task = client.execute(
                request: request,
                delegate: delegate
            )
            taskBox.withLockedValue { $0 = task }
            return task
        }

        for task in tasks {
            XCTAssertThrowsError(try task.futureResult.timeout(after: .seconds(2)).wait()) {
                XCTAssertEqual($0 as? HTTPClientError, .cancelled)
            }
        }
    }

    func testPlatformConnectErrorIsForwardedOnTimeout() {
        let bin = HTTPBin(.http2(compress: false), reusePort: true)
        let clientGroup = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let el1 = clientGroup.next()
        let el2 = clientGroup.next()
        defer { XCTAssertNoThrow(try clientGroup.syncShutdownGracefully()) }
        var config = HTTPClient.Configuration()
        config.tlsConfiguration = .clientDefault
        config.tlsConfiguration?.certificateVerification = .none
        config.httpVersion = .automatic
        config.timeout.connect = .milliseconds(1000)
        let client = HTTPClient(
            eventLoopGroupProvider: .shared(clientGroup),
            configuration: config,
            backgroundActivityLogger: Logger(label: "HTTPClient", factory: StreamLogHandler.standardOutput(label:))
        )
        defer { XCTAssertNoThrow(try client.syncShutdown()) }

        var maybeRequest1: HTTPClient.Request?
        XCTAssertNoThrow(maybeRequest1 = try HTTPClient.Request(url: "https://localhost:\(bin.port)/get"))
        guard let request1 = maybeRequest1 else { return }

        let task1 = client.execute(
            request: request1,
            delegate: ResponseAccumulator(request: request1),
            eventLoop: .delegateAndChannel(on: el1)
        )
        var response1: ResponseAccumulator.Response?
        XCTAssertNoThrow(response1 = try task1.wait())

        XCTAssertEqual(.ok, response1?.status)
        XCTAssertEqual(response1?.version, .http2)
        let serverPort = bin.port

        let serverGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try serverGroup.syncShutdownGracefully()) }
        var maybeServer: Channel?
        XCTAssertNoThrow(
            maybeServer = try ServerBootstrap(group: serverGroup)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEPORT), value: 1)
                .childChannelInitializer { channel in
                    channel.close()
                }
                .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .bind(host: "127.0.0.1", port: serverPort)
                .wait()
        )
        // shutting down the old server closes all connections immediately
        XCTAssertNoThrow(try bin.shutdown())
        // client is now in HTTP/2 state and the HTTPBin is closed
        guard let server = maybeServer else { return }
        defer { XCTAssertNoThrow(try server.close().wait()) }

        var maybeRequest2: HTTPClient.Request?
        XCTAssertNoThrow(maybeRequest2 = try HTTPClient.Request(url: "https://localhost:\(serverPort)/"))
        guard let request2 = maybeRequest2 else { return }

        let task2 = client.execute(
            request: request2,
            delegate: ResponseAccumulator(request: request2),
            eventLoop: .delegateAndChannel(on: el2)
        )
        XCTAssertThrowsError(try task2.wait()) { error in
            XCTAssertNil(
                error as? HTTPClientError,
                "error should be some platform specific error that the connection is closed/reset by the other side"
            )
        }
    }

    func testMassiveDownload() {
        let bin = HTTPBin(.http2(compress: false))
        defer { XCTAssertNoThrow(try bin.shutdown()) }
        let client = self.makeDefaultHTTPClient()
        defer { XCTAssertNoThrow(try client.syncShutdown()) }
        var response: HTTPClient.Response?
        XCTAssertNoThrow(response = try client.get(url: "https://localhost:\(bin.port)/mega-chunked").wait())

        XCTAssertEqual(.ok, response?.status)
        XCTAssertEqual(response?.version, .http2)
        XCTAssertEqual(response?.body?.readableBytes, 10_000)
    }

    func testSimplePost() {
        let bin = HTTPBin(.http2(compress: false))
        defer { XCTAssertNoThrow(try bin.shutdown()) }
        let client = self.makeDefaultHTTPClient()
        defer { XCTAssertNoThrow(try client.syncShutdown()) }
        var response: HTTPClient.Response?
        XCTAssertNoThrow(
            response = try client.post(
                url: "https://localhost:\(bin.port)/post",
                body: .byteBuffer(ByteBuffer(repeating: 0, count: 12345))
            ).wait()
        )
        XCTAssertEqual(.ok, response?.status)
        XCTAssertEqual(response?.version, .http2)
        XCTAssertEqual(
            String(buffer: ByteBuffer(repeating: 0, count: 12345)),
            try response?.body.map { body in
                try JSONDecoder().decode(RequestInfo.self, from: body)
            }?.data
        )
    }

    func testHugePost() {
        // Regression test for https://github.com/swift-server/async-http-client/issues/784
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)  // This needs to be more than 1!
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }
        var serverH2Settings: HTTP2Settings = HTTP2Settings()
        serverH2Settings.append(HTTP2Setting(parameter: .maxFrameSize, value: 16 * 1024 * 1024 - 1))
        serverH2Settings.append(HTTP2Setting(parameter: .initialWindowSize, value: Int(Int32.max)))
        let bin = HTTPBin(
            .http2(compress: false, settings: serverH2Settings)
        )
        defer { XCTAssertNoThrow(try bin.shutdown()) }
        var clientConfig = HTTPClient.Configuration()
        clientConfig.tlsConfiguration = .clientDefault
        clientConfig.tlsConfiguration?.certificateVerification = .none
        clientConfig.httpVersion = .automatic
        let client = HTTPClient(
            eventLoopGroupProvider: .shared(group),
            configuration: clientConfig,
            backgroundActivityLogger: Logger(label: "HTTPClient", factory: StreamLogHandler.standardOutput(label:))
        )
        defer { XCTAssertNoThrow(try client.syncShutdown()) }

        let loop1 = group.next()
        let loop2 = group.next()
        precondition(loop1 !== loop2, "bug in test setup, need two distinct loops")

        XCTAssertNoThrow(
            try client.execute(
                request: .init(url: "https://localhost:\(bin.port)/get"),
                eventLoop: .delegateAndChannel(on: loop1)  // This will force the channel to live on `loop1`.
            ).wait()
        )
        var response: HTTPClient.Response?
        let byteCount = 1024 * 1024 * 1024  // 1 GiB (unfortunately it has to be that big to trigger the bug)
        XCTAssertNoThrow(
            response = try client.execute(
                request: HTTPClient.Request(
                    url: "https://localhost:\(bin.port)/post-respond-with-byte-count",
                    method: .POST,
                    body: .data(Data(repeating: 0, count: byteCount))
                ),
                eventLoop: .delegate(on: loop2)
            ).wait()
        )
        XCTAssertEqual(.ok, response?.status)
        XCTAssertEqual(response?.version, .http2)
        XCTAssertEqual(
            "\(byteCount)",
            try response?.body.map { body in
                try JSONDecoder().decode(RequestInfo.self, from: body)
            }?.data
        )
    }
}

private final class HeadReceivedCallback: HTTPClientResponseDelegate {
    typealias Response = Void
    private let didReceiveHeadCallback: @Sendable (HTTPResponseHead) -> Void
    init(didReceiveHead: @escaping @Sendable (HTTPResponseHead) -> Void) {
        self.didReceiveHeadCallback = didReceiveHead
    }

    func didReceiveHead(task: HTTPClient.Task<Void>, _ head: HTTPResponseHead) -> EventLoopFuture<Void> {
        self.didReceiveHeadCallback(head)
        return task.eventLoop.makeSucceededVoidFuture()
    }

    func didFinishRequest(task: HTTPClient.Task<Void>) throws {}
}

/// sends some headers and waits indefinitely afterwards
private final class SendHeaderAndWaitChannelHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let requestPart = self.unwrapInboundIn(data)
        switch requestPart {
        case .head:
            context.writeAndFlush(
                self.wrapOutboundOut(
                    .head(
                        HTTPResponseHead(
                            version: HTTPVersion(major: 1, minor: 1),
                            status: .ok
                        )
                    )
                ),
                promise: nil
            )
        case .body, .end:
            return
        }
    }
}
