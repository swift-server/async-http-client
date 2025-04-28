//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2023 Apple Inc. and the AsyncHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if canImport(Network)
@testable import AsyncHTTPClient
import Network
import NIOCore
import NIOConcurrencyHelpers
import NIOEmbedded
import NIOSSL
import NIOTransportServices
import XCTest

@available(macOS 10.14, iOS 12.0, tvOS 12.0, watchOS 5.0, *)
class NWWaitingHandlerTests: XCTestCase {
    final class MockRequester: HTTPConnectionRequester {
        private struct State: Sendable {
            var waitingForConnectivityCalled = false
            var connectionID: AsyncHTTPClient.HTTPConnectionPool.Connection.ID?
            var transientError: NWError?
        }

        private let state = NIOLockedValueBox(State())

        var waitingForConnectivityCalled: Bool {
            self.state.withLockedValue { $0.waitingForConnectivityCalled }
        }

        var connectionID: AsyncHTTPClient.HTTPConnectionPool.Connection.ID? {
            self.state.withLockedValue { $0.connectionID }
        }

        var transientError: NWError? {
            self.state.withLockedValue {
                $0.transientError
            }
        }

        func http1ConnectionCreated(_: AsyncHTTPClient.HTTP1Connection.SendableView) {}

        func http2ConnectionCreated(_: AsyncHTTPClient.HTTP2Connection.SendableView, maximumStreams: Int) {}

        func failedToCreateHTTPConnection(_: AsyncHTTPClient.HTTPConnectionPool.Connection.ID, error: Error) {}

        func waitingForConnectivity(_ connectionID: AsyncHTTPClient.HTTPConnectionPool.Connection.ID, error: Error) {
            self.state.withLockedValue {
                $0.waitingForConnectivityCalled = true
                $0.connectionID = connectionID
                $0.transientError = error as? NWError
            }
        }
    }

    func testWaitingHandlerInvokesWaitingForConnectivity() {
        let requester = MockRequester()
        let connectionID: AsyncHTTPClient.HTTPConnectionPool.Connection.ID = 1
        let waitingEventHandler = NWWaitingHandler(requester: requester, connectionID: connectionID)
        let embedded = EmbeddedChannel(handlers: [waitingEventHandler])

        embedded.pipeline.fireUserInboundEventTriggered(
            NIOTSNetworkEvents.WaitingForConnectivity(transientError: .dns(1))
        )

        XCTAssertTrue(
            requester.waitingForConnectivityCalled,
            "Expected the handler to invoke .waitingForConnectivity on the requester"
        )
        XCTAssertEqual(requester.connectionID, connectionID, "Expected the handler to pass connectionID to requester")
        XCTAssertEqual(requester.transientError, NWError.dns(1))
    }

    func testWaitingHandlerDoesNotInvokeWaitingForConnectionOnUnrelatedErrors() {
        let requester = MockRequester()
        let waitingEventHandler = NWWaitingHandler(requester: requester, connectionID: 1)
        let embedded = EmbeddedChannel(handlers: [waitingEventHandler])
        embedded.pipeline.fireUserInboundEventTriggered(NIOTSNetworkEvents.BetterPathAvailable())

        XCTAssertFalse(
            requester.waitingForConnectivityCalled,
            "Should not call .waitingForConnectivity on unrelated events"
        )
    }

    func testWaitingHandlerPassesTheEventDownTheContext() {
        let requester = MockRequester()
        let waitingEventHandler = NWWaitingHandler(requester: requester, connectionID: 1)
        let tlsEventsHandler = TLSEventsHandler(deadline: nil)
        let embedded = EmbeddedChannel(handlers: [waitingEventHandler, tlsEventsHandler])

        embedded.pipeline.fireErrorCaught(NIOSSLError.handshakeFailed(BoringSSLError.wantConnect))
        XCTAssertThrowsError(try XCTUnwrap(tlsEventsHandler.tlsEstablishedFuture).wait()) {
            XCTAssertEqualTypeAndValue($0, NIOSSLError.handshakeFailed(BoringSSLError.wantConnect))
        }
    }
}

#endif
