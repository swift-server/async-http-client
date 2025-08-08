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

import NIOCore
import NIOEmbedded
import NIOSOCKS
import XCTest

@testable import AsyncHTTPClient

class SOCKSEventsHandlerTests: XCTestCase {
    func testHandlerHappyPath() {
        let socksEventsHandler = SOCKSEventsHandler(deadline: .now() + .seconds(10))
        XCTAssertNil(socksEventsHandler.socksEstablishedFuture)
        let embedded = EmbeddedChannel(handlers: [socksEventsHandler])
        XCTAssertNotNil(socksEventsHandler.socksEstablishedFuture)

        XCTAssertNoThrow(try embedded.connect(to: .makeAddressResolvingHost("localhost", port: 0)).wait())

        embedded.pipeline.fireUserInboundEventTriggered(SOCKSProxyEstablishedEvent())
        XCTAssertNoThrow(try XCTUnwrap(socksEventsHandler.socksEstablishedFuture).wait())
    }

    func testHandlerFailsFutureWhenRemovedWithoutEvent() {
        let socksEventsHandler = SOCKSEventsHandler(deadline: .now() + .seconds(10))
        XCTAssertNil(socksEventsHandler.socksEstablishedFuture)
        let embedded = EmbeddedChannel(handlers: [socksEventsHandler])
        XCTAssertNotNil(socksEventsHandler.socksEstablishedFuture)

        XCTAssertNoThrow(try embedded.pipeline.syncOperations.removeHandler(socksEventsHandler).wait())
        XCTAssertThrowsError(try XCTUnwrap(socksEventsHandler.socksEstablishedFuture).wait())
    }

    func testHandlerFailsFutureWhenHandshakeFails() {
        let socksEventsHandler = SOCKSEventsHandler(deadline: .now() + .seconds(10))
        XCTAssertNil(socksEventsHandler.socksEstablishedFuture)
        let embedded = EmbeddedChannel(handlers: [socksEventsHandler])
        XCTAssertNotNil(socksEventsHandler.socksEstablishedFuture)

        let error = SOCKSError.InvalidReservedByte(actual: 19)
        embedded.pipeline.fireErrorCaught(error)
        XCTAssertThrowsError(try XCTUnwrap(socksEventsHandler.socksEstablishedFuture).wait()) {
            XCTAssertEqual($0 as? SOCKSError.InvalidReservedByte, error)
        }
    }

    func testHandlerClosesConnectionIfHandshakeTimesout() {
        //  .uptimeNanoseconds(0) => .now() for EmbeddedEventLoops
        let socksEventsHandler = SOCKSEventsHandler(deadline: .uptimeNanoseconds(0) + .milliseconds(10))
        XCTAssertNil(socksEventsHandler.socksEstablishedFuture)
        let embedded = EmbeddedChannel(handlers: [socksEventsHandler])
        XCTAssertNotNil(socksEventsHandler.socksEstablishedFuture)

        XCTAssertNoThrow(try embedded.connect(to: .makeAddressResolvingHost("localhost", port: 0)).wait())

        embedded.embeddedEventLoop.advanceTime(by: .milliseconds(20))

        XCTAssertThrowsError(try XCTUnwrap(socksEventsHandler.socksEstablishedFuture).wait()) {
            XCTAssertEqual($0 as? HTTPClientError, .socksHandshakeTimeout)
        }
        XCTAssertFalse(embedded.isActive, "The timeout shall close the connection")
    }

    func testHandlerWorksIfDeadlineIsInPast() {
        //  .uptimeNanoseconds(0) => .now() for EmbeddedEventLoops
        let socksEventsHandler = SOCKSEventsHandler(deadline: .uptimeNanoseconds(0))
        XCTAssertNil(socksEventsHandler.socksEstablishedFuture)
        let embedded = EmbeddedChannel(handlers: [socksEventsHandler])
        embedded.embeddedEventLoop.advanceTime(by: .milliseconds(10))

        XCTAssertNoThrow(try embedded.connect(to: .makeAddressResolvingHost("localhost", port: 0)).wait())

        // schedules execute only on the next tick
        embedded.embeddedEventLoop.run()
        XCTAssertThrowsError(try XCTUnwrap(socksEventsHandler.socksEstablishedFuture).wait()) {
            XCTAssertEqual($0 as? HTTPClientError, .socksHandshakeTimeout)
        }
        XCTAssertFalse(embedded.isActive, "The timeout shall close the connection")
    }
}
