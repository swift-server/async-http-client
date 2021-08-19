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
import NIOCore
import NIOHTTP1
import XCTest

class HTTP1ConnectionStateMachineTests: XCTestCase {
    func testPOSTRequestWithWriteAndReadBackpressure() {
        var state = HTTP1ConnectionStateMachine()
        XCTAssertEqual(state.channelActive(isWritable: false), .fireChannelActive)

        let requestHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/", headers: HTTPHeaders([("content-length", "4")]))
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(4))
        XCTAssertEqual(state.runNewRequest(head: requestHead, metadata: metadata), .wait)
        XCTAssertEqual(state.writabilityChanged(writable: true), .sendRequestHead(requestHead, startBody: true))

        let part0 = IOData.byteBuffer(ByteBuffer(bytes: [0]))
        let part1 = IOData.byteBuffer(ByteBuffer(bytes: [1]))
        let part2 = IOData.byteBuffer(ByteBuffer(bytes: [2]))
        let part3 = IOData.byteBuffer(ByteBuffer(bytes: [3]))
        XCTAssertEqual(state.requestStreamPartReceived(part0), .sendBodyPart(part0))
        XCTAssertEqual(state.requestStreamPartReceived(part1), .sendBodyPart(part1))

        // oh the channel reports... we should slow down producing...
        XCTAssertEqual(state.writabilityChanged(writable: false), .pauseRequestBodyStream)

        // but we issued a .produceMoreRequestBodyData before... Thus, we must accept more produced
        // data
        XCTAssertEqual(state.requestStreamPartReceived(part2), .sendBodyPart(part2))
        // however when we have put the data on the channel, we should not issue further
        // .produceMoreRequestBodyData events

        // once we receive a writable event again, we can allow the producer to produce more data
        XCTAssertEqual(state.writabilityChanged(writable: true), .resumeRequestBodyStream)
        XCTAssertEqual(state.requestStreamPartReceived(part3), .sendBodyPart(part3))
        XCTAssertEqual(state.requestStreamFinished(), .sendRequestEnd)

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok)
        XCTAssertEqual(state.channelRead(.head(responseHead)), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        let responseBody = ByteBuffer(bytes: [1, 2, 3, 4])
        XCTAssertEqual(state.channelRead(.body(responseBody)), .wait)
        XCTAssertEqual(state.channelRead(.end(nil)), .succeedRequest(.informConnectionIsIdle, .init([responseBody])))
        XCTAssertEqual(state.channelReadComplete(), .wait)
    }

    func testResponseReadingWithBackpressure() {
        var state = HTTP1ConnectionStateMachine()
        XCTAssertEqual(state.channelActive(isWritable: true), .fireChannelActive)

        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .none)
        XCTAssertEqual(state.runNewRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: false))

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok, headers: HTTPHeaders([("content-length", "12")]))
        XCTAssertEqual(state.channelRead(.head(responseHead)), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        let part0 = ByteBuffer(bytes: 0...3)
        let part1 = ByteBuffer(bytes: 4...7)
        let part2 = ByteBuffer(bytes: 8...11)
        XCTAssertEqual(state.channelRead(.body(part0)), .wait)
        XCTAssertEqual(state.channelRead(.body(part1)), .wait)
        XCTAssertEqual(state.channelReadComplete(), .forwardResponseBodyParts(.init([part0, part1])))
        XCTAssertEqual(state.read(), .wait)
        XCTAssertEqual(state.read(), .wait, "Expected to be able to consume a second read event")
        XCTAssertEqual(state.demandMoreResponseBodyParts(), .read)
        XCTAssertEqual(state.channelRead(.body(part2)), .wait)
        XCTAssertEqual(state.channelReadComplete(), .forwardResponseBodyParts(.init([part2])))
        XCTAssertEqual(state.demandMoreResponseBodyParts(), .wait)
        XCTAssertEqual(state.read(), .read)
        XCTAssertEqual(state.channelRead(.end(nil)), .succeedRequest(.informConnectionIsIdle, .init()))
        XCTAssertEqual(state.channelReadComplete(), .wait)
        XCTAssertEqual(state.read(), .read)
    }

    func testAConnectionCloseHeaderInTheRequestLeadsToConnectionCloseAfterRequest() {
        var state = HTTP1ConnectionStateMachine()
        XCTAssertEqual(state.channelActive(isWritable: true), .fireChannelActive)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/", headers: ["connection": "close"])
        let metadata = RequestFramingMetadata(connectionClose: true, body: .none)
        XCTAssertEqual(state.runNewRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: false))

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok)
        XCTAssertEqual(state.channelRead(.head(responseHead)), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        let responseBody = ByteBuffer(bytes: [1, 2, 3, 4])
        XCTAssertEqual(state.channelRead(.body(responseBody)), .wait)
        XCTAssertEqual(state.channelRead(.end(nil)), .succeedRequest(.close, .init([responseBody])))
    }

    func testAConnectionCloseHeaderInTheResponseLeadsToConnectionCloseAfterRequest() {
        var state = HTTP1ConnectionStateMachine()
        XCTAssertEqual(state.channelActive(isWritable: false), .fireChannelActive)
        XCTAssertEqual(state.writabilityChanged(writable: true), .wait)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .none)
        XCTAssertEqual(state.runNewRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: false))

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok, headers: ["connection": "close"])
        XCTAssertEqual(state.channelRead(.head(responseHead)), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        let responseBody = ByteBuffer(bytes: [1, 2, 3, 4])
        XCTAssertEqual(state.channelRead(.body(responseBody)), .wait)
        XCTAssertEqual(state.channelRead(.end(nil)), .succeedRequest(.close, .init([responseBody])))
    }

    func testNIOTriggersChannelActiveTwice() {
        var state = HTTP1ConnectionStateMachine()
        XCTAssertEqual(state.channelActive(isWritable: true), .fireChannelActive)
        XCTAssertEqual(state.channelActive(isWritable: true), .wait)
    }

    func testIdleConnectionBecomesInactive() {
        var state = HTTP1ConnectionStateMachine()
        XCTAssertEqual(state.channelActive(isWritable: true), .fireChannelActive)
        XCTAssertEqual(state.channelInactive(), .fireChannelInactive)
        XCTAssertEqual(state.channelInactive(), .wait)
    }

    func testConnectionGoesAwayWhileInRequest() {
        var state = HTTP1ConnectionStateMachine()
        XCTAssertEqual(state.channelActive(isWritable: true), .fireChannelActive)

        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .none)
        XCTAssertEqual(state.runNewRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: false))

        XCTAssertEqual(state.channelInactive(), .failRequest(HTTPClientError.remoteConnectionClosed, .none))
    }

    func testRequestWasCancelledWhileUploadingData() {
        var state = HTTP1ConnectionStateMachine()
        XCTAssertEqual(state.channelActive(isWritable: false), .fireChannelActive)

        let requestHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/", headers: HTTPHeaders([("content-length", "4")]))
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(4))
        XCTAssertEqual(state.runNewRequest(head: requestHead, metadata: metadata), .wait)
        XCTAssertEqual(state.writabilityChanged(writable: true), .sendRequestHead(requestHead, startBody: true))

        let part0 = IOData.byteBuffer(ByteBuffer(bytes: [0]))
        let part1 = IOData.byteBuffer(ByteBuffer(bytes: [1]))
        XCTAssertEqual(state.requestStreamPartReceived(part0), .sendBodyPart(part0))
        XCTAssertEqual(state.requestStreamPartReceived(part1), .sendBodyPart(part1))
        XCTAssertEqual(state.requestCancelled(closeConnection: false), .failRequest(HTTPClientError.cancelled, .close))
    }

    func testCancelRequestIsIgnoredWhenConnectionIsIdle() {
        var state = HTTP1ConnectionStateMachine()
        XCTAssertEqual(state.channelActive(isWritable: true), .fireChannelActive)
        XCTAssertEqual(state.requestCancelled(closeConnection: false), .wait, "Should be ignored.")
        XCTAssertEqual(state.requestCancelled(closeConnection: true), .close, "Should lead to connection closure.")
        XCTAssertEqual(state.requestCancelled(closeConnection: true), .wait, "Should be ignored. Connection is already closing")
        XCTAssertEqual(state.channelInactive(), .fireChannelInactive)
        XCTAssertEqual(state.requestCancelled(closeConnection: true), .wait, "Should be ignored. Connection is already closed")
    }

    func testReadsAreForwardedIfConnectionIsClosing() {
        var state = HTTP1ConnectionStateMachine()
        XCTAssertEqual(state.channelActive(isWritable: true), .fireChannelActive)
        XCTAssertEqual(state.requestCancelled(closeConnection: true), .close)
        XCTAssertEqual(state.read(), .read)
        XCTAssertEqual(state.channelInactive(), .fireChannelInactive)
        XCTAssertEqual(state.read(), .read)
    }

    func testChannelReadsAreIgnoredIfConnectionIsClosing() {
        var state = HTTP1ConnectionStateMachine()
        XCTAssertEqual(state.channelActive(isWritable: true), .fireChannelActive)
        XCTAssertEqual(state.requestCancelled(closeConnection: true), .close)
        XCTAssertEqual(state.channelRead(.end(nil)), .wait)
        XCTAssertEqual(state.channelReadComplete(), .wait)
        XCTAssertEqual(state.channelInactive(), .fireChannelInactive)
        XCTAssertEqual(state.channelRead(.end(nil)), .wait)
    }

    func testRequestIsCancelledWhileWaitingForWritable() {
        var state = HTTP1ConnectionStateMachine()
        XCTAssertEqual(state.channelActive(isWritable: false), .fireChannelActive)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/", headers: HTTPHeaders([("content-length", "4")]))
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(4))
        XCTAssertEqual(state.runNewRequest(head: requestHead, metadata: metadata), .wait)
        XCTAssertEqual(state.requestCancelled(closeConnection: false), .failRequest(HTTPClientError.cancelled, .informConnectionIsIdle))
    }
}

extension HTTP1ConnectionStateMachine.Action: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.fireChannelActive, .fireChannelActive):
            return true

        case (.fireChannelInactive, .fireChannelInactive):
            return true

        case (.sendRequestHead(let lhsHead, let lhsStartBody), .sendRequestHead(let rhsHead, let rhsStartBody)):
            return lhsHead == rhsHead && lhsStartBody == rhsStartBody

        case (.sendBodyPart(let lhsData), .sendBodyPart(let rhsData)):
            return lhsData == rhsData

        case (.sendRequestEnd, .sendRequestEnd):
            return true

        case (.pauseRequestBodyStream, .pauseRequestBodyStream):
            return true
        case (.resumeRequestBodyStream, .resumeRequestBodyStream):
            return true

        case (.forwardResponseHead(let lhsHead, let lhsPauseRequestBodyStream), .forwardResponseHead(let rhsHead, let rhsPauseRequestBodyStream)):
            return lhsHead == rhsHead && lhsPauseRequestBodyStream == rhsPauseRequestBodyStream

        case (.forwardResponseBodyParts(let lhsData), .forwardResponseBodyParts(let rhsData)):
            return lhsData == rhsData

        case (.succeedRequest(let lhsFinalAction, let lhsFinalBuffer), .succeedRequest(let rhsFinalAction, let rhsFinalBuffer)):
            return lhsFinalAction == rhsFinalAction && lhsFinalBuffer == rhsFinalBuffer

        case (.failRequest(_, let lhsFinalAction), .failRequest(_, let rhsFinalAction)):
            return lhsFinalAction == rhsFinalAction

        case (.read, .read):
            return true

        case (.close, .close):
            return true

        case (.wait, .wait):
            return true

        default:
            return false
        }
    }
}
