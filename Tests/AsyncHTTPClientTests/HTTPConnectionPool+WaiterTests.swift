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
import XCTest

class HTTPConnectionPool_WaiterTests: XCTestCase {
    func testCanBeRunIfEventLoopIsSpecified() {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 2)

        let theRightEL = eventLoopGroup.next()
        let theFalseEL = eventLoopGroup.next()

        let waiter = HTTPConnectionPool.Waiter(request: MockScheduledRequest(), eventLoopRequirement: theRightEL)

        XCTAssertTrue(waiter.canBeRun(on: theRightEL))
        XCTAssertFalse(waiter.canBeRun(on: theFalseEL))
    }

    func testCanBeRunIfNoEventLoopIsSpecified() {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 2)

        let waiter = HTTPConnectionPool.Waiter(request: MockScheduledRequest(), eventLoopRequirement: nil)

        for el in eventLoopGroup.makeIterator() {
            XCTAssertTrue(waiter.canBeRun(on: el))
        }
    }
}

private class MockScheduledRequest: HTTPScheduledRequest {
    init() {}

    var logger: Logger { preconditionFailure("Unimplemented") }
    var connectionDeadline: NIODeadline { preconditionFailure("Unimplemented") }
    var eventLoopPreference: HTTPClient.EventLoopPreference { preconditionFailure("Unimplemented") }

    func requestWasQueued(_: HTTPRequestScheduler) {
        preconditionFailure("Unimplemented")
    }

    func fail(_: Error) {
        preconditionFailure("Unimplemented")
    }
}
