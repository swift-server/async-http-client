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
import NIOSSL
import NIOTLS
import XCTest

@testable import AsyncHTTPClient

class TLSEventsHandlerTests: XCTestCase {
    func testHandlerHappyPath() {
        let tlsEventsHandler = TLSEventsHandler(deadline: nil)
        XCTAssertNil(tlsEventsHandler.tlsEstablishedFuture)
        let embedded = EmbeddedChannel(handlers: [tlsEventsHandler])
        XCTAssertNotNil(tlsEventsHandler.tlsEstablishedFuture)

        XCTAssertNoThrow(try embedded.connect(to: .makeAddressResolvingHost("localhost", port: 0)).wait())

        embedded.pipeline.fireUserInboundEventTriggered(TLSUserEvent.handshakeCompleted(negotiatedProtocol: "abcd1234"))
        XCTAssertEqual(try XCTUnwrap(tlsEventsHandler.tlsEstablishedFuture).wait(), "abcd1234")
    }

    func testHandlerFailsFutureWhenRemovedWithoutEvent() {
        let tlsEventsHandler = TLSEventsHandler(deadline: nil)
        XCTAssertNil(tlsEventsHandler.tlsEstablishedFuture)
        let embedded = EmbeddedChannel(handlers: [tlsEventsHandler])
        XCTAssertNotNil(tlsEventsHandler.tlsEstablishedFuture)

        XCTAssertNoThrow(try embedded.pipeline.syncOperations.removeHandler(tlsEventsHandler).wait())
        XCTAssertThrowsError(try XCTUnwrap(tlsEventsHandler.tlsEstablishedFuture).wait())
    }

    func testHandlerFailsFutureWhenHandshakeFails() {
        let tlsEventsHandler = TLSEventsHandler(deadline: nil)
        XCTAssertNil(tlsEventsHandler.tlsEstablishedFuture)
        let embedded = EmbeddedChannel(handlers: [tlsEventsHandler])
        XCTAssertNotNil(tlsEventsHandler.tlsEstablishedFuture)

        embedded.pipeline.fireErrorCaught(NIOSSLError.handshakeFailed(BoringSSLError.wantConnect))
        XCTAssertThrowsError(try XCTUnwrap(tlsEventsHandler.tlsEstablishedFuture).wait()) {
            XCTAssertEqual($0 as? NIOSSLError, .handshakeFailed(BoringSSLError.wantConnect))
        }
    }

    func testHandlerIgnoresShutdownCompletedEvent() {
        let tlsEventsHandler = TLSEventsHandler(deadline: nil)
        XCTAssertNil(tlsEventsHandler.tlsEstablishedFuture)
        let embedded = EmbeddedChannel(handlers: [tlsEventsHandler])
        XCTAssertNotNil(tlsEventsHandler.tlsEstablishedFuture)

        XCTAssertNoThrow(try embedded.connect(to: .makeAddressResolvingHost("localhost", port: 0)).wait())

        // ignore event
        embedded.pipeline.fireUserInboundEventTriggered(TLSUserEvent.shutdownCompleted)

        embedded.pipeline.fireUserInboundEventTriggered(TLSUserEvent.handshakeCompleted(negotiatedProtocol: "alpn"))
        XCTAssertEqual(try XCTUnwrap(tlsEventsHandler.tlsEstablishedFuture).wait(), "alpn")
    }
}
