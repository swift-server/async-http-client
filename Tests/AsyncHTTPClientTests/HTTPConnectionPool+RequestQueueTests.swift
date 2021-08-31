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

class HTTPConnectionPool_RequestQueueTests: XCTestCase {
    func testCountAndIsEmptyWorks() {
        var queue = HTTPConnectionPool.RequestQueue()
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(queue.count, 0)
        let req1 = MockScheduledRequest(eventLoopPreference: .indifferent)
        let req1ID = queue.push(.init(req1))
        XCTAssertFalse(queue.isEmpty)
        XCTAssertFalse(queue.isEmpty(for: nil))
        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(queue.count(for: nil), 1)

        let req2 = MockScheduledRequest(eventLoopPreference: .indifferent)
        let req2ID = queue.push(.init(req2))
        XCTAssertEqual(queue.count, 2)

        XCTAssert(queue.popFirst()?.__testOnly_internal_value() === req1)
        XCTAssertEqual(queue.count, 1)
        XCTAssert(queue.remove(req2ID)?.__testOnly_internal_value() === req2)
        XCTAssertNil(queue.remove(req1ID))

        let eventLoop = EmbeddedEventLoop()

        XCTAssertTrue(queue.isEmpty(for: eventLoop))
        XCTAssertEqual(queue.count(for: eventLoop), 0)
        let req3 = MockScheduledRequest(eventLoopPreference: .delegateAndChannel(on: eventLoop))
        let req3ID = queue.push(.init(req3))
        XCTAssertFalse(queue.isEmpty(for: eventLoop))
        XCTAssertEqual(queue.count(for: eventLoop), 1)
        XCTAssert(queue.popFirst(for: eventLoop)?.__testOnly_internal_value() === req3)
        XCTAssertNil(queue.remove(req3ID))

        let req4 = MockScheduledRequest(eventLoopPreference: .delegateAndChannel(on: eventLoop))
        let req4ID = queue.push(.init(req4))
        XCTAssert(queue.remove(req4ID)?.__testOnly_internal_value() === req4)

        let req5 = MockScheduledRequest(eventLoopPreference: .indifferent)
        queue.push(.init(req5))
        let req6 = MockScheduledRequest(eventLoopPreference: .delegateAndChannel(on: eventLoop))
        queue.push(.init(req6))
        let all = queue.removeAll()
        let testSet = all.map { $0.__testOnly_internal_value() }
        XCTAssertEqual(testSet.count, 2)
        XCTAssertTrue(testSet.contains(where: { $0 === req5 }))
        XCTAssertTrue(testSet.contains(where: { $0 === req6 }))
        XCTAssertFalse(testSet.contains(where: { $0 === req4 }))
    }
}

private class MockScheduledRequest: HTTPSchedulableRequest {
    init(eventLoopPreference: HTTPClient.EventLoopPreference) {
        self.eventLoopPreference = eventLoopPreference
    }

    var logger: Logger { preconditionFailure("Unimplemented") }
    var connectionDeadline: NIODeadline { preconditionFailure("Unimplemented") }
    let eventLoopPreference: HTTPClient.EventLoopPreference

    func requestWasQueued(_: HTTPRequestScheduler) {
        preconditionFailure("Unimplemented")
    }

    func fail(_: Error) {
        preconditionFailure("Unimplemented")
    }

    // MARK: HTTPExecutableRequest

    var requestHead: HTTPRequestHead { preconditionFailure("Unimplemented") }
    var requestFramingMetadata: RequestFramingMetadata { preconditionFailure("Unimplemented") }
    var idleReadTimeout: TimeAmount? { preconditionFailure("Unimplemented") }

    func willExecuteRequest(_: HTTPRequestExecutor) {
        preconditionFailure("Unimplemented")
    }

    func requestHeadSent() {
        preconditionFailure("Unimplemented")
    }

    func resumeRequestBodyStream() {
        preconditionFailure("Unimplemented")
    }

    func pauseRequestBodyStream() {
        preconditionFailure("Unimplemented")
    }

    func receiveResponseHead(_: HTTPResponseHead) {
        preconditionFailure("Unimplemented")
    }

    func receiveResponseBodyParts(_: CircularBuffer<ByteBuffer>) {
        preconditionFailure("Unimplemented")
    }

    func succeedRequest(_: CircularBuffer<ByteBuffer>?) {
        preconditionFailure("Unimplemented")
    }
}
