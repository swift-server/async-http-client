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
import NIO
import NIOHTTP1
import XCTest

final class RequestBagTests: XCTestCase {
    func testWriteBackpressureWorks() {
        let embeddedEventLoop = EmbeddedEventLoop()
        defer { XCTAssertNoThrow(try embeddedEventLoop.syncShutdownGracefully()) }
        let logger = Logger(label: "test")

        var writtenBytes = 0
        var writes = 0
        let bytesToSent = (3000...10000).randomElement()!
        var streamIsAllowedToWrite = false

        let writeDonePromise = embeddedEventLoop.makePromise(of: Void.self)
        let requestBody: HTTPClient.Body = .stream(length: bytesToSent) { writer -> EventLoopFuture<Void> in
            func write(donePromise: EventLoopPromise<Void>) {
                XCTAssertTrue(streamIsAllowedToWrite)
                guard writtenBytes < bytesToSent else {
                    return donePromise.succeed(())
                }
                let byteCount = min(bytesToSent - writtenBytes, 100)
                let buffer = ByteBuffer(bytes: [UInt8](repeating: 1, count: byteCount))
                writes += 1
                writer.write(.byteBuffer(buffer)).whenSuccess { _ in
                    writtenBytes += 100
                    write(donePromise: donePromise)
                }
            }

            write(donePromise: writeDonePromise)

            return writeDonePromise.futureResult
        }

        var maybeRequest: HTTPClient.Request?
        XCTAssertNoThrow(maybeRequest = try HTTPClient.Request(url: "https://swift.org", method: .POST, body: requestBody))
        guard let request = maybeRequest else { return XCTFail("Expected to have a request") }

        let delegate = UploadCountingDelegate(eventLoop: embeddedEventLoop)
        let bag = RequestBag(
            request: request,
            eventLoopPreference: .delegate(on: embeddedEventLoop),
            task: .init(eventLoop: embeddedEventLoop, logger: logger),
            redirectHandler: nil,
            connectionDeadline: .now() + .seconds(30),
            idleReadTimeout: nil,
            delegate: delegate
        )
        XCTAssert(bag.task.eventLoop === embeddedEventLoop)

        let executor = MockRequestExecutor(pauseRequestBodyPartStreamAfterASingleWrite: true)

        bag.willExecuteRequest(executor)

        XCTAssertEqual(delegate.hitDidSendRequestHead, 0)
        bag.requestHeadSent()
        XCTAssertEqual(delegate.hitDidSendRequestHead, 1)
        streamIsAllowedToWrite = true
        bag.resumeRequestBodyStream()
        streamIsAllowedToWrite = false

        // after starting the body stream we should have received two writes
        var eof = false
        var receivedBytes = 0
        while !eof {
            switch executor.nextBodyPart() {
            case .body(.byteBuffer(let bytes)):
                XCTAssertEqual(delegate.hitDidSendRequestPart, writes)
                receivedBytes += bytes.readableBytes
            case .body(.fileRegion(_)):
                return XCTFail("We never send a file region. Something is really broken")
            case .endOfStream:
                XCTAssertEqual(delegate.hitDidSendRequest, 1)
                eof = true
            case .none:
                // this should produce maximum two parts
                streamIsAllowedToWrite = true
                bag.resumeRequestBodyStream()
                streamIsAllowedToWrite = false
                XCTAssertLessThanOrEqual(executor.requestBodyParts.count, 2)
                XCTAssertEqual(delegate.hitDidSendRequestPart, writes)
            }
        }

        XCTAssertEqual(receivedBytes, bytesToSent, "We have sent all request bytes...")

        XCTAssertNil(delegate.receivedHead, "Expected not to have a response head, before `receiveResponseHead`")
        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok, headers: .init([
            ("Transfer-Encoding", "chunked"),
        ]))
        bag.receiveResponseHead(responseHead)
        XCTAssertEqual(responseHead, delegate.receivedHead)
        XCTAssertNoThrow(try XCTUnwrap(delegate.backpressurePromise).succeed(()))
        XCTAssertTrue(executor.signalledDemandForResponseBody)
        executor.resetDemandSignal()

        // we will receive 20 chunks with each 10 byteBuffers and 32 bytes
        let bodyPart = ByteBuffer(bytes: 0..<32)
        for i in 0..<20 {
            let chunk = CircularBuffer(repeating: bodyPart, count: 10)
            XCTAssertEqual(delegate.hitDidReceiveBodyPart, i * 10) // 0
            bag.receiveResponseBodyParts(chunk)

            // consume the 10 buffers
            for j in 0..<10 {
                XCTAssertEqual(delegate.hitDidReceiveBodyPart, i * 10 + j + 1)
                XCTAssertEqual(delegate.lastBodyPart, bodyPart)
                XCTAssertNoThrow(try XCTUnwrap(delegate.backpressurePromise).succeed(()))

                if j < 9 {
                    XCTAssertFalse(executor.signalledDemandForResponseBody)
                } else {
                    XCTAssertTrue(executor.signalledDemandForResponseBody)
                }
            }

            executor.resetDemandSignal()
        }

        XCTAssertEqual(delegate.hitDidReceiveResponse, 0)
        bag.succeedRequest(nil)
        XCTAssertEqual(delegate.hitDidReceiveResponse, 1)

        XCTAssertNoThrow(try bag.task.futureResult.wait(), "The request has succeeded")
    }

    func testTaskIsFailedIfWritingFails() {
        struct TestError: Error, Equatable {}

        let embeddedEventLoop = EmbeddedEventLoop()
        defer { XCTAssertNoThrow(try embeddedEventLoop.syncShutdownGracefully()) }
        let logger = Logger(label: "test")

        let requestBody: HTTPClient.Body = .stream(length: 12) { writer -> EventLoopFuture<Void> in

            writer.write(.byteBuffer(ByteBuffer(bytes: 0...3))).flatMap { _ -> EventLoopFuture<Void> in
                embeddedEventLoop.makeFailedFuture(TestError())
            }
        }

        var maybeRequest: HTTPClient.Request?
        XCTAssertNoThrow(maybeRequest = try HTTPClient.Request(url: "https://swift.org", method: .POST, body: requestBody))
        guard let request = maybeRequest else { return XCTFail("Expected to have a request") }

        let delegate = UploadCountingDelegate(eventLoop: embeddedEventLoop)
        let bag = RequestBag(
            request: request,
            eventLoopPreference: .delegate(on: embeddedEventLoop),
            task: .init(eventLoop: embeddedEventLoop, logger: logger),
            redirectHandler: nil,
            connectionDeadline: .now() + .seconds(30),
            idleReadTimeout: nil,
            delegate: delegate
        )
        XCTAssert(bag.task.eventLoop === embeddedEventLoop)

        let executor = MockRequestExecutor()

        bag.willExecuteRequest(executor)

        XCTAssertEqual(delegate.hitDidSendRequestHead, 0)
        bag.requestHeadSent()
        XCTAssertEqual(delegate.hitDidSendRequestHead, 1)
        XCTAssertEqual(delegate.hitDidSendRequestPart, 0)
        bag.resumeRequestBodyStream()
        XCTAssertEqual(delegate.hitDidSendRequestPart, 1)
        XCTAssertEqual(delegate.hitDidReceiveError, 1)
        XCTAssertEqual(delegate.lastError as? TestError, TestError())

        XCTAssertTrue(executor.isCancelled)

        XCTAssertThrowsError(try bag.task.futureResult.wait()) {
            XCTAssertEqual($0 as? TestError, TestError())
        }
    }

    func testCancelFailsTaskBeforeRequestIsSent() {
        let embeddedEventLoop = EmbeddedEventLoop()
        defer { XCTAssertNoThrow(try embeddedEventLoop.syncShutdownGracefully()) }
        let logger = Logger(label: "test")

        var maybeRequest: HTTPClient.Request?
        XCTAssertNoThrow(maybeRequest = try HTTPClient.Request(url: "https://swift.org"))
        guard let request = maybeRequest else { return XCTFail("Expected to have a request") }

        let delegate = UploadCountingDelegate(eventLoop: embeddedEventLoop)
        let bag = RequestBag(
            request: request,
            eventLoopPreference: .delegate(on: embeddedEventLoop),
            task: .init(eventLoop: embeddedEventLoop, logger: logger),
            redirectHandler: nil,
            connectionDeadline: .now() + .seconds(30),
            idleReadTimeout: nil,
            delegate: delegate
        )
        XCTAssert(bag.eventLoop === embeddedEventLoop)

        let executor = MockRequestExecutor()
        bag.cancel()

        bag.willExecuteRequest(executor)
        XCTAssertTrue(executor.isCancelled, "The request bag, should call cancel immediately on the executor")
        XCTAssertThrowsError(try bag.task.futureResult.wait()) {
            XCTAssertEqual($0 as? HTTPClientError, .cancelled)
        }
    }

    func testCancelFailsTaskAfterRequestIsSent() {
        let embeddedEventLoop = EmbeddedEventLoop()
        defer { XCTAssertNoThrow(try embeddedEventLoop.syncShutdownGracefully()) }
        let logger = Logger(label: "test")

        var maybeRequest: HTTPClient.Request?
        XCTAssertNoThrow(maybeRequest = try HTTPClient.Request(url: "https://swift.org"))
        guard let request = maybeRequest else { return XCTFail("Expected to have a request") }

        let delegate = UploadCountingDelegate(eventLoop: embeddedEventLoop)
        let bag = RequestBag(
            request: request,
            eventLoopPreference: .delegate(on: embeddedEventLoop),
            task: .init(eventLoop: embeddedEventLoop, logger: logger),
            redirectHandler: nil,
            connectionDeadline: .now() + .seconds(30),
            idleReadTimeout: nil,
            delegate: delegate
        )
        XCTAssert(bag.eventLoop === embeddedEventLoop)

        let executor = MockRequestExecutor()

        bag.willExecuteRequest(executor)
        XCTAssertFalse(executor.isCancelled)

        XCTAssertEqual(delegate.hitDidSendRequestHead, 0)
        XCTAssertEqual(delegate.hitDidSendRequest, 0)
        bag.requestHeadSent()
        XCTAssertEqual(delegate.hitDidSendRequestHead, 1)
        XCTAssertEqual(delegate.hitDidSendRequest, 1)

        bag.cancel()
        XCTAssertTrue(executor.isCancelled, "The request bag, should call cancel immediately on the executor")

        XCTAssertThrowsError(try bag.task.futureResult.wait()) {
            XCTAssertEqual($0 as? HTTPClientError, .cancelled)
        }
    }

    func testCancelFailsTaskWhenTaskIsQueued() {
        let embeddedEventLoop = EmbeddedEventLoop()
        defer { XCTAssertNoThrow(try embeddedEventLoop.syncShutdownGracefully()) }
        let logger = Logger(label: "test")

        var maybeRequest: HTTPClient.Request?
        XCTAssertNoThrow(maybeRequest = try HTTPClient.Request(url: "https://swift.org"))
        guard let request = maybeRequest else { return XCTFail("Expected to have a request") }

        let delegate = UploadCountingDelegate(eventLoop: embeddedEventLoop)
        let bag = RequestBag(
            request: request,
            eventLoopPreference: .delegate(on: embeddedEventLoop),
            task: .init(eventLoop: embeddedEventLoop, logger: logger),
            redirectHandler: nil,
            connectionDeadline: .now() + .seconds(30),
            idleReadTimeout: nil,
            delegate: delegate
        )

        let queuer = MockTaskQueuer()
        bag.requestWasQueued(queuer)

        XCTAssertEqual(queuer.hitCancelCount, 0)
        bag.cancel()
        XCTAssertEqual(queuer.hitCancelCount, 1)

        XCTAssertThrowsError(try bag.task.futureResult.wait()) {
            XCTAssertEqual($0 as? HTTPClientError, .cancelled)
        }
    }

    func testHTTPUploadIsCancelledEvenThoughRequestSucceeds() {
        let embeddedEventLoop = EmbeddedEventLoop()
        defer { XCTAssertNoThrow(try embeddedEventLoop.syncShutdownGracefully()) }
        let logger = Logger(label: "test")

        var maybeRequest: HTTPClient.Request?
        let writeSecondPartPromise = embeddedEventLoop.makePromise(of: Void.self)

        XCTAssertNoThrow(maybeRequest = try HTTPClient.Request(
            url: "https://swift.org",
            method: .POST,
            headers: ["content-length": "12"],
            body: .stream(length: 12) { writer -> EventLoopFuture<Void> in
                var firstWriteSuccess = false
                return writer.write(.byteBuffer(.init(bytes: 0...3))).flatMap { _ in
                    firstWriteSuccess = true

                    return writeSecondPartPromise.futureResult
                }.flatMap {
                    return writer.write(.byteBuffer(.init(bytes: 4...7)))
                }.always { result in
                    XCTAssertTrue(firstWriteSuccess)

                    guard case .failure(let error) = result else {
                        return XCTFail("Expected the second write to fail")
                    }
                    XCTAssertEqual(error as? HTTPClientError, .requestStreamCancelled)
                }
            }
        ))
        guard let request = maybeRequest else { return XCTFail("Expected to have a request") }

        let delegate = UploadCountingDelegate(eventLoop: embeddedEventLoop)
        let bag = RequestBag(
            request: request,
            eventLoopPreference: .delegate(on: embeddedEventLoop),
            task: .init(eventLoop: embeddedEventLoop, logger: logger),
            redirectHandler: nil,
            connectionDeadline: .now() + .seconds(30),
            idleReadTimeout: nil,
            delegate: delegate
        )

        let executor = MockRequestExecutor()
        bag.willExecuteRequest(executor)

        XCTAssertEqual(delegate.hitDidSendRequestHead, 0)
        XCTAssertEqual(delegate.hitDidSendRequest, 0)
        bag.requestHeadSent()
        XCTAssertEqual(delegate.hitDidSendRequestHead, 1)
        XCTAssertEqual(delegate.hitDidSendRequest, 0)

        bag.resumeRequestBodyStream()
        XCTAssertEqual(executor.nextBodyPart(), .body(.byteBuffer(.init(bytes: 0...3))))
        // receive a 301 response immediately.
        bag.receiveResponseHead(.init(version: .http1_1, status: .movedPermanently))
        bag.succeedRequest(.init())

        // if we now write our second part of the response this should fail the backpressure promise
        writeSecondPartPromise.succeed(())

        XCTAssertEqual(delegate.receivedHead?.status, .movedPermanently)
        XCTAssertNoThrow(try bag.task.futureResult.wait())
    }
}

class MockRequestExecutor: HTTPRequestExecutor {
    enum RequestParts: Equatable {
        case body(IOData)
        case endOfStream
    }

    let pauseRequestBodyPartStreamAfterASingleWrite: Bool

    private(set) var requestBodyParts = CircularBuffer<RequestParts>()
    private(set) var isCancelled: Bool = false
    private(set) var signalledDemandForResponseBody: Bool = false

    init(pauseRequestBodyPartStreamAfterASingleWrite: Bool = false) {
        self.pauseRequestBodyPartStreamAfterASingleWrite = pauseRequestBodyPartStreamAfterASingleWrite
    }

    func nextBodyPart() -> RequestParts? {
        guard !self.requestBodyParts.isEmpty else { return nil }
        return self.requestBodyParts.removeFirst()
    }

    func resetDemandSignal() {
        self.signalledDemandForResponseBody = false
    }

    // this should always be called twice. When we receive the first call, the next call to produce
    // data is already scheduled. If we call pause here, once, after the second call new subsequent
    // calls should not be scheduled.
    func writeRequestBodyPart(_ part: IOData, request: HTTPExecutingRequest) {
        if self.requestBodyParts.isEmpty, self.pauseRequestBodyPartStreamAfterASingleWrite {
            request.pauseRequestBodyStream()
        }
        self.requestBodyParts.append(.body(part))
    }

    func finishRequestBodyStream(_: HTTPExecutingRequest) {
        self.requestBodyParts.append(.endOfStream)
    }

    func demandResponseBodyStream(_: HTTPExecutingRequest) {
        self.signalledDemandForResponseBody = true
    }

    func cancelRequest(_: HTTPExecutingRequest) {
        self.isCancelled = true
    }
}

class UploadCountingDelegate: HTTPClientResponseDelegate {
    typealias Response = Void

    let eventLoop: EventLoop

    private(set) var hitDidSendRequestHead = 0
    private(set) var hitDidSendRequestPart = 0
    private(set) var hitDidSendRequest = 0
    private(set) var hitDidReceiveResponse = 0
    private(set) var hitDidReceiveBodyPart = 0
    private(set) var hitDidReceiveError = 0

    private(set) var receivedHead: HTTPResponseHead?
    private(set) var lastBodyPart: ByteBuffer?
    private(set) var backpressurePromise: EventLoopPromise<Void>?
    private(set) var lastError: Error?

    init(eventLoop: EventLoop) {
        self.eventLoop = eventLoop
    }

    func didSendRequestHead(task: HTTPClient.Task<Void>, _ head: HTTPRequestHead) {
        self.hitDidSendRequestHead += 1
    }

    func didSendRequestPart(task: HTTPClient.Task<Void>, _ part: IOData) {
        self.hitDidSendRequestPart += 1
    }

    func didSendRequest(task: HTTPClient.Task<Void>) {
        self.hitDidSendRequest += 1
    }

    func didReceiveHead(task: HTTPClient.Task<Void>, _ head: HTTPResponseHead) -> EventLoopFuture<Void> {
        self.receivedHead = head
        return self.createBackpressurePromise()
    }

    func didReceiveBodyPart(task: HTTPClient.Task<Void>, _ buffer: ByteBuffer) -> EventLoopFuture<Void> {
        assert(self.backpressurePromise == nil)
        self.hitDidReceiveBodyPart += 1
        self.lastBodyPart = buffer
        return self.createBackpressurePromise()
    }

    func didFinishRequest(task: HTTPClient.Task<Void>) throws {
        self.hitDidReceiveResponse += 1
    }

    func didReceiveError(task: HTTPClient.Task<Void>, _ error: Error) {
        self.hitDidReceiveError += 1
        self.lastError = error
    }

    private func createBackpressurePromise() -> EventLoopFuture<Void> {
        assert(self.backpressurePromise == nil)
        self.backpressurePromise = self.eventLoop.makePromise(of: Void.self)
        return self.backpressurePromise!.futureResult.always { _ in
            self.backpressurePromise = nil
        }
    }
}

class MockTaskQueuer: HTTPRequestScheduler {
    private(set) var hitCancelCount = 0

    init() {}

    func cancelRequest(_: HTTPScheduledRequest) {
        self.hitCancelCount += 1
    }
}
