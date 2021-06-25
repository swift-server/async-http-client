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
import NIO
import NIOSSL
import NIOTLS
import XCTest

class TLSEventsHandlerTests: XCTestCase {
    func testHandlerHappyPath() {
        let tlsEventsHandler = TLSEventsHandler()
        XCTAssertNil(tlsEventsHandler.tlsEstablishedFuture)
        let embedded = EmbeddedChannel(handlers: [tlsEventsHandler])
        XCTAssertNotNil(tlsEventsHandler.tlsEstablishedFuture)

        embedded.pipeline.fireUserInboundEventTriggered(TLSUserEvent.handshakeCompleted(negotiatedProtocol: "abcd1234"))
        XCTAssertEqual(try tlsEventsHandler.tlsEstablishedFuture.wait(), "abcd1234")
    }

    func testHandlerFailsFutureWhenRemovedWithoutEvent() {
        let tlsEventsHandler = TLSEventsHandler()
        XCTAssertNil(tlsEventsHandler.tlsEstablishedFuture)
        let embedded = EmbeddedChannel(handlers: [tlsEventsHandler])
        XCTAssertNotNil(tlsEventsHandler.tlsEstablishedFuture)

        XCTAssertNoThrow(try embedded.pipeline.removeHandler(tlsEventsHandler).wait())
        XCTAssertThrowsError(try tlsEventsHandler.tlsEstablishedFuture.wait())
    }

    func testHandlerFailsFutureWhenHandshakeFails() {
        let tlsEventsHandler = TLSEventsHandler()
        XCTAssertNil(tlsEventsHandler.tlsEstablishedFuture)
        let embedded = EmbeddedChannel(handlers: [tlsEventsHandler])
        XCTAssertNotNil(tlsEventsHandler.tlsEstablishedFuture)

        embedded.pipeline.fireErrorCaught(NIOSSLError.handshakeFailed(BoringSSLError.wantConnect))
        XCTAssertThrowsError(try tlsEventsHandler.tlsEstablishedFuture.wait()) {
            XCTAssertEqual($0 as? NIOSSLError, .handshakeFailed(BoringSSLError.wantConnect))
        }
    }

    func testHandlerIgnoresShutdownCompletedEvent() {
        let tlsEventsHandler = TLSEventsHandler()
        XCTAssertNil(tlsEventsHandler.tlsEstablishedFuture)
        let embedded = EmbeddedChannel(handlers: [tlsEventsHandler])
        XCTAssertNotNil(tlsEventsHandler.tlsEstablishedFuture)

        // ignore event
        embedded.pipeline.fireUserInboundEventTriggered(TLSUserEvent.shutdownCompleted)

        embedded.pipeline.fireUserInboundEventTriggered(TLSUserEvent.handshakeCompleted(negotiatedProtocol: "alpn"))
        XCTAssertEqual(try tlsEventsHandler.tlsEstablishedFuture.wait(), "alpn")
    }
}
