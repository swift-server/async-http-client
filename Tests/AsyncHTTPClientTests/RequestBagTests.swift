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

import Atomics
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOPosix
import XCTest

@testable import AsyncHTTPClient

final class RequestBagTests: XCTestCase {
    func testWriteBackpressureWorks() {
        let embeddedEventLoop = EmbeddedEventLoop()
        defer { XCTAssertNoThrow(try embeddedEventLoop.syncShutdownGracefully()) }
        let logger = Logger(label: "test")

        struct TestState {
            var writtenBytes: Int = 0
            var writes: Int = 0
            var streamIsAllowedToWrite: Bool = false
        }

        let testState = NIOLockedValueBox(TestState())

        let bytesToSent = (3000...10000).randomElement()!
        let expectedWrites = bytesToSent / 100 + ((bytesToSent % 100 > 0) ? 1 : 0)

        let writeDonePromise = embeddedEventLoop.makePromise(of: Void.self)
        let requestBody: HTTPClient.Body = .stream(contentLength: Int64(bytesToSent)) {
            writer -> EventLoopFuture<Void> in
            @Sendable func write(donePromise: EventLoopPromise<Void>) {
                let futureWrite: EventLoopFuture<Void>? = testState.withLockedValue { state in
                    XCTAssertTrue(state.streamIsAllowedToWrite)
                    guard state.writtenBytes < bytesToSent else {
                        donePromise.succeed(())
                        return nil
                    }
                    let byteCount = min(bytesToSent - state.writtenBytes, 100)
                    let buffer = ByteBuffer(bytes: [UInt8](repeating: 1, count: byteCount))
                    state.writes += 1
                    return writer.write(.byteBuffer(buffer))
                }

                futureWrite?.whenSuccess { _ in
                    testState.withLockedValue { state in
                        state.writtenBytes += 100
                    }
                    write(donePromise: donePromise)
                }
            }

            write(donePromise: writeDonePromise)

            return writeDonePromise.futureResult
        }

        var maybeRequest: HTTPClient.Request?
        XCTAssertNoThrow(
            maybeRequest = try HTTPClient.Request(url: "https://swift.org", method: .POST, body: requestBody)
        )
        guard let request = maybeRequest else { return XCTFail("Expected to have a request") }
        let delegate = UploadCountingDelegate(eventLoop: embeddedEventLoop)

        var maybeRequestBag: RequestBag<UploadCountingDelegate>?
        XCTAssertNoThrow(
            maybeRequestBag = try RequestBag(
                request: request,
                eventLoopPreference: .delegate(on: embeddedEventLoop),
                task: .init(eventLoop: embeddedEventLoop, logger: logger),
                redirectHandler: nil,
                connectionDeadline: .now() + .seconds(30),
                requestOptions: .forTests(),
                delegate: delegate
            )
        )
        guard let bag = maybeRequestBag else { return XCTFail("Expected to be able to create a request bag.") }

        XCTAssert(bag.task.eventLoop === embeddedEventLoop)

        let executor = MockRequestExecutor(
            pauseRequestBodyPartStreamAfterASingleWrite: true,
            eventLoop: embeddedEventLoop
        )

        XCTAssertEqual(delegate.hitDidSendRequestHead, 0)
        executor.runRequest(bag)
        XCTAssertEqual(delegate.hitDidSendRequestHead, 1)

        testState.withLockedValue { $0.streamIsAllowedToWrite = true }
        bag.resumeRequestBodyStream()
        testState.withLockedValue { $0.streamIsAllowedToWrite = false }

        // after starting the body stream we should have received two writes
        var receivedBytes = 0
        for i in 0..<expectedWrites {
            XCTAssertNoThrow(
                try executor.receiveRequestBody {
                    receivedBytes += $0.readableBytes
                }
            )
            XCTAssertEqual(delegate.hitDidSendRequestPart, testState.withLockedValue { $0.writes })

            if i % 2 == 1 {
                testState.withLockedValue { $0.streamIsAllowedToWrite = true }
                executor.resumeRequestBodyStream()
                testState.withLockedValue { $0.streamIsAllowedToWrite = false }
                XCTAssertLessThanOrEqual(executor.requestBodyPartsCount, 2)
                XCTAssertEqual(delegate.hitDidSendRequestPart, testState.withLockedValue { $0.writes })
            }
        }

        XCTAssertNoThrow(try executor.receiveEndOfStream())
        XCTAssertEqual(receivedBytes, bytesToSent, "We have sent all request bytes...")

        XCTAssertTrue(delegate.history.isEmpty)
        XCTAssertNil(delegate.receivedHead, "Expected not to have a response head, before `receiveResponseHead`")
        let responseHead = HTTPResponseHead(
            version: .http1_1,
            status: .ok,
            headers: .init([
                ("Transfer-Encoding", "chunked")
            ])
        )
        XCTAssertFalse(executor.signalledDemandForResponseBody)
        bag.receiveResponseHead(responseHead)
        XCTAssertEqual(responseHead, delegate.receivedHead)
        XCTAssertNoThrow(try XCTUnwrap(delegate.backpressurePromise).succeed(()))
        XCTAssertTrue(executor.signalledDemandForResponseBody)

        XCTAssertEqual(delegate.history.map(\.request.url), [request.url])
        XCTAssertEqual(delegate.history.map(\.response), [responseHead])

        executor.resetResponseStreamDemandSignal()

        // we will receive 20 chunks with each 10 byteBuffers and 32 bytes
        let bodyPart = ByteBuffer(bytes: 0..<32)
        for i in 0..<20 {
            let chunk = CircularBuffer(repeating: bodyPart, count: 10)
            XCTAssertEqual(delegate.hitDidReceiveBodyPart, i * 10)  // 0
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

            executor.resetResponseStreamDemandSignal()
        }

        XCTAssertEqual(delegate.hitDidReceiveResponse, 0)
        bag.receiveResponseEnd(nil, trailers: nil)
        XCTAssertEqual(delegate.hitDidReceiveResponse, 1)

        XCTAssertNoThrow(try bag.task.futureResult.wait(), "The request has succeeded")
    }

    func testTaskIsFailedIfWritingFails() {
        struct TestError: Error, Equatable {}

        let embeddedEventLoop = EmbeddedEventLoop()
        defer { XCTAssertNoThrow(try embeddedEventLoop.syncShutdownGracefully()) }
        let logger = Logger(label: "test")

        let requestBody: HTTPClient.Body = .stream(contentLength: 12) { writer -> EventLoopFuture<Void> in

            writer.write(.byteBuffer(ByteBuffer(bytes: 0...3))).flatMap { _ -> EventLoopFuture<Void> in
                embeddedEventLoop.makeFailedFuture(TestError())
            }
        }

        var maybeRequest: HTTPClient.Request?
        XCTAssertNoThrow(
            maybeRequest = try HTTPClient.Request(url: "https://swift.org", method: .POST, body: requestBody)
        )
        guard let request = maybeRequest else { return XCTFail("Expected to have a request") }

        let delegate = UploadCountingDelegate(eventLoop: embeddedEventLoop)
        var maybeRequestBag: RequestBag<UploadCountingDelegate>?
        XCTAssertNoThrow(
            maybeRequestBag = try RequestBag(
                request: request,
                eventLoopPreference: .delegate(on: embeddedEventLoop),
                task: .init(eventLoop: embeddedEventLoop, logger: logger),
                redirectHandler: nil,
                connectionDeadline: .now() + .seconds(30),
                requestOptions: .forTests(),
                delegate: delegate
            )
        )
        guard let bag = maybeRequestBag else { return XCTFail("Expected to be able to create a request bag.") }
        XCTAssert(bag.task.eventLoop === embeddedEventLoop)

        let executor = MockRequestExecutor(eventLoop: embeddedEventLoop)

        XCTAssertEqual(delegate.hitDidSendRequestHead, 0)
        executor.runRequest(bag)
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
        var maybeRequestBag: RequestBag<UploadCountingDelegate>?
        XCTAssertNoThrow(
            maybeRequestBag = try RequestBag(
                request: request,
                eventLoopPreference: .delegate(on: embeddedEventLoop),
                task: .init(eventLoop: embeddedEventLoop, logger: logger),
                redirectHandler: nil,
                connectionDeadline: .now() + .seconds(30),
                requestOptions: .forTests(),
                delegate: delegate
            )
        )
        guard let bag = maybeRequestBag else { return XCTFail("Expected to be able to create a request bag.") }
        XCTAssert(bag.eventLoop === embeddedEventLoop)

        let executor = MockRequestExecutor(eventLoop: embeddedEventLoop)
        bag.fail(HTTPClientError.cancelled)

        bag.willExecuteRequest(executor)
        XCTAssertTrue(executor.isCancelled, "The request bag, should call cancel immediately on the executor")
        XCTAssertThrowsError(try bag.task.futureResult.wait()) {
            XCTAssertEqual($0 as? HTTPClientError, .cancelled)
        }
    }

    func testDeadlineExceededFailsTaskEvenIfRaceBetweenCancelingSchedulerAndRequestStart() {
        let embeddedEventLoop = EmbeddedEventLoop()
        defer { XCTAssertNoThrow(try embeddedEventLoop.syncShutdownGracefully()) }
        let logger = Logger(label: "test")

        var maybeRequest: HTTPClient.Request?
        XCTAssertNoThrow(maybeRequest = try HTTPClient.Request(url: "https://swift.org"))
        guard let request = maybeRequest else { return XCTFail("Expected to have a request") }

        let delegate = UploadCountingDelegate(eventLoop: embeddedEventLoop)
        var maybeRequestBag: RequestBag<UploadCountingDelegate>?
        XCTAssertNoThrow(
            maybeRequestBag = try RequestBag(
                request: request,
                eventLoopPreference: .delegate(on: embeddedEventLoop),
                task: .init(eventLoop: embeddedEventLoop, logger: logger),
                redirectHandler: nil,
                connectionDeadline: .now() + .seconds(30),
                requestOptions: .forTests(),
                delegate: delegate
            )
        )
        guard let bag = maybeRequestBag else { return XCTFail("Expected to be able to create a request bag.") }
        XCTAssert(bag.eventLoop === embeddedEventLoop)

        let queuer = MockTaskQueuer()
        bag.requestWasQueued(queuer)

        let executor = MockRequestExecutor(eventLoop: embeddedEventLoop)
        XCTAssertEqual(queuer.hitCancelCount, 0)
        bag.deadlineExceeded()
        XCTAssertEqual(queuer.hitCancelCount, 1)

        bag.willExecuteRequest(executor)
        XCTAssertTrue(executor.isCancelled, "The request bag, should call cancel immediately on the executor")
        XCTAssertThrowsError(try bag.task.futureResult.wait()) {
            XCTAssertEqual($0 as? HTTPClientError, .deadlineExceeded)
        }
    }

    func testCancelHasNoEffectAfterDeadlineExceededFailsTask() {
        struct MyError: Error, Equatable {}
        let embeddedEventLoop = EmbeddedEventLoop()
        defer { XCTAssertNoThrow(try embeddedEventLoop.syncShutdownGracefully()) }
        let logger = Logger(label: "test")

        var maybeRequest: HTTPClient.Request?
        XCTAssertNoThrow(maybeRequest = try HTTPClient.Request(url: "https://swift.org"))
        guard let request = maybeRequest else { return XCTFail("Expected to have a request") }

        let delegate = UploadCountingDelegate(eventLoop: embeddedEventLoop)
        var maybeRequestBag: RequestBag<UploadCountingDelegate>?
        XCTAssertNoThrow(
            maybeRequestBag = try RequestBag(
                request: request,
                eventLoopPreference: .delegate(on: embeddedEventLoop),
                task: .init(eventLoop: embeddedEventLoop, logger: logger),
                redirectHandler: nil,
                connectionDeadline: .now() + .seconds(30),
                requestOptions: .forTests(),
                delegate: delegate
            )
        )
        guard let bag = maybeRequestBag else { return XCTFail("Expected to be able to create a request bag.") }
        XCTAssert(bag.eventLoop === embeddedEventLoop)

        let queuer = MockTaskQueuer()
        bag.requestWasQueued(queuer)

        XCTAssertEqual(queuer.hitCancelCount, 0)
        bag.deadlineExceeded()
        XCTAssertEqual(queuer.hitCancelCount, 1)
        XCTAssertEqual(delegate.hitDidReceiveError, 0)
        bag.fail(MyError())
        XCTAssertEqual(delegate.hitDidReceiveError, 1)

        bag.fail(HTTPClientError.cancelled)
        XCTAssertEqual(delegate.hitDidReceiveError, 1)

        XCTAssertThrowsError(try bag.task.futureResult.wait()) {
            XCTAssertEqualTypeAndValue($0, MyError())
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
        var maybeRequestBag: RequestBag<UploadCountingDelegate>?
        XCTAssertNoThrow(
            maybeRequestBag = try RequestBag(
                request: request,
                eventLoopPreference: .delegate(on: embeddedEventLoop),
                task: .init(eventLoop: embeddedEventLoop, logger: logger),
                redirectHandler: nil,
                connectionDeadline: .now() + .seconds(30),
                requestOptions: .forTests(),
                delegate: delegate
            )
        )
        guard let bag = maybeRequestBag else { return XCTFail("Expected to be able to create a request bag.") }
        XCTAssert(bag.eventLoop === embeddedEventLoop)

        let executor = MockRequestExecutor(eventLoop: embeddedEventLoop)

        XCTAssertFalse(executor.isCancelled)

        XCTAssertEqual(delegate.hitDidSendRequestHead, 0)
        XCTAssertEqual(delegate.hitDidSendRequest, 0)
        executor.runRequest(bag)
        XCTAssertEqual(delegate.hitDidSendRequestHead, 1)
        XCTAssertEqual(delegate.hitDidSendRequest, 1)

        bag.fail(HTTPClientError.cancelled)
        XCTAssertTrue(executor.isCancelled, "The request bag, should call cancel immediately on the executor")

        XCTAssertThrowsError(try bag.task.futureResult.timeout(after: .seconds(10)).wait()) {
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
        var maybeRequestBag: RequestBag<UploadCountingDelegate>?
        XCTAssertNoThrow(
            maybeRequestBag = try RequestBag(
                request: request,
                eventLoopPreference: .delegate(on: embeddedEventLoop),
                task: .init(eventLoop: embeddedEventLoop, logger: logger),
                redirectHandler: nil,
                connectionDeadline: .now() + .seconds(30),
                requestOptions: .forTests(),
                delegate: delegate
            )
        )
        guard let bag = maybeRequestBag else { return XCTFail("Expected to be able to create a request bag.") }

        let queuer = MockTaskQueuer()
        bag.requestWasQueued(queuer)

        XCTAssertEqual(queuer.hitCancelCount, 0)
        bag.fail(HTTPClientError.cancelled)
        XCTAssertEqual(queuer.hitCancelCount, 1)

        XCTAssertThrowsError(try bag.task.futureResult.wait()) {
            XCTAssertEqual($0 as? HTTPClientError, .cancelled)
        }
    }

    func testFailsTaskWhenTaskIsWaitingForMoreFromServer() {
        let embeddedEventLoop = EmbeddedEventLoop()
        defer { XCTAssertNoThrow(try embeddedEventLoop.syncShutdownGracefully()) }
        let logger = Logger(label: "test")

        var maybeRequest: HTTPClient.Request?
        XCTAssertNoThrow(maybeRequest = try HTTPClient.Request(url: "https://swift.org"))
        guard let request = maybeRequest else { return XCTFail("Expected to have a request") }

        let delegate = UploadCountingDelegate(eventLoop: embeddedEventLoop)
        var maybeRequestBag: RequestBag<UploadCountingDelegate>?
        XCTAssertNoThrow(
            maybeRequestBag = try RequestBag(
                request: request,
                eventLoopPreference: .delegate(on: embeddedEventLoop),
                task: .init(eventLoop: embeddedEventLoop, logger: logger),
                redirectHandler: nil,
                connectionDeadline: .now() + .seconds(30),
                requestOptions: .forTests(),
                delegate: delegate
            )
        )
        guard let bag = maybeRequestBag else { return XCTFail("Expected to be able to create a request bag.") }

        let executor = MockRequestExecutor(eventLoop: embeddedEventLoop)
        executor.runRequest(bag)
        bag.receiveResponseHead(.init(version: .http1_1, status: .ok))
        XCTAssertEqual(executor.isCancelled, false)
        bag.fail(HTTPClientError.readTimeout)
        XCTAssertEqual(executor.isCancelled, true)
        XCTAssertThrowsError(try bag.task.futureResult.wait()) {
            XCTAssertEqual($0 as? HTTPClientError, .readTimeout)
        }
    }

    func testChannelBecomingWritableDoesntCrashCancelledTask() {
        let embeddedEventLoop = EmbeddedEventLoop()
        defer { XCTAssertNoThrow(try embeddedEventLoop.syncShutdownGracefully()) }
        let logger = Logger(label: "test")

        var maybeRequest: HTTPClient.Request?
        XCTAssertNoThrow(
            maybeRequest = try HTTPClient.Request(
                url: "https://swift.org",
                body: .bytes([1, 2, 3, 4, 5])
            )
        )
        guard let request = maybeRequest else { return XCTFail("Expected to have a request") }

        let delegate = UploadCountingDelegate(eventLoop: embeddedEventLoop)
        var maybeRequestBag: RequestBag<UploadCountingDelegate>?
        XCTAssertNoThrow(
            maybeRequestBag = try RequestBag(
                request: request,
                eventLoopPreference: .delegate(on: embeddedEventLoop),
                task: .init(eventLoop: embeddedEventLoop, logger: logger),
                redirectHandler: nil,
                connectionDeadline: .now() + .seconds(30),
                requestOptions: .forTests(),
                delegate: delegate
            )
        )
        guard let bag = maybeRequestBag else { return XCTFail("Expected to be able to create a request bag.") }

        let executor = MockRequestExecutor(eventLoop: embeddedEventLoop)
        executor.runRequest(bag)

        // This simulates a race between the user cancelling the task (which invokes `RequestBag.fail(_:)`) and the
        // call to `resumeRequestBodyStream` (which comes from the `Channel` event loop and so may have to hop.
        bag.fail(HTTPClientError.cancelled)
        bag.resumeRequestBodyStream()

        XCTAssertEqual(executor.isCancelled, true)
        XCTAssertThrowsError(try bag.task.futureResult.wait()) {
            XCTAssertEqual($0 as? HTTPClientError, .cancelled)
        }
    }

    func testDidReceiveBodyPartFailedPromise() {
        let embeddedEventLoop = EmbeddedEventLoop()
        defer { XCTAssertNoThrow(try embeddedEventLoop.syncShutdownGracefully()) }
        let logger = Logger(label: "test")

        var maybeRequest: HTTPClient.Request?

        XCTAssertNoThrow(
            maybeRequest = try HTTPClient.Request(
                url: "https://swift.org",
                method: .POST,
                body: .byteBuffer(.init(bytes: [1]))
            )
        )
        guard let request = maybeRequest else { return XCTFail("Expected to have a request") }

        struct MyError: Error, Equatable {}
        final class Delegate: HTTPClientResponseDelegate {
            typealias Response = Void
            let didFinishPromise: EventLoopPromise<Void>
            init(didFinishPromise: EventLoopPromise<Void>) {
                self.didFinishPromise = didFinishPromise
            }

            func didReceiveBodyPart(task: HTTPClient.Task<Void>, _ buffer: ByteBuffer) -> EventLoopFuture<Void> {
                task.eventLoop.makeFailedFuture(MyError())
            }

            func didReceiveError(task: HTTPClient.Task<Void>, _ error: Error) {
                self.didFinishPromise.fail(error)
            }

            func didFinishRequest(task: AsyncHTTPClient.HTTPClient.Task<Void>) throws {
                XCTFail("\(#function) should not be called")
                self.didFinishPromise.succeed(())
            }
        }
        let delegate = Delegate(didFinishPromise: embeddedEventLoop.makePromise())
        var maybeRequestBag: RequestBag<Delegate>?
        XCTAssertNoThrow(
            maybeRequestBag = try RequestBag(
                request: request,
                eventLoopPreference: .delegate(on: embeddedEventLoop),
                task: .init(eventLoop: embeddedEventLoop, logger: logger),
                redirectHandler: nil,
                connectionDeadline: .now() + .seconds(30),
                requestOptions: .forTests(),
                delegate: delegate
            )
        )
        guard let bag = maybeRequestBag else { return XCTFail("Expected to be able to create a request bag.") }

        let executor = MockRequestExecutor(eventLoop: embeddedEventLoop)

        executor.runRequest(bag)

        bag.resumeRequestBodyStream()
        XCTAssertNoThrow(try executor.receiveRequestBody { XCTAssertEqual($0, ByteBuffer(bytes: [1])) })

        bag.receiveResponseHead(.init(version: .http1_1, status: .ok))

        bag.receiveResponseEnd([ByteBuffer([1])], trailers: nil)

        XCTAssertThrowsError(try delegate.didFinishPromise.futureResult.wait()) { error in
            XCTAssertEqualTypeAndValue(error, MyError())
        }
        XCTAssertThrowsError(try bag.task.futureResult.wait()) { error in
            XCTAssertEqualTypeAndValue(error, MyError())
        }
    }

    func testHTTPUploadIsCancelledEvenThoughRequestSucceeds() {
        let embeddedEventLoop = EmbeddedEventLoop()
        defer { XCTAssertNoThrow(try embeddedEventLoop.syncShutdownGracefully()) }
        let logger = Logger(label: "test")

        var maybeRequest: HTTPClient.Request?
        let writeSecondPartPromise = embeddedEventLoop.makePromise(of: Void.self)
        let firstWriteSuccess: NIOLockedValueBox<Bool> = .init(false)

        XCTAssertNoThrow(
            maybeRequest = try HTTPClient.Request(
                url: "https://swift.org",
                method: .POST,
                headers: ["content-length": "12"],
                body: .stream(contentLength: 12) { writer -> EventLoopFuture<Void> in
                    writer.write(.byteBuffer(.init(bytes: 0...3))).flatMap { _ in
                        firstWriteSuccess.withLockedValue { $0 = true }

                        return writeSecondPartPromise.futureResult
                    }.flatMap {
                        writer.write(.byteBuffer(.init(bytes: 4...7)))
                    }.always { result in
                        XCTAssertTrue(firstWriteSuccess.withLockedValue { $0 })

                        guard case .failure(let error) = result else {
                            return XCTFail("Expected the second write to fail")
                        }
                        XCTAssertEqual(error as? HTTPClientError, .requestStreamCancelled)
                    }
                }
            )
        )
        guard let request = maybeRequest else { return XCTFail("Expected to have a request") }

        let delegate = UploadCountingDelegate(eventLoop: embeddedEventLoop)
        var maybeRequestBag: RequestBag<UploadCountingDelegate>?
        XCTAssertNoThrow(
            maybeRequestBag = try RequestBag(
                request: request,
                eventLoopPreference: .delegate(on: embeddedEventLoop),
                task: .init(eventLoop: embeddedEventLoop, logger: logger),
                redirectHandler: nil,
                connectionDeadline: .now() + .seconds(30),
                requestOptions: .forTests(),
                delegate: delegate
            )
        )
        guard let bag = maybeRequestBag else { return XCTFail("Expected to be able to create a request bag.") }

        let executor = MockRequestExecutor(eventLoop: embeddedEventLoop)

        XCTAssertEqual(delegate.hitDidSendRequestHead, 0)
        XCTAssertEqual(delegate.hitDidSendRequest, 0)
        executor.runRequest(bag)
        XCTAssertEqual(delegate.hitDidSendRequestHead, 1)
        XCTAssertEqual(delegate.hitDidSendRequest, 0)

        bag.resumeRequestBodyStream()
        XCTAssertNoThrow(try executor.receiveRequestBody { XCTAssertEqual($0, ByteBuffer(bytes: 0...3)) })
        // receive a 301 response immediately.
        bag.receiveResponseHead(.init(version: .http1_1, status: .movedPermanently))
        XCTAssertNoThrow(try XCTUnwrap(delegate.backpressurePromise).succeed(()))
        bag.receiveResponseEnd([], trailers: nil)

        // if we now write our second part of the response this should fail the backpressure promise
        writeSecondPartPromise.succeed(())

        XCTAssertEqual(delegate.receivedHead?.status, .movedPermanently)
        XCTAssertNoThrow(try bag.task.futureResult.wait())
    }

    func testRaceBetweenConnectionCloseAndDemandMoreData() {
        let embeddedEventLoop = EmbeddedEventLoop()
        defer { XCTAssertNoThrow(try embeddedEventLoop.syncShutdownGracefully()) }
        let logger = Logger(label: "test")

        var maybeRequest: HTTPClient.Request?
        XCTAssertNoThrow(maybeRequest = try HTTPClient.Request(url: "https://swift.org"))
        guard let request = maybeRequest else { return XCTFail("Expected to have a request") }

        let delegate = UploadCountingDelegate(eventLoop: embeddedEventLoop)
        var maybeRequestBag: RequestBag<UploadCountingDelegate>?
        XCTAssertNoThrow(
            maybeRequestBag = try RequestBag(
                request: request,
                eventLoopPreference: .delegate(on: embeddedEventLoop),
                task: .init(eventLoop: embeddedEventLoop, logger: logger),
                redirectHandler: nil,
                connectionDeadline: .now() + .seconds(30),
                requestOptions: .forTests(),
                delegate: delegate
            )
        )
        guard let bag = maybeRequestBag else { return XCTFail("Expected to be able to create a request bag.") }

        let executor = MockRequestExecutor(eventLoop: embeddedEventLoop)
        executor.runRequest(bag)
        bag.receiveResponseHead(.init(version: .http1_1, status: .ok))
        XCTAssertFalse(executor.signalledDemandForResponseBody)
        XCTAssertNoThrow(try XCTUnwrap(delegate.backpressurePromise).succeed(()))
        XCTAssertTrue(executor.signalledDemandForResponseBody)
        executor.resetResponseStreamDemandSignal()

        // "foo" is forwarded for consumption. We expect the RequestBag to consume "foo" with the
        // delegate and call demandMoreBody afterwards.
        XCTAssertEqual(delegate.hitDidReceiveBodyPart, 0)
        bag.receiveResponseBodyParts([ByteBuffer(string: "foo")])
        XCTAssertFalse(executor.signalledDemandForResponseBody)
        XCTAssertEqual(delegate.hitDidReceiveBodyPart, 1)
        XCTAssertNoThrow(try XCTUnwrap(delegate.backpressurePromise).succeed(()))
        XCTAssertTrue(executor.signalledDemandForResponseBody)
        executor.resetResponseStreamDemandSignal()

        bag.receiveResponseBodyParts([ByteBuffer(string: "bar")])
        XCTAssertEqual(delegate.hitDidReceiveBodyPart, 2)

        // the remote closes the connection, which leads to more data and a succeed of the request
        bag.receiveResponseEnd([ByteBuffer(string: "baz")], trailers: nil)
        XCTAssertEqual(delegate.hitDidReceiveBodyPart, 2)

        XCTAssertNoThrow(try XCTUnwrap(delegate.backpressurePromise).succeed(()))
        XCTAssertEqual(delegate.hitDidReceiveBodyPart, 3)

        XCTAssertEqual(delegate.hitDidReceiveResponse, 0)
        XCTAssertNoThrow(try XCTUnwrap(delegate.backpressurePromise).succeed(()))
        XCTAssertEqual(delegate.hitDidReceiveResponse, 1)
    }

    func testRedirectWith3KBBody() {
        let embeddedEventLoop = EmbeddedEventLoop()
        defer { XCTAssertNoThrow(try embeddedEventLoop.syncShutdownGracefully()) }
        let logger = Logger(label: "test")

        var maybeRequest: HTTPClient.Request?
        XCTAssertNoThrow(maybeRequest = try HTTPClient.Request(url: "https://swift.org"))
        guard let request = maybeRequest else { return XCTFail("Expected to have a request") }

        let delegate = UploadCountingDelegate(eventLoop: embeddedEventLoop)
        var maybeRequestBag: RequestBag<UploadCountingDelegate>?
        var redirectTriggered = false
        XCTAssertNoThrow(
            maybeRequestBag = try RequestBag(
                request: request,
                eventLoopPreference: .delegate(on: embeddedEventLoop),
                task: .init(eventLoop: embeddedEventLoop, logger: logger),
                redirectHandler: .init(
                    request: request,
                    redirectState: RedirectState(
                        .follow(max: 5, allowCycles: false),
                        initialURL: request.url.absoluteString
                    )!,
                    execute: { request, _ in
                        XCTAssertEqual(request.url.absoluteString, "https://swift.org/sswg")
                        XCTAssertFalse(redirectTriggered)

                        let task = HTTPClient.Task<UploadCountingDelegate.Response>(
                            eventLoop: embeddedEventLoop,
                            logger: logger
                        )
                        task.promise.fail(HTTPClientError.cancelled)
                        redirectTriggered = true
                        return task
                    }
                ),
                connectionDeadline: .now() + .seconds(30),
                requestOptions: .forTests(),
                delegate: delegate
            )
        )
        guard let bag = maybeRequestBag else { return XCTFail("Expected to be able to create a request bag.") }

        let executor = MockRequestExecutor(eventLoop: embeddedEventLoop)
        executor.runRequest(bag)
        XCTAssertFalse(executor.signalledDemandForResponseBody)
        XCTAssertTrue(delegate.history.isEmpty)
        let responseHead = HTTPResponseHead(
            version: .http1_1,
            status: .permanentRedirect,
            headers: ["content-length": "\(3 * 1024)", "location": "https://swift.org/sswg"]
        )
        bag.receiveResponseHead(responseHead)
        XCTAssertEqual(delegate.history.map(\.request.url), [request.url])
        XCTAssertEqual(delegate.history.map(\.response), [responseHead])
        XCTAssertNil(delegate.backpressurePromise)
        XCTAssertTrue(executor.signalledDemandForResponseBody)
        executor.resetResponseStreamDemandSignal()

        // "foo" is forwarded for consumption. We expect the RequestBag to consume "foo" with the
        // delegate and call demandMoreBody afterwards.
        XCTAssertEqual(delegate.hitDidReceiveBodyPart, 0)
        XCTAssertFalse(executor.signalledDemandForResponseBody)
        bag.receiveResponseBodyParts([ByteBuffer(repeating: 0, count: 1024)])
        XCTAssertTrue(executor.signalledDemandForResponseBody)
        XCTAssertEqual(delegate.hitDidReceiveBodyPart, 0)
        XCTAssertNil(delegate.backpressurePromise)
        executor.resetResponseStreamDemandSignal()

        XCTAssertEqual(delegate.hitDidReceiveBodyPart, 0)
        XCTAssertFalse(executor.signalledDemandForResponseBody)
        bag.receiveResponseBodyParts([ByteBuffer(repeating: 1, count: 1024)])
        XCTAssertTrue(executor.signalledDemandForResponseBody)
        XCTAssertEqual(delegate.hitDidReceiveBodyPart, 0)
        XCTAssertNil(delegate.backpressurePromise)
        executor.resetResponseStreamDemandSignal()

        XCTAssertEqual(delegate.hitDidReceiveBodyPart, 0)
        XCTAssertFalse(executor.signalledDemandForResponseBody)
        bag.receiveResponseEnd([ByteBuffer(repeating: 2, count: 1024)], trailers: nil)
        XCTAssertFalse(executor.signalledDemandForResponseBody)
        XCTAssertEqual(delegate.hitDidReceiveResponse, 0)
        XCTAssertNil(delegate.backpressurePromise)
        executor.resetResponseStreamDemandSignal()

        XCTAssertTrue(redirectTriggered)
    }

    func testRedirectWith4KBBodyAnnouncedInResponseHead() {
        let embeddedEventLoop = EmbeddedEventLoop()
        defer { XCTAssertNoThrow(try embeddedEventLoop.syncShutdownGracefully()) }
        let logger = Logger(label: "test")

        var maybeRequest: HTTPClient.Request?
        XCTAssertNoThrow(maybeRequest = try HTTPClient.Request(url: "https://swift.org"))
        guard let request = maybeRequest else { return XCTFail("Expected to have a request") }

        let delegate = UploadCountingDelegate(eventLoop: embeddedEventLoop)
        var maybeRequestBag: RequestBag<UploadCountingDelegate>?
        var redirectTriggered = false
        XCTAssertNoThrow(
            maybeRequestBag = try RequestBag(
                request: request,
                eventLoopPreference: .delegate(on: embeddedEventLoop),
                task: .init(eventLoop: embeddedEventLoop, logger: logger),
                redirectHandler: .init(
                    request: request,
                    redirectState: RedirectState(
                        .follow(max: 5, allowCycles: false),
                        initialURL: request.url.absoluteString
                    )!,
                    execute: { request, _ in
                        XCTAssertEqual(request.url.absoluteString, "https://swift.org/sswg")
                        XCTAssertFalse(redirectTriggered)

                        let task = HTTPClient.Task<UploadCountingDelegate.Response>(
                            eventLoop: embeddedEventLoop,
                            logger: logger
                        )
                        task.promise.fail(HTTPClientError.cancelled)
                        redirectTriggered = true
                        return task
                    }
                ),
                connectionDeadline: .now() + .seconds(30),
                requestOptions: .forTests(),
                delegate: delegate
            )
        )
        guard let bag = maybeRequestBag else { return XCTFail("Expected to be able to create a request bag.") }

        let executor = MockRequestExecutor(eventLoop: embeddedEventLoop)
        executor.runRequest(bag)
        XCTAssertFalse(executor.signalledDemandForResponseBody)
        XCTAssertTrue(delegate.history.isEmpty)
        let responseHead = HTTPResponseHead(
            version: .http1_1,
            status: .permanentRedirect,
            headers: ["content-length": "\(4 * 1024)", "location": "https://swift.org/sswg"]
        )
        bag.receiveResponseHead(responseHead)
        XCTAssertEqual(delegate.history.map(\.request.url), [request.url])
        XCTAssertEqual(delegate.history.map(\.response), [responseHead])
        XCTAssertNil(delegate.backpressurePromise)
        XCTAssertFalse(executor.signalledDemandForResponseBody)
        XCTAssertTrue(executor.isCancelled)

        XCTAssertTrue(redirectTriggered)
    }

    func testRedirectWith4KBBodyNotAnnouncedInResponseHead() {
        let embeddedEventLoop = EmbeddedEventLoop()
        defer { XCTAssertNoThrow(try embeddedEventLoop.syncShutdownGracefully()) }
        let logger = Logger(label: "test")

        var maybeRequest: HTTPClient.Request?
        XCTAssertNoThrow(maybeRequest = try HTTPClient.Request(url: "https://swift.org"))
        guard let request = maybeRequest else { return XCTFail("Expected to have a request") }

        let delegate = UploadCountingDelegate(eventLoop: embeddedEventLoop)
        var maybeRequestBag: RequestBag<UploadCountingDelegate>?
        var redirectTriggered = false
        XCTAssertNoThrow(
            maybeRequestBag = try RequestBag(
                request: request,
                eventLoopPreference: .delegate(on: embeddedEventLoop),
                task: .init(eventLoop: embeddedEventLoop, logger: logger),
                redirectHandler: .init(
                    request: request,
                    redirectState: RedirectState(
                        .follow(max: 5, allowCycles: false),
                        initialURL: request.url.absoluteString
                    )!,
                    execute: { request, _ in
                        XCTAssertEqual(request.url.absoluteString, "https://swift.org/sswg")
                        XCTAssertFalse(redirectTriggered)

                        let task = HTTPClient.Task<UploadCountingDelegate.Response>(
                            eventLoop: embeddedEventLoop,
                            logger: logger
                        )
                        task.promise.fail(HTTPClientError.cancelled)
                        redirectTriggered = true
                        return task
                    }
                ),
                connectionDeadline: .now() + .seconds(30),
                requestOptions: .forTests(),
                delegate: delegate
            )
        )
        guard let bag = maybeRequestBag else { return XCTFail("Expected to be able to create a request bag.") }

        let executor = MockRequestExecutor(eventLoop: embeddedEventLoop)
        executor.runRequest(bag)
        XCTAssertFalse(executor.signalledDemandForResponseBody)
        XCTAssertTrue(delegate.history.isEmpty)
        let responseHead = HTTPResponseHead(
            version: .http1_1,
            status: .permanentRedirect,
            headers: ["content-length": "\(3 * 1024)", "location": "https://swift.org/sswg"]
        )
        bag.receiveResponseHead(responseHead)
        XCTAssertEqual(delegate.history.map(\.request.url), [request.url])
        XCTAssertEqual(delegate.history.map(\.response), [responseHead])
        XCTAssertNil(delegate.backpressurePromise)
        XCTAssertTrue(executor.signalledDemandForResponseBody)
        executor.resetResponseStreamDemandSignal()

        // "foo" is forwarded for consumption. We expect the RequestBag to consume "foo" with the
        // delegate and call demandMoreBody afterwards.
        XCTAssertEqual(delegate.hitDidReceiveBodyPart, 0)
        XCTAssertFalse(executor.signalledDemandForResponseBody)
        bag.receiveResponseBodyParts([ByteBuffer(repeating: 0, count: 2024)])
        XCTAssertTrue(executor.signalledDemandForResponseBody)
        XCTAssertEqual(delegate.hitDidReceiveBodyPart, 0)
        XCTAssertNil(delegate.backpressurePromise)
        executor.resetResponseStreamDemandSignal()

        XCTAssertEqual(delegate.hitDidReceiveBodyPart, 0)
        XCTAssertFalse(executor.isCancelled)
        XCTAssertFalse(executor.signalledDemandForResponseBody)
        bag.receiveResponseBodyParts([ByteBuffer(repeating: 1, count: 2024)])
        XCTAssertFalse(executor.signalledDemandForResponseBody)
        XCTAssertTrue(executor.isCancelled)
        XCTAssertEqual(delegate.hitDidReceiveBodyPart, 0)
        XCTAssertNil(delegate.backpressurePromise)
        executor.resetResponseStreamDemandSignal()

        XCTAssertTrue(redirectTriggered)
    }

    func testWeDontLeakTheRequestIfTheRequestWriterWasCapturedByAPromise() {
        final class LeakDetector: Sendable {}

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }

        let httpClient = HTTPClient(eventLoopGroupProvider: .shared(group))
        defer { XCTAssertNoThrow(try httpClient.shutdown().wait()) }

        let httpBin = HTTPBin()
        defer { XCTAssertNoThrow(try httpBin.shutdown()) }

        var leakDetector = LeakDetector()

        do {
            var maybeRequest: HTTPClient.Request?
            XCTAssertNoThrow(
                maybeRequest = try HTTPClient.Request(url: "http://localhost:\(httpBin.port)/", method: .POST)
            )
            guard var request = maybeRequest else { return XCTFail("Expected to have a request here") }

            let writerPromise = group.any().makePromise(of: HTTPClient.Body.StreamWriter.self)
            let donePromise = group.any().makePromise(of: Void.self)
            request.body = .stream { [leakDetector] writer in
                _ = leakDetector
                writerPromise.succeed(writer)
                return donePromise.futureResult
            }

            let resultFuture = httpClient.execute(request: request)
            request.body = nil
            writerPromise.futureResult.whenSuccess { writer in
                writer.write(.byteBuffer(ByteBuffer(string: "hello"))).map {
                    print("written")
                }.cascade(to: donePromise)
            }
            XCTAssertNoThrow(try donePromise.futureResult.wait())
            print("HTTP sent")

            var result: HTTPClient.Response?
            XCTAssertNoThrow(result = try resultFuture.wait())

            XCTAssertEqual(.ok, result?.status)
            let body = result?.body.map { String(buffer: $0) }
            XCTAssertNotNil(body)
            print("HTTP done")
        }
        XCTAssertTrue(isKnownUniquelyReferenced(&leakDetector))
    }
}

extension HTTPClient.Task {
    convenience init(
        eventLoop: EventLoop,
        logger: Logger
    ) {
        self.init(eventLoop: eventLoop, logger: logger, tracing: .init()) {
            preconditionFailure("thread pool not needed in tests")
        }
    }
}

final class UploadCountingDelegate: HTTPClientResponseDelegate {
    typealias Response = Void

    let eventLoop: EventLoop

    struct State: Sendable {
        var hitDidSendRequestHead = 0
        var hitDidSendRequestPart = 0
        var hitDidSendRequest = 0
        var hitDidReceiveResponse = 0
        var hitDidReceiveBodyPart = 0
        var hitDidReceiveError = 0

        var history: [(request: HTTPClient.Request, response: HTTPResponseHead)] = []
        var receivedHead: HTTPResponseHead?
        var lastBodyPart: ByteBuffer?
        var backpressurePromise: EventLoopPromise<Void>?
        var lastError: Error?
    }

    private let state: NIOLoopBoundBox<State>

    var hitDidSendRequestHead: Int { self.state.value.hitDidSendRequestHead }
    var hitDidSendRequestPart: Int { self.state.value.hitDidSendRequestPart }
    var hitDidSendRequest: Int { self.state.value.hitDidSendRequest }
    var hitDidReceiveResponse: Int { self.state.value.hitDidReceiveResponse }
    var hitDidReceiveBodyPart: Int { self.state.value.hitDidReceiveBodyPart }
    var hitDidReceiveError: Int { self.state.value.hitDidReceiveError }

    var history: [(request: HTTPClient.Request, response: HTTPResponseHead)] {
        self.state.value.history
    }
    var receivedHead: HTTPResponseHead? { self.state.value.receivedHead }
    var lastBodyPart: ByteBuffer? { self.state.value.lastBodyPart }
    var backpressurePromise: EventLoopPromise<Void>? { self.state.value.backpressurePromise }
    var lastError: Error? { self.state.value.lastError }

    init(eventLoop: EventLoop) {
        self.eventLoop = eventLoop
        self.state = .makeBoxSendingValue(State(), eventLoop: eventLoop)
    }

    func didSendRequestHead(task: HTTPClient.Task<Void>, _ head: HTTPRequestHead) {
        self.state.value.hitDidSendRequestHead += 1
    }

    func didSendRequestPart(task: HTTPClient.Task<Void>, _ part: IOData) {
        self.state.value.hitDidSendRequestPart += 1
    }

    func didSendRequest(task: HTTPClient.Task<Void>) {
        self.state.value.hitDidSendRequest += 1
    }

    func didVisitURL(task: HTTPClient.Task<Void>, _ request: HTTPClient.Request, _ head: HTTPResponseHead) {
        self.state.value.history.append((request, head))
    }

    func didReceiveHead(task: HTTPClient.Task<Void>, _ head: HTTPResponseHead) -> EventLoopFuture<Void> {
        self.state.value.receivedHead = head
        return self.createBackpressurePromise()
    }

    func didReceiveBodyPart(task: HTTPClient.Task<Void>, _ buffer: ByteBuffer) -> EventLoopFuture<Void> {
        assert(self.state.value.backpressurePromise == nil)
        self.state.value.hitDidReceiveBodyPart += 1
        self.state.value.lastBodyPart = buffer
        return self.createBackpressurePromise()
    }

    func didFinishRequest(task: HTTPClient.Task<Void>) throws {
        self.state.value.hitDidReceiveResponse += 1
    }

    func didReceiveError(task: HTTPClient.Task<Void>, _ error: Error) {
        self.state.value.hitDidReceiveError += 1
        self.state.value.lastError = error
    }

    private func createBackpressurePromise() -> EventLoopFuture<Void> {
        assert(self.state.value.backpressurePromise == nil)
        self.state.value.backpressurePromise = self.eventLoop.makePromise(of: Void.self)
        return self.state.value.backpressurePromise!.futureResult.always { _ in
            self.state.value.backpressurePromise = nil
        }
    }
}

final class MockTaskQueuer: HTTPRequestScheduler {
    private let _hitCancelCount = ManagedAtomic(0)

    var hitCancelCount: Int {
        self._hitCancelCount.load(ordering: .sequentiallyConsistent)
    }

    let onCancelRequest: (@Sendable (HTTPSchedulableRequest) -> Void)?

    init(onCancelRequest: (@Sendable (HTTPSchedulableRequest) -> Void)? = nil) {
        self.onCancelRequest = onCancelRequest
    }

    func cancelRequest(_ request: HTTPSchedulableRequest) {
        self._hitCancelCount.wrappingIncrement(ordering: .sequentiallyConsistent)
        self.onCancelRequest?(request)
    }
}

extension RequestOptions {
    static func forTests(
        idleReadTimeout: TimeAmount? = nil,
        idleWriteTimeout: TimeAmount? = nil,
        dnsOverride: [String: String] = [:]
    ) -> Self {
        RequestOptions(
            idleReadTimeout: idleReadTimeout,
            idleWriteTimeout: idleWriteTimeout,
            dnsOverride: dnsOverride
        )
    }
}
