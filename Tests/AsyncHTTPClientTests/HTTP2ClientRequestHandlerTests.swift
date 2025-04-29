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
import NIOEmbedded
import NIOHTTP1
import XCTest

@testable import AsyncHTTPClient

class HTTP2ClientRequestHandlerTests: XCTestCase {
    func testResponseBackpressure() {
        let embedded = EmbeddedChannel()
        let readEventHandler = ReadEventHitHandler()
        let requestHandler = HTTP2ClientRequestHandler(eventLoop: embedded.eventLoop)
        let logger = Logger(label: "test")

        XCTAssertNoThrow(try embedded.pipeline.syncOperations.addHandlers([readEventHandler, requestHandler]))

        var maybeRequest: HTTPClient.Request?
        XCTAssertNoThrow(maybeRequest = try HTTPClient.Request(url: "http://localhost/"))
        guard let request = maybeRequest else { return XCTFail("Expected to be able to create a request") }

        let delegate = ResponseBackpressureDelegate(eventLoop: embedded.eventLoop)
        var maybeRequestBag: RequestBag<ResponseBackpressureDelegate>?
        XCTAssertNoThrow(
            maybeRequestBag = try RequestBag(
                request: request,
                eventLoopPreference: .delegate(on: embedded.eventLoop),
                task: .init(eventLoop: embedded.eventLoop, logger: logger),
                redirectHandler: nil,
                connectionDeadline: .now() + .seconds(30),
                requestOptions: .forTests(),
                delegate: delegate
            )
        )
        guard let requestBag = maybeRequestBag else { return XCTFail("Expected to be able to create a request bag") }

        embedded.write(requestBag, promise: nil)
        XCTAssertNoThrow(try embedded.connect(to: .makeAddressResolvingHost("localhost", port: 0)).wait())

        XCTAssertNoThrow(
            try embedded.receiveHeadAndVerify {
                XCTAssertEqual($0.method, .GET)
                XCTAssertEqual($0.uri, "/")
                XCTAssertEqual($0.headers.first(name: "host"), "localhost")
            }
        )
        XCTAssertEqual(try embedded.readOutbound(as: HTTPClientRequestPart.self), .end(nil))

        let responseHead = HTTPResponseHead(
            version: .http1_1,
            status: .ok,
            headers: HTTPHeaders([("content-length", "12")])
        )

        XCTAssertEqual(readEventHandler.readHitCounter, 0)
        embedded.read()
        XCTAssertEqual(readEventHandler.readHitCounter, 1)
        XCTAssertNoThrow(try embedded.writeInbound(HTTPClientResponsePart.head(responseHead)))

        let part0 = ByteBuffer(bytes: 0...3)
        let part1 = ByteBuffer(bytes: 4...7)
        let part2 = ByteBuffer(bytes: 8...11)

        // part 0. Demand first, read second
        XCTAssertEqual(readEventHandler.readHitCounter, 1)
        let part0Future = delegate.next()
        XCTAssertEqual(readEventHandler.readHitCounter, 1)
        embedded.read()
        XCTAssertEqual(readEventHandler.readHitCounter, 2)
        XCTAssertNoThrow(try embedded.writeInbound(HTTPClientResponsePart.body(part0)))
        XCTAssertEqual(try part0Future.wait(), part0)

        // part 1. read first, demand second

        XCTAssertEqual(readEventHandler.readHitCounter, 2)
        embedded.read()
        XCTAssertEqual(readEventHandler.readHitCounter, 2)
        let part1Future = delegate.next()
        XCTAssertEqual(readEventHandler.readHitCounter, 3)
        XCTAssertNoThrow(try embedded.writeInbound(HTTPClientResponsePart.body(part1)))
        XCTAssertEqual(try part1Future.wait(), part1)

        // part 2. Demand first, read second
        XCTAssertEqual(readEventHandler.readHitCounter, 3)
        let part2Future = delegate.next()
        XCTAssertEqual(readEventHandler.readHitCounter, 3)
        embedded.read()
        XCTAssertEqual(readEventHandler.readHitCounter, 4)
        XCTAssertNoThrow(try embedded.writeInbound(HTTPClientResponsePart.body(part2)))
        XCTAssertEqual(try part2Future.wait(), part2)

        // end. read first, demand second
        XCTAssertEqual(readEventHandler.readHitCounter, 4)
        embedded.read()
        XCTAssertEqual(readEventHandler.readHitCounter, 4)
        let endFuture = delegate.next()
        XCTAssertEqual(readEventHandler.readHitCounter, 5)
        XCTAssertNoThrow(try embedded.writeInbound(HTTPClientResponsePart.end(nil)))
        XCTAssertEqual(try endFuture.wait(), .none)

        XCTAssertNoThrow(try requestBag.task.futureResult.wait())
    }

    func testWriteBackpressure() {
        let embedded = EmbeddedChannel()
        let requestHandler = HTTP2ClientRequestHandler(eventLoop: embedded.eventLoop)
        XCTAssertNoThrow(try embedded.pipeline.syncOperations.addHandler(requestHandler))
        let logger = Logger(label: "test")

        let testWriter = TestBackpressureWriter(eventLoop: embedded.eventLoop, parts: 50)

        var maybeRequest: HTTPClient.Request?
        XCTAssertNoThrow(
            maybeRequest = try HTTPClient.Request(
                url: "http://localhost/",
                method: .POST,
                body: .stream(contentLength: 100) { writer in
                    testWriter.start(writer: writer)
                }
            )
        )
        guard let request = maybeRequest else { return XCTFail("Expected to be able to create a request") }

        let delegate = ResponseAccumulator(request: request)
        var maybeRequestBag: RequestBag<ResponseAccumulator>?
        XCTAssertNoThrow(
            maybeRequestBag = try RequestBag(
                request: request,
                eventLoopPreference: .delegate(on: embedded.eventLoop),
                task: .init(eventLoop: embedded.eventLoop, logger: logger),
                redirectHandler: nil,
                connectionDeadline: .now() + .seconds(30),
                requestOptions: .forTests(idleReadTimeout: .milliseconds(200)),
                delegate: delegate
            )
        )
        guard let requestBag = maybeRequestBag else { return XCTFail("Expected to be able to create a request bag") }

        embedded.isWritable = false
        XCTAssertNoThrow(try embedded.connect(to: .makeAddressResolvingHost("localhost", port: 0)).wait())
        embedded.write(requestBag, promise: nil)

        // the handler only writes once the channel is writable
        XCTAssertEqual(try embedded.readOutbound(as: HTTPClientRequestPart.self), .none)
        embedded.isWritable = true
        testWriter.writabilityChanged(true)
        embedded.pipeline.fireChannelWritabilityChanged()

        XCTAssertNoThrow(
            try embedded.receiveHeadAndVerify {
                XCTAssertEqual($0.method, .POST)
                XCTAssertEqual($0.uri, "/")
                XCTAssertEqual($0.headers.first(name: "host"), "localhost")
                XCTAssertEqual($0.headers.first(name: "content-length"), "100")
            }
        )

        // the next body write will be executed once we tick the el. before we make the channel
        // unwritable

        for index in 0..<50 {
            embedded.isWritable = false
            testWriter.writabilityChanged(false)
            embedded.pipeline.fireChannelWritabilityChanged()

            XCTAssertEqual(testWriter.written, index)

            embedded.embeddedEventLoop.run()

            XCTAssertNoThrow(
                try embedded.receiveBodyAndVerify {
                    XCTAssertEqual($0.readableBytes, 2)
                }
            )

            XCTAssertEqual(testWriter.written, index + 1)

            embedded.isWritable = true
            testWriter.writabilityChanged(true)
            embedded.pipeline.fireChannelWritabilityChanged()
        }

        embedded.embeddedEventLoop.run()
        XCTAssertNoThrow(try embedded.receiveEnd())

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok)
        XCTAssertNoThrow(try embedded.writeInbound(HTTPClientResponsePart.head(responseHead)))
        embedded.read()

        XCTAssertNoThrow(try embedded.writeInbound(HTTPClientResponsePart.end(nil)))
        XCTAssertNoThrow(try requestBag.task.futureResult.wait())
    }

    func testIdleReadTimeout() {
        let embedded = EmbeddedChannel()
        let readEventHandler = ReadEventHitHandler()
        let requestHandler = HTTP2ClientRequestHandler(eventLoop: embedded.eventLoop)
        XCTAssertNoThrow(try embedded.pipeline.syncOperations.addHandlers([readEventHandler, requestHandler]))
        XCTAssertNoThrow(try embedded.connect(to: .makeAddressResolvingHost("localhost", port: 0)).wait())
        let logger = Logger(label: "test")

        var maybeRequest: HTTPClient.Request?
        XCTAssertNoThrow(maybeRequest = try HTTPClient.Request(url: "http://localhost/"))
        guard let request = maybeRequest else { return XCTFail("Expected to be able to create a request") }

        let delegate = ResponseBackpressureDelegate(eventLoop: embedded.eventLoop)
        var maybeRequestBag: RequestBag<ResponseBackpressureDelegate>?
        XCTAssertNoThrow(
            maybeRequestBag = try RequestBag(
                request: request,
                eventLoopPreference: .delegate(on: embedded.eventLoop),
                task: .init(eventLoop: embedded.eventLoop, logger: logger),
                redirectHandler: nil,
                connectionDeadline: .now() + .seconds(30),
                requestOptions: .forTests(idleReadTimeout: .milliseconds(200)),
                delegate: delegate
            )
        )
        guard let requestBag = maybeRequestBag else { return XCTFail("Expected to be able to create a request bag") }

        embedded.write(requestBag, promise: nil)

        XCTAssertNoThrow(
            try embedded.receiveHeadAndVerify {
                XCTAssertEqual($0.method, .GET)
                XCTAssertEqual($0.uri, "/")
                XCTAssertEqual($0.headers.first(name: "host"), "localhost")
            }
        )
        XCTAssertNoThrow(try embedded.receiveEnd())

        let responseHead = HTTPResponseHead(
            version: .http1_1,
            status: .ok,
            headers: HTTPHeaders([("content-length", "12")])
        )

        XCTAssertEqual(readEventHandler.readHitCounter, 0)
        embedded.read()
        XCTAssertEqual(readEventHandler.readHitCounter, 1)
        XCTAssertNoThrow(try embedded.writeInbound(HTTPClientResponsePart.head(responseHead)))

        // not sending anything after the head should lead to request fail and connection close

        embedded.embeddedEventLoop.advanceTime(by: .milliseconds(250))

        XCTAssertThrowsError(try requestBag.task.futureResult.wait()) {
            XCTAssertEqual($0 as? HTTPClientError, .readTimeout)
        }
    }

    func testIdleReadTimeoutIsCanceledIfRequestIsCanceled() {
        let embedded = EmbeddedChannel()
        let readEventHandler = ReadEventHitHandler()
        let requestHandler = HTTP2ClientRequestHandler(eventLoop: embedded.eventLoop)
        XCTAssertNoThrow(try embedded.pipeline.syncOperations.addHandlers([readEventHandler, requestHandler]))
        XCTAssertNoThrow(try embedded.connect(to: .makeAddressResolvingHost("localhost", port: 0)).wait())
        let logger = Logger(label: "test")

        var maybeRequest: HTTPClient.Request?
        XCTAssertNoThrow(maybeRequest = try HTTPClient.Request(url: "http://localhost/"))
        guard let request = maybeRequest else { return XCTFail("Expected to be able to create a request") }

        let delegate = ResponseBackpressureDelegate(eventLoop: embedded.eventLoop)
        var maybeRequestBag: RequestBag<ResponseBackpressureDelegate>?
        XCTAssertNoThrow(
            maybeRequestBag = try RequestBag(
                request: request,
                eventLoopPreference: .delegate(on: embedded.eventLoop),
                task: .init(eventLoop: embedded.eventLoop, logger: logger),
                redirectHandler: nil,
                connectionDeadline: .now() + .seconds(30),
                requestOptions: .forTests(idleReadTimeout: .milliseconds(200)),
                delegate: delegate
            )
        )
        guard let requestBag = maybeRequestBag else { return XCTFail("Expected to be able to create a request bag") }

        embedded.write(requestBag, promise: nil)

        XCTAssertNoThrow(
            try embedded.receiveHeadAndVerify {
                XCTAssertEqual($0.method, .GET)
                XCTAssertEqual($0.uri, "/")
                XCTAssertEqual($0.headers.first(name: "host"), "localhost")
            }
        )
        XCTAssertNoThrow(try embedded.receiveEnd())

        let responseHead = HTTPResponseHead(
            version: .http1_1,
            status: .ok,
            headers: HTTPHeaders([("content-length", "12")])
        )

        XCTAssertEqual(readEventHandler.readHitCounter, 0)
        embedded.read()
        XCTAssertEqual(readEventHandler.readHitCounter, 1)
        XCTAssertNoThrow(try embedded.writeInbound(HTTPClientResponsePart.head(responseHead)))

        // canceling the request
        requestBag.fail(HTTPClientError.cancelled)
        XCTAssertThrowsError(try requestBag.task.futureResult.wait()) {
            XCTAssertEqual($0 as? HTTPClientError, .cancelled)
        }

        // the idle read timeout should be cleared because we canceled the request
        // therefore advancing the time should not trigger a crash
        embedded.embeddedEventLoop.advanceTime(by: .milliseconds(250))
    }

    func testIdleWriteTimeout() {
        let embedded = EmbeddedChannel()
        let requestHandler = HTTP2ClientRequestHandler(eventLoop: embedded.eventLoop)
        XCTAssertNoThrow(try embedded.pipeline.syncOperations.addHandlers([requestHandler]))
        XCTAssertNoThrow(try embedded.connect(to: .makeAddressResolvingHost("localhost", port: 0)).wait())
        let logger = Logger(label: "test")

        let testWriter = TestBackpressureWriter(eventLoop: embedded.eventLoop, parts: 5)
        var maybeRequest: HTTPClient.Request?
        XCTAssertNoThrow(
            maybeRequest = try HTTPClient.Request(
                url: "http://localhost/",
                method: .POST,
                body: .stream(contentLength: 10) { writer in
                    // Advance time by more than the idle write timeout (that's 1 millisecond) to trigger the timeout.
                    embedded.embeddedEventLoop.advanceTime(by: .milliseconds(2))
                    return testWriter.start(writer: writer)
                }
            )
        )
        guard let request = maybeRequest else { return XCTFail("Expected to be able to create a request") }

        let delegate = ResponseBackpressureDelegate(eventLoop: embedded.eventLoop)
        var maybeRequestBag: RequestBag<ResponseBackpressureDelegate>?
        XCTAssertNoThrow(
            maybeRequestBag = try RequestBag(
                request: request,
                eventLoopPreference: .delegate(on: embedded.eventLoop),
                task: .init(eventLoop: embedded.eventLoop, logger: logger),
                redirectHandler: nil,
                connectionDeadline: .now() + .seconds(30),
                requestOptions: .forTests(idleWriteTimeout: .milliseconds(1)),
                delegate: delegate
            )
        )
        guard let requestBag = maybeRequestBag else { return XCTFail("Expected to be able to create a request bag") }

        embedded.isWritable = true
        testWriter.writabilityChanged(true)
        embedded.pipeline.fireChannelWritabilityChanged()
        embedded.write(requestBag, promise: nil)

        XCTAssertThrowsError(try requestBag.task.futureResult.wait()) {
            XCTAssertEqual($0 as? HTTPClientError, .writeTimeout)
        }
    }

    func testIdleWriteTimeoutWritabilityChanged() {
        let embedded = EmbeddedChannel()
        let readEventHandler = ReadEventHitHandler()
        let requestHandler = HTTP2ClientRequestHandler(eventLoop: embedded.eventLoop)
        XCTAssertNoThrow(try embedded.pipeline.syncOperations.addHandlers([readEventHandler, requestHandler]))
        XCTAssertNoThrow(try embedded.connect(to: .makeAddressResolvingHost("localhost", port: 0)).wait())
        let logger = Logger(label: "test")

        let testWriter = TestBackpressureWriter(eventLoop: embedded.eventLoop, parts: 5)
        var maybeRequest: HTTPClient.Request?
        XCTAssertNoThrow(
            maybeRequest = try HTTPClient.Request(
                url: "http://localhost/",
                method: .POST,
                body: .stream(contentLength: 10) { writer in
                    embedded.isWritable = false
                    embedded.pipeline.fireChannelWritabilityChanged()
                    // This should not trigger any errors or timeouts, because the timer isn't running
                    // as the channel is not writable.
                    embedded.embeddedEventLoop.advanceTime(by: .milliseconds(20))

                    // Now that the channel will become writable, this should trigger a timeout.
                    embedded.isWritable = true
                    embedded.pipeline.fireChannelWritabilityChanged()
                    embedded.embeddedEventLoop.advanceTime(by: .milliseconds(2))

                    return testWriter.start(writer: writer)
                }
            )
        )

        guard let request = maybeRequest else { return XCTFail("Expected to be able to create a request") }

        let delegate = ResponseAccumulator(request: request)
        var maybeRequestBag: RequestBag<ResponseAccumulator>?
        XCTAssertNoThrow(
            maybeRequestBag = try RequestBag(
                request: request,
                eventLoopPreference: .delegate(on: embedded.eventLoop),
                task: .init(eventLoop: embedded.eventLoop, logger: logger),
                redirectHandler: nil,
                connectionDeadline: .now() + .seconds(30),
                requestOptions: .forTests(idleWriteTimeout: .milliseconds(1)),
                delegate: delegate
            )
        )
        guard let requestBag = maybeRequestBag else { return XCTFail("Expected to be able to create a request bag") }

        embedded.isWritable = true
        testWriter.writabilityChanged(true)
        embedded.pipeline.fireChannelWritabilityChanged()
        embedded.write(requestBag, promise: nil)

        XCTAssertThrowsError(try requestBag.task.futureResult.wait()) {
            XCTAssertEqual($0 as? HTTPClientError, .writeTimeout)
        }
    }

    func testIdleWriteTimeoutIsCanceledIfRequestIsCanceled() {
        let embedded = EmbeddedChannel()
        let readEventHandler = ReadEventHitHandler()
        let requestHandler = HTTP2ClientRequestHandler(eventLoop: embedded.eventLoop)
        XCTAssertNoThrow(try embedded.pipeline.syncOperations.addHandlers([readEventHandler, requestHandler]))
        XCTAssertNoThrow(try embedded.connect(to: .makeAddressResolvingHost("localhost", port: 0)).wait())
        let logger = Logger(label: "test")

        let testWriter = TestBackpressureWriter(eventLoop: embedded.eventLoop, parts: 5)
        var maybeRequest: HTTPClient.Request?
        XCTAssertNoThrow(
            maybeRequest = try HTTPClient.Request(
                url: "http://localhost/",
                method: .POST,
                body: .stream(contentLength: 2) { writer in
                    testWriter.start(writer: writer, expectedErrors: [HTTPClientError.cancelled])
                }
            )
        )
        guard let request = maybeRequest else { return XCTFail("Expected to be able to create a request") }

        let delegate = ResponseBackpressureDelegate(eventLoop: embedded.eventLoop)
        var maybeRequestBag: RequestBag<ResponseBackpressureDelegate>?
        XCTAssertNoThrow(
            maybeRequestBag = try RequestBag(
                request: request,
                eventLoopPreference: .delegate(on: embedded.eventLoop),
                task: .init(eventLoop: embedded.eventLoop, logger: logger),
                redirectHandler: nil,
                connectionDeadline: .now() + .seconds(30),
                requestOptions: .forTests(idleWriteTimeout: .milliseconds(1)),
                delegate: delegate
            )
        )
        guard let requestBag = maybeRequestBag else { return XCTFail("Expected to be able to create a request bag") }

        embedded.isWritable = true
        testWriter.writabilityChanged(true)
        embedded.pipeline.fireChannelWritabilityChanged()
        embedded.write(requestBag, promise: nil)

        // canceling the request
        requestBag.fail(HTTPClientError.cancelled)
        XCTAssertThrowsError(try requestBag.task.futureResult.wait()) {
            XCTAssertEqual($0 as? HTTPClientError, .cancelled)
        }

        // the idle read timeout should be cleared because we canceled the request
        // therefore advancing the time should not trigger a crash
        embedded.embeddedEventLoop.advanceTime(by: .milliseconds(250))
    }

    func testWriteHTTPHeadFails() {
        struct WriteError: Error, Equatable {}

        class FailWriteHandler: ChannelOutboundHandler {
            typealias OutboundIn = HTTPClientRequestPart
            typealias OutboundOut = HTTPClientRequestPart

            func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
                let error = WriteError()
                promise?.fail(error)
                context.fireErrorCaught(error)
            }
        }

        let bodies: [HTTPClient.Body?] = [
            .none,
            .some(.byteBuffer(ByteBuffer(string: "hello world"))),
        ]

        for body in bodies {
            let embeddedEventLoop = EmbeddedEventLoop()
            let requestHandler = HTTP2ClientRequestHandler(eventLoop: embeddedEventLoop)
            let embedded = EmbeddedChannel(handlers: [FailWriteHandler(), requestHandler], loop: embeddedEventLoop)

            let logger = Logger(label: "test")

            var maybeRequest: HTTPClient.Request?
            XCTAssertNoThrow(maybeRequest = try HTTPClient.Request(url: "http://localhost/", method: .POST, body: body))
            guard let request = maybeRequest else { return XCTFail("Expected to be able to create a request") }

            let delegate = ResponseAccumulator(request: request)
            var maybeRequestBag: RequestBag<ResponseAccumulator>?
            XCTAssertNoThrow(
                maybeRequestBag = try RequestBag(
                    request: request,
                    eventLoopPreference: .delegate(on: embedded.eventLoop),
                    task: .init(eventLoop: embedded.eventLoop, logger: logger),
                    redirectHandler: nil,
                    connectionDeadline: .now() + .seconds(30),
                    requestOptions: .forTests(idleReadTimeout: .milliseconds(200)),
                    delegate: delegate
                )
            )
            guard let requestBag = maybeRequestBag else {
                return XCTFail("Expected to be able to create a request bag")
            }

            embedded.isWritable = false
            XCTAssertNoThrow(try embedded.connect(to: .makeAddressResolvingHost("localhost", port: 0)).wait())
            embedded.write(requestBag, promise: nil)

            // the handler only writes once the channel is writable
            XCTAssertEqual(try embedded.readOutbound(as: HTTPClientRequestPart.self), .none)
            XCTAssertTrue(embedded.isActive)
            embedded.isWritable = true
            embedded.pipeline.fireChannelWritabilityChanged()

            XCTAssertThrowsError(try requestBag.task.futureResult.wait()) {
                XCTAssertEqual($0 as? WriteError, WriteError())
            }

            XCTAssertFalse(embedded.isActive)
        }
    }

    func testChannelBecomesNonWritableDuringHeaderWrite() throws {
        final class ChangeWritabilityOnFlush: ChannelOutboundHandler {
            typealias OutboundIn = Any
            func flush(context: ChannelHandlerContext) {
                context.flush()
                (context.channel as! EmbeddedChannel).isWritable = false
                context.fireChannelWritabilityChanged()
            }
        }
        let eventLoopGroup = EmbeddedEventLoopGroup(loops: 1)
        let eventLoop = eventLoopGroup.next() as! EmbeddedEventLoop
        let handler = HTTP2ClientRequestHandler(
            eventLoop: eventLoop
        )
        let channel = EmbeddedChannel(
            handlers: [
                ChangeWritabilityOnFlush(),
                handler,
            ],
            loop: eventLoop
        )
        try channel.connect(to: .init(ipAddress: "127.0.0.1", port: 80)).wait()

        // non empty body is important to trigger this bug as we otherwise finish the request in a single flush
        let request = MockHTTPExecutableRequest(
            framingMetadata: RequestFramingMetadata(connectionClose: false, body: .fixedSize(1)),
            raiseErrorIfUnimplementedMethodIsCalled: false
        )
        channel.writeAndFlush(request, promise: nil)
        XCTAssertEqual(request.events.map(\.kind), [.willExecuteRequest, .requestHeadSent])
    }
}
