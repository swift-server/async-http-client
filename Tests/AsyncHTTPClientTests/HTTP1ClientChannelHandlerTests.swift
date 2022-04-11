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

@testable import AsyncHTTPClient
import Logging
import NIOCore
import NIOEmbedded
import NIOHTTP1
import XCTest

class HTTP1ClientChannelHandlerTests: XCTestCase {
    func testResponseBackpressure() {
        let embedded = EmbeddedChannel()
        var maybeTestUtils: HTTP1TestTools?
        XCTAssertNoThrow(maybeTestUtils = try embedded.setupHTTP1Connection())
        guard let testUtils = maybeTestUtils else { return XCTFail("Expected connection setup works") }

        var maybeRequest: HTTPClient.Request?
        XCTAssertNoThrow(maybeRequest = try HTTPClient.Request(url: "http://localhost/"))
        guard let request = maybeRequest else { return XCTFail("Expected to be able to create a request") }

        let delegate = ResponseBackpressureDelegate(eventLoop: embedded.eventLoop)
        var maybeRequestBag: RequestBag<ResponseBackpressureDelegate>?
        XCTAssertNoThrow(maybeRequestBag = try RequestBag(
            request: request,
            eventLoopPreference: .delegate(on: embedded.eventLoop),
            task: .init(eventLoop: embedded.eventLoop, logger: testUtils.logger),
            redirectHandler: nil,
            connectionDeadline: .now() + .seconds(30),
            requestOptions: .forTests(),
            delegate: delegate
        ))
        guard let requestBag = maybeRequestBag else { return XCTFail("Expected to be able to create a request bag") }

        testUtils.connection.executeRequest(requestBag)

        XCTAssertNoThrow(try embedded.receiveHeadAndVerify {
            XCTAssertEqual($0.method, .GET)
            XCTAssertEqual($0.uri, "/")
            XCTAssertEqual($0.headers.first(name: "host"), "localhost")
        })
        XCTAssertEqual(try embedded.readOutbound(as: HTTPClientRequestPart.self), .end(nil))

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok, headers: HTTPHeaders([("content-length", "12")]))

        XCTAssertEqual(testUtils.readEventHandler.readHitCounter, 0)
        embedded.read()
        XCTAssertEqual(testUtils.readEventHandler.readHitCounter, 1)
        XCTAssertNoThrow(try embedded.writeInbound(HTTPClientResponsePart.head(responseHead)))

        let part0 = ByteBuffer(bytes: 0...3)
        let part1 = ByteBuffer(bytes: 4...7)
        let part2 = ByteBuffer(bytes: 8...11)

        // part 0. Demand first, read second
        XCTAssertEqual(testUtils.readEventHandler.readHitCounter, 1)
        let part0Future = delegate.next()
        XCTAssertEqual(testUtils.readEventHandler.readHitCounter, 1)
        embedded.read()
        XCTAssertEqual(testUtils.readEventHandler.readHitCounter, 2)
        XCTAssertNoThrow(try embedded.writeInbound(HTTPClientResponsePart.body(part0)))
        XCTAssertEqual(try part0Future.wait(), part0)

        // part 1. read first, demand second

        XCTAssertEqual(testUtils.readEventHandler.readHitCounter, 2)
        embedded.read()
        XCTAssertEqual(testUtils.readEventHandler.readHitCounter, 2)
        let part1Future = delegate.next()
        XCTAssertEqual(testUtils.readEventHandler.readHitCounter, 3)
        XCTAssertNoThrow(try embedded.writeInbound(HTTPClientResponsePart.body(part1)))
        XCTAssertEqual(try part1Future.wait(), part1)

        // part 2. Demand first, read second
        XCTAssertEqual(testUtils.readEventHandler.readHitCounter, 3)
        let part2Future = delegate.next()
        XCTAssertEqual(testUtils.readEventHandler.readHitCounter, 3)
        embedded.read()
        XCTAssertEqual(testUtils.readEventHandler.readHitCounter, 4)
        XCTAssertNoThrow(try embedded.writeInbound(HTTPClientResponsePart.body(part2)))
        XCTAssertEqual(try part2Future.wait(), part2)

        // end. read first, demand second
        XCTAssertEqual(testUtils.readEventHandler.readHitCounter, 4)
        embedded.read()
        XCTAssertEqual(testUtils.readEventHandler.readHitCounter, 4)
        let endFuture = delegate.next()
        XCTAssertEqual(testUtils.readEventHandler.readHitCounter, 5)
        XCTAssertEqual(testUtils.connectionDelegate.hitConnectionReleased, 0)
        XCTAssertNoThrow(try embedded.writeInbound(HTTPClientResponsePart.end(nil)))
        XCTAssertEqual(testUtils.connectionDelegate.hitConnectionReleased, 1)
        XCTAssertEqual(try endFuture.wait(), .none)

        XCTAssertNoThrow(try requestBag.task.futureResult.wait())
    }

    func testWriteBackpressure() {
        let embedded = EmbeddedChannel()
        let testWriter = TestBackpressureWriter(eventLoop: embedded.eventLoop, parts: 50)
        var maybeTestUtils: HTTP1TestTools?
        XCTAssertNoThrow(maybeTestUtils = try embedded.setupHTTP1Connection())
        guard let testUtils = maybeTestUtils else { return XCTFail("Expected connection setup works") }

        var maybeRequest: HTTPClient.Request?
        XCTAssertNoThrow(maybeRequest = try HTTPClient.Request(url: "http://localhost/", method: .POST, body: .stream(length: 100) { writer in
            testWriter.start(writer: writer)
        }))
        guard let request = maybeRequest else { return XCTFail("Expected to be able to create a request") }

        let delegate = ResponseAccumulator(request: request)
        var maybeRequestBag: RequestBag<ResponseAccumulator>?
        XCTAssertNoThrow(maybeRequestBag = try RequestBag(
            request: request,
            eventLoopPreference: .delegate(on: embedded.eventLoop),
            task: .init(eventLoop: embedded.eventLoop, logger: testUtils.logger),
            redirectHandler: nil,
            connectionDeadline: .now() + .seconds(30),
            requestOptions: .forTests(idleReadTimeout: .milliseconds(200)),
            delegate: delegate
        ))
        guard let requestBag = maybeRequestBag else { return XCTFail("Expected to be able to create a request bag") }

        // the handler only writes once the channel is writable
        embedded.isWritable = false
        testWriter.writabilityChanged(false)
        embedded.pipeline.fireChannelWritabilityChanged()
        testUtils.connection.executeRequest(requestBag)

        XCTAssertEqual(try embedded.readOutbound(as: HTTPClientRequestPart.self), .none)

        embedded.isWritable = true
        testWriter.writabilityChanged(true)
        embedded.pipeline.fireChannelWritabilityChanged()

        XCTAssertNoThrow(try embedded.receiveHeadAndVerify {
            XCTAssertEqual($0.method, .POST)
            XCTAssertEqual($0.uri, "/")
            XCTAssertEqual($0.headers.first(name: "host"), "localhost")
            XCTAssertEqual($0.headers.first(name: "content-length"), "100")
        })

        // the next body write will be executed once we tick the el. before we make the channel
        // unwritable

        for index in 0..<50 {
            embedded.isWritable = false
            testWriter.writabilityChanged(false)
            embedded.pipeline.fireChannelWritabilityChanged()

            XCTAssertEqual(testWriter.written, index)

            embedded.embeddedEventLoop.run()

            XCTAssertNoThrow(try embedded.receiveBodyAndVerify {
                XCTAssertEqual($0.readableBytes, 2)
            })

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

        XCTAssertEqual(testUtils.connectionDelegate.hitConnectionClosed, 0)
        XCTAssertEqual(testUtils.connectionDelegate.hitConnectionReleased, 0)
        XCTAssertNoThrow(try embedded.writeInbound(HTTPClientResponsePart.end(nil)))
        XCTAssertEqual(testUtils.connectionDelegate.hitConnectionClosed, 0)
        XCTAssertEqual(testUtils.connectionDelegate.hitConnectionReleased, 1)

        XCTAssertNoThrow(try requestBag.task.futureResult.wait())
    }

    func testClientHandlerCancelsRequestIfWeWantToShutdown() {
        let embedded = EmbeddedChannel()
        var maybeTestUtils: HTTP1TestTools?
        XCTAssertNoThrow(maybeTestUtils = try embedded.setupHTTP1Connection())
        guard let testUtils = maybeTestUtils else { return XCTFail("Expected connection setup works") }

        var maybeRequest: HTTPClient.Request?
        XCTAssertNoThrow(maybeRequest = try HTTPClient.Request(url: "http://localhost/"))
        guard let request = maybeRequest else { return XCTFail("Expected to be able to create a request") }

        let delegate = ResponseAccumulator(request: request)
        var maybeRequestBag: RequestBag<ResponseAccumulator>?
        XCTAssertNoThrow(maybeRequestBag = try RequestBag(
            request: request,
            eventLoopPreference: .delegate(on: embedded.eventLoop),
            task: .init(eventLoop: embedded.eventLoop, logger: testUtils.logger),
            redirectHandler: nil,
            connectionDeadline: .now() + .seconds(30),
            requestOptions: .forTests(idleReadTimeout: .milliseconds(200)),
            delegate: delegate
        ))
        guard let requestBag = maybeRequestBag else { return XCTFail("Expected to be able to create a request bag") }

        testUtils.connection.executeRequest(requestBag)

        XCTAssertNoThrow(try embedded.receiveHeadAndVerify {
            XCTAssertEqual($0.method, .GET)
            XCTAssertEqual($0.uri, "/")
            XCTAssertEqual($0.headers.first(name: "host"), "localhost")
        })
        XCTAssertNoThrow(try embedded.receiveEnd())

        XCTAssertTrue(embedded.isActive)
        XCTAssertEqual(testUtils.connectionDelegate.hitConnectionClosed, 0)
        XCTAssertEqual(testUtils.connectionDelegate.hitConnectionReleased, 0)
        testUtils.connection.shutdown()
        XCTAssertFalse(embedded.isActive)
        embedded.embeddedEventLoop.run()
        XCTAssertEqual(testUtils.connectionDelegate.hitConnectionClosed, 1)
        XCTAssertEqual(testUtils.connectionDelegate.hitConnectionReleased, 0)

        XCTAssertThrowsError(try requestBag.task.futureResult.wait()) {
            XCTAssertEqual($0 as? HTTPClientError, .cancelled)
        }
    }

    func testIdleReadTimeout() {
        let embedded = EmbeddedChannel()
        var maybeTestUtils: HTTP1TestTools?
        XCTAssertNoThrow(maybeTestUtils = try embedded.setupHTTP1Connection())
        guard let testUtils = maybeTestUtils else { return XCTFail("Expected connection setup works") }

        var maybeRequest: HTTPClient.Request?
        XCTAssertNoThrow(maybeRequest = try HTTPClient.Request(url: "http://localhost/"))
        guard let request = maybeRequest else { return XCTFail("Expected to be able to create a request") }

        let delegate = ResponseBackpressureDelegate(eventLoop: embedded.eventLoop)
        var maybeRequestBag: RequestBag<ResponseBackpressureDelegate>?
        XCTAssertNoThrow(maybeRequestBag = try RequestBag(
            request: request,
            eventLoopPreference: .delegate(on: embedded.eventLoop),
            task: .init(eventLoop: embedded.eventLoop, logger: testUtils.logger),
            redirectHandler: nil,
            connectionDeadline: .now() + .seconds(30),
            requestOptions: .forTests(idleReadTimeout: .milliseconds(200)),
            delegate: delegate
        ))
        guard let requestBag = maybeRequestBag else { return XCTFail("Expected to be able to create a request bag") }

        testUtils.connection.executeRequest(requestBag)

        XCTAssertNoThrow(try embedded.receiveHeadAndVerify {
            XCTAssertEqual($0.method, .GET)
            XCTAssertEqual($0.uri, "/")
            XCTAssertEqual($0.headers.first(name: "host"), "localhost")
        })
        XCTAssertNoThrow(try embedded.receiveEnd())

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok, headers: HTTPHeaders([("content-length", "12")]))

        XCTAssertEqual(testUtils.readEventHandler.readHitCounter, 0)
        embedded.read()
        XCTAssertEqual(testUtils.readEventHandler.readHitCounter, 1)
        XCTAssertNoThrow(try embedded.writeInbound(HTTPClientResponsePart.head(responseHead)))

        // not sending anything after the head should lead to request fail and connection close

        XCTAssertEqual(testUtils.connectionDelegate.hitConnectionClosed, 0)
        XCTAssertEqual(testUtils.connectionDelegate.hitConnectionReleased, 0)
        embedded.embeddedEventLoop.advanceTime(by: .milliseconds(250))
        XCTAssertEqual(testUtils.connectionDelegate.hitConnectionClosed, 1)
        XCTAssertEqual(testUtils.connectionDelegate.hitConnectionReleased, 0)

        XCTAssertThrowsError(try requestBag.task.futureResult.wait()) {
            XCTAssertEqual($0 as? HTTPClientError, .readTimeout)
        }
    }

    func testIdleReadTimeoutIsCanceledIfRequestIsCanceled() {
        let embedded = EmbeddedChannel()
        var maybeTestUtils: HTTP1TestTools?
        XCTAssertNoThrow(maybeTestUtils = try embedded.setupHTTP1Connection())
        guard let testUtils = maybeTestUtils else { return XCTFail("Expected connection setup works") }

        var maybeRequest: HTTPClient.Request?
        XCTAssertNoThrow(maybeRequest = try HTTPClient.Request(url: "http://localhost/"))
        guard let request = maybeRequest else { return XCTFail("Expected to be able to create a request") }

        let delegate = ResponseBackpressureDelegate(eventLoop: embedded.eventLoop)
        var maybeRequestBag: RequestBag<ResponseBackpressureDelegate>?
        XCTAssertNoThrow(maybeRequestBag = try RequestBag(
            request: request,
            eventLoopPreference: .delegate(on: embedded.eventLoop),
            task: .init(eventLoop: embedded.eventLoop, logger: testUtils.logger),
            redirectHandler: nil,
            connectionDeadline: .now() + .seconds(30),
            requestOptions: .forTests(idleReadTimeout: .milliseconds(200)),
            delegate: delegate
        ))
        guard let requestBag = maybeRequestBag else { return XCTFail("Expected to be able to create a request bag") }

        testUtils.connection.executeRequest(requestBag)

        XCTAssertNoThrow(try embedded.receiveHeadAndVerify {
            XCTAssertEqual($0.method, .GET)
            XCTAssertEqual($0.uri, "/")
            XCTAssertEqual($0.headers.first(name: "host"), "localhost")
        })
        XCTAssertNoThrow(try embedded.receiveEnd())

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok, headers: HTTPHeaders([("content-length", "12")]))

        XCTAssertEqual(testUtils.readEventHandler.readHitCounter, 0)
        embedded.read()
        XCTAssertEqual(testUtils.readEventHandler.readHitCounter, 1)
        XCTAssertNoThrow(try embedded.writeInbound(HTTPClientResponsePart.head(responseHead)))

        // canceling the request
        requestBag.cancel()
        XCTAssertThrowsError(try requestBag.task.futureResult.wait()) {
            XCTAssertEqual($0 as? HTTPClientError, .cancelled)
        }

        // the idle read timeout should be cleared because we canceled the request
        // therefore advancing the time should not trigger a crash
        embedded.embeddedEventLoop.advanceTime(by: .milliseconds(250))
    }

    func testFailHTTPRequestWithContentLengthBecauseOfChannelInactiveWaitingForDemand() {
        let embedded = EmbeddedChannel()
        var maybeTestUtils: HTTP1TestTools?
        XCTAssertNoThrow(maybeTestUtils = try embedded.setupHTTP1Connection())
        guard let testUtils = maybeTestUtils else { return XCTFail("Expected connection setup works") }

        var maybeRequest: HTTPClient.Request?
        XCTAssertNoThrow(maybeRequest = try HTTPClient.Request(url: "http://localhost/"))
        guard let request = maybeRequest else { return XCTFail("Expected to be able to create a request") }

        let delegate = ResponseBackpressureDelegate(eventLoop: embedded.eventLoop)
        var maybeRequestBag: RequestBag<ResponseBackpressureDelegate>?
        XCTAssertNoThrow(maybeRequestBag = try RequestBag(
            request: request,
            eventLoopPreference: .delegate(on: embedded.eventLoop),
            task: .init(eventLoop: embedded.eventLoop, logger: testUtils.logger),
            redirectHandler: nil,
            connectionDeadline: .now() + .seconds(30),
            requestOptions: .forTests(),
            delegate: delegate
        ))
        guard let requestBag = maybeRequestBag else { return XCTFail("Expected to be able to create a request bag") }

        testUtils.connection.executeRequest(requestBag)

        XCTAssertNoThrow(try embedded.receiveHeadAndVerify {
            XCTAssertEqual($0.method, .GET)
            XCTAssertEqual($0.uri, "/")
            XCTAssertEqual($0.headers.first(name: "host"), "localhost")
        })
        XCTAssertNoThrow(try embedded.receiveEnd())

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok, headers: HTTPHeaders([("content-length", "50")]))

        XCTAssertEqual(testUtils.readEventHandler.readHitCounter, 0)
        embedded.read()
        XCTAssertEqual(testUtils.readEventHandler.readHitCounter, 1)
        XCTAssertNoThrow(try embedded.writeInbound(HTTPClientResponsePart.head(responseHead)))

        // not sending anything after the head should lead to request fail and connection close
        embedded.pipeline.fireChannelReadComplete()
        embedded.pipeline.read()
        XCTAssertEqual(testUtils.readEventHandler.readHitCounter, 2)

        XCTAssertNoThrow(try embedded.writeInbound(HTTPClientResponsePart.body(ByteBuffer(string: "foo bar"))))
        embedded.pipeline.fireChannelReadComplete()
        // We miss a `embedded.pipeline.read()` here by purpose.
        XCTAssertEqual(testUtils.readEventHandler.readHitCounter, 2)

        XCTAssertNoThrow(try embedded.writeInbound(HTTPClientResponsePart.body(ByteBuffer(string: "last bytes"))))
        embedded.pipeline.fireChannelReadComplete()
        embedded.pipeline.fireChannelInactive()

        XCTAssertThrowsError(try requestBag.task.futureResult.wait()) {
            XCTAssertEqual($0 as? HTTPClientError, .remoteConnectionClosed)
        }
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
            let embedded = EmbeddedChannel()
            var maybeTestUtils: HTTP1TestTools?
            XCTAssertNoThrow(maybeTestUtils = try embedded.setupHTTP1Connection())
            guard let testUtils = maybeTestUtils else { return XCTFail("Expected connection setup works") }

            XCTAssertNoThrow(try embedded.pipeline.syncOperations.addHandler(FailWriteHandler(), position: .after(testUtils.readEventHandler)))

            let logger = Logger(label: "test")

            var maybeRequest: HTTPClient.Request?
            XCTAssertNoThrow(maybeRequest = try HTTPClient.Request(url: "http://localhost/", method: .POST, body: body))
            guard let request = maybeRequest else { return XCTFail("Expected to be able to create a request") }

            let delegate = ResponseAccumulator(request: request)
            var maybeRequestBag: RequestBag<ResponseAccumulator>?
            XCTAssertNoThrow(maybeRequestBag = try RequestBag(
                request: request,
                eventLoopPreference: .delegate(on: embedded.eventLoop),
                task: .init(eventLoop: embedded.eventLoop, logger: logger),
                redirectHandler: nil,
                connectionDeadline: .now() + .seconds(30),
                requestOptions: .forTests(idleReadTimeout: .milliseconds(200)),
                delegate: delegate
            ))
            guard let requestBag = maybeRequestBag else { return XCTFail("Expected to be able to create a request bag") }

            embedded.isWritable = false
            XCTAssertNoThrow(try embedded.connect(to: .makeAddressResolvingHost("localhost", port: 0)).wait())
            embedded.write(requestBag, promise: nil)

            // the handler only writes once the channel is writable
            XCTAssertEqual(try embedded.readOutbound(as: HTTPClientRequestPart.self), .none)
            embedded.isWritable = true
            embedded.pipeline.fireChannelWritabilityChanged()

            XCTAssertThrowsError(try requestBag.task.futureResult.wait()) {
                XCTAssertEqual($0 as? WriteError, WriteError())
            }

            XCTAssertEqual(embedded.isActive, false)
        }
    }
}

class TestBackpressureWriter {
    let eventLoop: EventLoop

    let parts: Int

    var finishFuture: EventLoopFuture<Void> { self.finishPromise.futureResult }
    private let finishPromise: EventLoopPromise<Void>
    private(set) var written: Int = 0

    private var channelIsWritable: Bool = false

    init(eventLoop: EventLoop, parts: Int) {
        self.eventLoop = eventLoop
        self.parts = parts

        self.finishPromise = eventLoop.makePromise(of: Void.self)
    }

    func start(writer: HTTPClient.Body.StreamWriter) -> EventLoopFuture<Void> {
        func recursive() {
            XCTAssert(self.eventLoop.inEventLoop)
            XCTAssert(self.channelIsWritable)
            if self.written == self.parts {
                self.finishPromise.succeed(())
            } else {
                self.eventLoop.execute {
                    let future = writer.write(.byteBuffer(.init(bytes: [0, 1])))
                    self.written += 1
                    future.whenComplete { result in
                        switch result {
                        case .success:
                            recursive()
                        case .failure(let error):
                            XCTFail("Unexpected error: \(error)")
                        }
                    }
                }
            }
        }

        recursive()

        return self.finishFuture
    }

    func writabilityChanged(_ newValue: Bool) {
        self.channelIsWritable = newValue
    }
}

class ResponseBackpressureDelegate: HTTPClientResponseDelegate {
    typealias Response = Void

    enum State {
        case consuming(EventLoopPromise<Void>)
        case waitingForRemote(CircularBuffer<EventLoopPromise<ByteBuffer?>>)
        case buffering((ByteBuffer?, EventLoopPromise<Void>)?)
        case done
    }

    let eventLoop: EventLoop
    private var state: State = .buffering(nil)

    init(eventLoop: EventLoop) {
        self.eventLoop = eventLoop

        self.state = .consuming(self.eventLoop.makePromise(of: Void.self))
    }

    func next() -> EventLoopFuture<ByteBuffer?> {
        switch self.state {
        case .consuming(let backpressurePromise):
            var promiseBuffer = CircularBuffer<EventLoopPromise<ByteBuffer?>>()
            let newPromise = self.eventLoop.makePromise(of: ByteBuffer?.self)
            promiseBuffer.append(newPromise)
            self.state = .waitingForRemote(promiseBuffer)
            backpressurePromise.succeed(())
            return newPromise.futureResult

        case .waitingForRemote(var promiseBuffer):
            assert(!promiseBuffer.isEmpty, "assert expected to be waiting if we have at least one promise in the buffer")
            let promise = self.eventLoop.makePromise(of: ByteBuffer?.self)
            promiseBuffer.append(promise)
            self.state = .waitingForRemote(promiseBuffer)
            return promise.futureResult

        case .buffering(.none):
            var promiseBuffer = CircularBuffer<EventLoopPromise<ByteBuffer?>>()
            let promise = self.eventLoop.makePromise(of: ByteBuffer?.self)
            promiseBuffer.append(promise)
            self.state = .waitingForRemote(promiseBuffer)
            return promise.futureResult

        case .buffering(.some((let buffer, let promise))):
            self.state = .buffering(nil)
            promise.succeed(())
            return self.eventLoop.makeSucceededFuture(buffer)

        case .done:
            return self.eventLoop.makeSucceededFuture(.none)
        }
    }

    func didReceiveHead(task: HTTPClient.Task<Void>, _ head: HTTPResponseHead) -> EventLoopFuture<Void> {
        switch self.state {
        case .consuming(let backpressurePromise):
            return backpressurePromise.futureResult

        case .waitingForRemote:
            return self.eventLoop.makeSucceededVoidFuture()

        case .buffering, .done:
            preconditionFailure("State must be either waitingForRemote or initialized")
        }
    }

    func didReceiveBodyPart(task: HTTPClient.Task<Void>, _ buffer: ByteBuffer) -> EventLoopFuture<Void> {
        switch self.state {
        case .waitingForRemote(var promiseBuffer):
            assert(!promiseBuffer.isEmpty, "assert expected to be waiting if we have at least one promise in the buffer")
            let promise = promiseBuffer.removeFirst()
            if promiseBuffer.isEmpty {
                let newBackpressurePromise = self.eventLoop.makePromise(of: Void.self)
                self.state = .consuming(newBackpressurePromise)
                promise.succeed(buffer)
                return newBackpressurePromise.futureResult
            } else {
                self.state = .waitingForRemote(promiseBuffer)
                promise.succeed(buffer)
                return self.eventLoop.makeSucceededVoidFuture()
            }

        case .buffering(.none):
            let promise = self.eventLoop.makePromise(of: Void.self)
            self.state = .buffering((buffer, promise))
            return promise.futureResult

        case .buffering(.some):
            preconditionFailure("Did receive response part should not be called, before the previous promise was succeeded.")

        case .done, .consuming:
            preconditionFailure("Invalid state: \(self.state)")
        }
    }

    func didFinishRequest(task: HTTPClient.Task<Void>) throws {
        switch self.state {
        case .waitingForRemote(let promiseBuffer):
            promiseBuffer.forEach {
                $0.succeed(.none)
            }
            self.state = .done

        case .buffering(.none):
            self.state = .done

        case .done, .consuming:
            preconditionFailure("Invalid state: \(self.state)")

        case .buffering(.some):
            preconditionFailure("Did receive response part should not be called, before the previous promise was succeeded.")
        }
    }
}

class ReadEventHitHandler: ChannelOutboundHandler {
    public typealias OutboundIn = NIOAny

    private(set) var readHitCounter = 0

    public init() {}

    public func read(context: ChannelHandlerContext) {
        self.readHitCounter += 1
        context.read()
    }
}
