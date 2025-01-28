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
import NIOHTTP1
import NIOHTTPCompression
import XCTest

@testable import AsyncHTTPClient

class HTTP1ConnectionStateMachineTests: XCTestCase {
    func testPOSTRequestWithWriteAndReadBackpressure() {
        var state = HTTP1ConnectionStateMachine()
        XCTAssertEqual(state.channelActive(isWritable: false), .fireChannelActive)

        let requestHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/", headers: ["content-length": "4"])
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(4))
        XCTAssertEqual(state.runNewRequest(head: requestHead, metadata: metadata), .wait)
        XCTAssertEqual(state.writabilityChanged(writable: true), .sendRequestHead(requestHead, sendEnd: false))
        XCTAssertEqual(
            state.headSent(),
            .notifyRequestHeadSendSuccessfully(resumeRequestBodyStream: true, startIdleTimer: false)
        )

        let part0 = IOData.byteBuffer(ByteBuffer(bytes: [0]))
        let part1 = IOData.byteBuffer(ByteBuffer(bytes: [1]))
        let part2 = IOData.byteBuffer(ByteBuffer(bytes: [2]))
        let part3 = IOData.byteBuffer(ByteBuffer(bytes: [3]))
        XCTAssertEqual(state.requestStreamPartReceived(part0, promise: nil), .sendBodyPart(part0, nil))
        XCTAssertEqual(state.requestStreamPartReceived(part1, promise: nil), .sendBodyPart(part1, nil))

        // oh the channel reports... we should slow down producing...
        XCTAssertEqual(state.writabilityChanged(writable: false), .pauseRequestBodyStream)

        // but we issued a .produceMoreRequestBodyData before... Thus, we must accept more produced
        // data
        XCTAssertEqual(state.requestStreamPartReceived(part2, promise: nil), .sendBodyPart(part2, nil))
        // however when we have put the data on the channel, we should not issue further
        // .produceMoreRequestBodyData events

        // once we receive a writable event again, we can allow the producer to produce more data
        XCTAssertEqual(state.writabilityChanged(writable: true), .resumeRequestBodyStream)
        XCTAssertEqual(state.requestStreamPartReceived(part3, promise: nil), .sendBodyPart(part3, nil))
        XCTAssertEqual(state.requestStreamFinished(promise: nil), .sendRequestEnd(nil))

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok)
        XCTAssertEqual(
            state.channelRead(.head(responseHead)),
            .forwardResponseHead(responseHead, pauseRequestBodyStream: false)
        )
        let responseBody = ByteBuffer(bytes: [1, 2, 3, 4])
        XCTAssertEqual(state.channelRead(.body(responseBody)), .wait)
        XCTAssertEqual(state.channelRead(.end(nil)), .succeedRequest(.informConnectionIsIdle, .init([responseBody])))
        XCTAssertEqual(state.channelReadComplete(), .wait)
    }

    func testResponseReadingWithBackpressure() {
        var state = HTTP1ConnectionStateMachine()
        XCTAssertEqual(state.channelActive(isWritable: true), .fireChannelActive)

        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(0))
        let newRequestAction = state.runNewRequest(head: requestHead, metadata: metadata)
        XCTAssertEqual(newRequestAction, .sendRequestHead(requestHead, sendEnd: true))
        XCTAssertEqual(
            state.headSent(),
            .notifyRequestHeadSendSuccessfully(resumeRequestBodyStream: false, startIdleTimer: true)
        )

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok, headers: ["content-length": "12"])
        XCTAssertEqual(
            state.channelRead(.head(responseHead)),
            .forwardResponseHead(responseHead, pauseRequestBodyStream: false)
        )
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

    func testWriteTimeoutAfterErrorDoesntCrash() {
        var state = HTTP1ConnectionStateMachine()
        XCTAssertEqual(state.channelActive(isWritable: true), .fireChannelActive)

        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(0))
        let newRequestAction = state.runNewRequest(head: requestHead, metadata: metadata)
        XCTAssertEqual(newRequestAction, .sendRequestHead(requestHead, sendEnd: true))
        XCTAssertEqual(
            state.headSent(),
            .notifyRequestHeadSendSuccessfully(resumeRequestBodyStream: false, startIdleTimer: true)
        )

        struct MyError: Error, Equatable {}
        XCTAssertEqual(state.errorHappened(MyError()), .failRequest(MyError(), .close(nil)))

        // Primarily we care that we don't crash here
        XCTAssertEqual(state.idleWriteTimeoutTriggered(), .wait)
    }

    func testAConnectionCloseHeaderInTheRequestLeadsToConnectionCloseAfterRequest() {
        var state = HTTP1ConnectionStateMachine()
        XCTAssertEqual(state.channelActive(isWritable: true), .fireChannelActive)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/", headers: ["connection": "close"])
        let metadata = RequestFramingMetadata(connectionClose: true, body: .fixedSize(0))
        let newRequestAction = state.runNewRequest(head: requestHead, metadata: metadata)
        XCTAssertEqual(newRequestAction, .sendRequestHead(requestHead, sendEnd: true))
        XCTAssertEqual(
            state.headSent(),
            .notifyRequestHeadSendSuccessfully(resumeRequestBodyStream: false, startIdleTimer: true)
        )

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok)
        XCTAssertEqual(
            state.channelRead(.head(responseHead)),
            .forwardResponseHead(responseHead, pauseRequestBodyStream: false)
        )
        let responseBody = ByteBuffer(bytes: [1, 2, 3, 4])
        XCTAssertEqual(state.channelRead(.body(responseBody)), .wait)
        XCTAssertEqual(state.channelRead(.end(nil)), .succeedRequest(.close, .init([responseBody])))
        XCTAssertEqual(state.channelInactive(), .fireChannelInactive)
    }

    func testAHTTP1_0ResponseWithoutKeepAliveHeaderLeadsToConnectionCloseAfterRequest() {
        var state = HTTP1ConnectionStateMachine()
        XCTAssertEqual(state.channelActive(isWritable: true), .fireChannelActive)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(0))
        let newRequestAction = state.runNewRequest(head: requestHead, metadata: metadata)
        XCTAssertEqual(newRequestAction, .sendRequestHead(requestHead, sendEnd: true))
        XCTAssertEqual(
            state.headSent(),
            .notifyRequestHeadSendSuccessfully(resumeRequestBodyStream: false, startIdleTimer: true)
        )

        let responseHead = HTTPResponseHead(version: .http1_0, status: .ok, headers: ["content-length": "4"])
        XCTAssertEqual(
            state.channelRead(.head(responseHead)),
            .forwardResponseHead(responseHead, pauseRequestBodyStream: false)
        )
        let responseBody = ByteBuffer(bytes: [1, 2, 3, 4])
        XCTAssertEqual(state.channelRead(.body(responseBody)), .wait)
        XCTAssertEqual(state.channelRead(.end(nil)), .succeedRequest(.close, .init([responseBody])))
        XCTAssertEqual(state.channelInactive(), .fireChannelInactive)
    }

    func testAHTTP1_0ResponseWithKeepAliveHeaderLeadsToConnectionBeingKeptAlive() {
        var state = HTTP1ConnectionStateMachine()
        XCTAssertEqual(state.channelActive(isWritable: true), .fireChannelActive)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(0))
        let newRequestAction = state.runNewRequest(head: requestHead, metadata: metadata)
        XCTAssertEqual(newRequestAction, .sendRequestHead(requestHead, sendEnd: true))
        XCTAssertEqual(
            state.headSent(),
            .notifyRequestHeadSendSuccessfully(resumeRequestBodyStream: false, startIdleTimer: true)
        )

        let responseHead = HTTPResponseHead(
            version: .http1_0,
            status: .ok,
            headers: ["content-length": "4", "connection": "keep-alive"]
        )
        XCTAssertEqual(
            state.channelRead(.head(responseHead)),
            .forwardResponseHead(responseHead, pauseRequestBodyStream: false)
        )
        let responseBody = ByteBuffer(bytes: [1, 2, 3, 4])
        XCTAssertEqual(state.channelRead(.body(responseBody)), .wait)
        XCTAssertEqual(state.channelRead(.end(nil)), .succeedRequest(.informConnectionIsIdle, .init([responseBody])))
        XCTAssertEqual(state.channelInactive(), .fireChannelInactive)
    }

    func testAConnectionCloseHeaderInTheResponseLeadsToConnectionCloseAfterRequest() {
        var state = HTTP1ConnectionStateMachine()
        XCTAssertEqual(state.channelActive(isWritable: false), .fireChannelActive)
        XCTAssertEqual(state.writabilityChanged(writable: true), .wait)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(0))
        let newRequestAction = state.runNewRequest(head: requestHead, metadata: metadata)
        XCTAssertEqual(newRequestAction, .sendRequestHead(requestHead, sendEnd: true))
        XCTAssertEqual(
            state.headSent(),
            .notifyRequestHeadSendSuccessfully(resumeRequestBodyStream: false, startIdleTimer: true)
        )

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok, headers: ["connection": "close"])
        XCTAssertEqual(
            state.channelRead(.head(responseHead)),
            .forwardResponseHead(responseHead, pauseRequestBodyStream: false)
        )
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
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(0))
        let newRequestAction = state.runNewRequest(head: requestHead, metadata: metadata)
        XCTAssertEqual(newRequestAction, .sendRequestHead(requestHead, sendEnd: true))

        XCTAssertEqual(state.channelInactive(), .failRequest(HTTPClientError.remoteConnectionClosed, .none))

        XCTAssertEqual(state.headSent(), .wait)
    }

    func testRequestWasCancelledWhileUploadingData() {
        var state = HTTP1ConnectionStateMachine()
        XCTAssertEqual(state.channelActive(isWritable: false), .fireChannelActive)

        let requestHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/", headers: ["content-length": "4"])
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(4))
        XCTAssertEqual(state.runNewRequest(head: requestHead, metadata: metadata), .wait)
        XCTAssertEqual(state.writabilityChanged(writable: true), .sendRequestHead(requestHead, sendEnd: false))
        XCTAssertEqual(
            state.headSent(),
            .notifyRequestHeadSendSuccessfully(resumeRequestBodyStream: true, startIdleTimer: false)
        )

        let part0 = IOData.byteBuffer(ByteBuffer(bytes: [0]))
        let part1 = IOData.byteBuffer(ByteBuffer(bytes: [1]))
        XCTAssertEqual(state.requestStreamPartReceived(part0, promise: nil), .sendBodyPart(part0, nil))
        XCTAssertEqual(state.requestStreamPartReceived(part1, promise: nil), .sendBodyPart(part1, nil))
        XCTAssertEqual(
            state.requestCancelled(closeConnection: false),
            .failRequest(HTTPClientError.cancelled, .close(nil))
        )
    }

    func testNewRequestAfterErrorHappened() {
        var state = HTTP1ConnectionStateMachine()
        XCTAssertEqual(state.channelActive(isWritable: false), .fireChannelActive)
        struct MyError: Error, Equatable {}
        XCTAssertEqual(state.errorHappened(MyError()), .fireChannelError(MyError(), closeConnection: true))
        let requestHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/", headers: ["content-length": "4"])
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(4))
        let action = state.runNewRequest(head: requestHead, metadata: metadata)
        guard case .failRequest = action else {
            return XCTFail("unexpected action \(action)")
        }
    }

    func testCancelRequestIsIgnoredWhenConnectionIsIdle() {
        var state = HTTP1ConnectionStateMachine()
        XCTAssertEqual(state.channelActive(isWritable: true), .fireChannelActive)
        XCTAssertEqual(state.requestCancelled(closeConnection: false), .wait, "Should be ignored.")
        XCTAssertEqual(state.requestCancelled(closeConnection: true), .close, "Should lead to connection closure.")
        XCTAssertEqual(
            state.requestCancelled(closeConnection: true),
            .wait,
            "Should be ignored. Connection is already closing"
        )
        XCTAssertEqual(state.channelInactive(), .fireChannelInactive)
        XCTAssertEqual(
            state.requestCancelled(closeConnection: true),
            .wait,
            "Should be ignored. Connection is already closed"
        )
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
        let requestHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/", headers: ["content-length": "4"])
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(4))
        XCTAssertEqual(state.runNewRequest(head: requestHead, metadata: metadata), .wait)
        XCTAssertEqual(
            state.requestCancelled(closeConnection: false),
            .failRequest(HTTPClientError.cancelled, .informConnectionIsIdle)
        )
    }

    func testConnectionIsClosedIfErrorHappensWhileInRequest() {
        var state = HTTP1ConnectionStateMachine()
        XCTAssertEqual(state.channelActive(isWritable: true), .fireChannelActive)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(0))
        let newRequestAction = state.runNewRequest(head: requestHead, metadata: metadata)
        XCTAssertEqual(newRequestAction, .sendRequestHead(requestHead, sendEnd: true))
        XCTAssertEqual(
            state.headSent(),
            .notifyRequestHeadSendSuccessfully(resumeRequestBodyStream: false, startIdleTimer: true)
        )
        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok)
        XCTAssertEqual(
            state.channelRead(.head(responseHead)),
            .forwardResponseHead(responseHead, pauseRequestBodyStream: false)
        )
        XCTAssertEqual(state.channelRead(.body(ByteBuffer(string: "Hello world!\n"))), .wait)
        XCTAssertEqual(state.channelRead(.body(ByteBuffer(string: "Foo Bar!\n"))), .wait)
        let decompressionError = NIOHTTPDecompression.DecompressionError.limit
        XCTAssertEqual(state.errorHappened(decompressionError), .failRequest(decompressionError, .close(nil)))
    }

    func testConnectionIsClosedAfterSwitchingProtocols() {
        var state = HTTP1ConnectionStateMachine()
        XCTAssertEqual(state.channelActive(isWritable: true), .fireChannelActive)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(0))
        let newRequestAction = state.runNewRequest(head: requestHead, metadata: metadata)
        XCTAssertEqual(newRequestAction, .sendRequestHead(requestHead, sendEnd: true))
        XCTAssertEqual(
            state.headSent(),
            .notifyRequestHeadSendSuccessfully(resumeRequestBodyStream: false, startIdleTimer: true)
        )
        let responseHead = HTTPResponseHead(version: .http1_1, status: .switchingProtocols)
        XCTAssertEqual(
            state.channelRead(.head(responseHead)),
            .forwardResponseHead(responseHead, pauseRequestBodyStream: false)
        )
        XCTAssertEqual(state.channelRead(.end(nil)), .succeedRequest(.close, []))
    }

    func testWeDontCrashAfterEarlyHintsAndConnectionClose() {
        var state = HTTP1ConnectionStateMachine()
        XCTAssertEqual(state.channelActive(isWritable: true), .fireChannelActive)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(0))
        let newRequestAction = state.runNewRequest(head: requestHead, metadata: metadata)
        XCTAssertEqual(newRequestAction, .sendRequestHead(requestHead, sendEnd: true))
        XCTAssertEqual(
            state.headSent(),
            .notifyRequestHeadSendSuccessfully(resumeRequestBodyStream: false, startIdleTimer: true)
        )
        let responseHead = HTTPResponseHead(
            version: .http1_1,
            status: .init(statusCode: 103, reasonPhrase: "Early Hints")
        )
        XCTAssertEqual(state.channelRead(.head(responseHead)), .wait)
        XCTAssertEqual(state.channelInactive(), .failRequest(HTTPClientError.remoteConnectionClosed, .none))
    }

    func testWeDontCrashInRaceBetweenSchedulingNewRequestAndConnectionClose() {
        var state = HTTP1ConnectionStateMachine()
        XCTAssertEqual(state.channelActive(isWritable: true), .fireChannelActive)
        XCTAssertEqual(state.channelInactive(), .fireChannelInactive)

        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(0))
        let newRequestAction = state.runNewRequest(head: requestHead, metadata: metadata)
        guard case .failRequest(let error, .none) = newRequestAction else {
            return XCTFail("Unexpected test case")
        }
        XCTAssertEqual(error as? HTTPClientError, .remoteConnectionClosed)
    }
}

extension HTTP1ConnectionStateMachine.Action: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.fireChannelActive, .fireChannelActive):
            return true

        case (.fireChannelInactive, .fireChannelInactive):
            return true
        case (.fireChannelError(_, let lhsCloseConnection), .fireChannelError(_, let rhsCloseConnection)):
            return lhsCloseConnection == rhsCloseConnection

        case (.sendRequestHead(let lhsHead, let lhsStartBody), .sendRequestHead(let rhsHead, let rhsStartBody)):
            return lhsHead == rhsHead && lhsStartBody == rhsStartBody

        case (
            .notifyRequestHeadSendSuccessfully(let lhsResumeRequestBodyStream, let lhsStartIdleTimer),
            .notifyRequestHeadSendSuccessfully(let rhsResumeRequestBodyStream, let rhsStartIdleTimer)
        ):
            return lhsResumeRequestBodyStream == rhsResumeRequestBodyStream && lhsStartIdleTimer == rhsStartIdleTimer

        case (.sendBodyPart(let lhsData, let lhsPromise), .sendBodyPart(let rhsData, let rhsPromise)):
            return lhsData == rhsData && lhsPromise?.futureResult == rhsPromise?.futureResult

        case (.sendRequestEnd, .sendRequestEnd):
            return true

        case (.pauseRequestBodyStream, .pauseRequestBodyStream):
            return true
        case (.resumeRequestBodyStream, .resumeRequestBodyStream):
            return true

        case (
            .forwardResponseHead(let lhsHead, let lhsPauseRequestBodyStream),
            .forwardResponseHead(let rhsHead, let rhsPauseRequestBodyStream)
        ):
            return lhsHead == rhsHead && lhsPauseRequestBodyStream == rhsPauseRequestBodyStream

        case (.forwardResponseBodyParts(let lhsData), .forwardResponseBodyParts(let rhsData)):
            return lhsData == rhsData

        case (
            .succeedRequest(let lhsFinalAction, let lhsFinalBuffer),
            .succeedRequest(let rhsFinalAction, let rhsFinalBuffer)
        ):
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

extension HTTP1ConnectionStateMachine.Action.FinalSuccessfulStreamAction: Equatable {
    public static func == (
        lhs: HTTP1ConnectionStateMachine.Action.FinalSuccessfulStreamAction,
        rhs: HTTP1ConnectionStateMachine.Action.FinalSuccessfulStreamAction
    ) -> Bool {
        switch (lhs, rhs) {
        case (.close, .close):
            return true
        case (sendRequestEnd(let lhsPromise, let lhsShouldClose), sendRequestEnd(let rhsPromise, let rhsShouldClose)):
            return lhsPromise?.futureResult == rhsPromise?.futureResult && lhsShouldClose == rhsShouldClose
        case (informConnectionIsIdle, informConnectionIsIdle):
            return true
        default:
            return false
        }
    }
}

extension HTTP1ConnectionStateMachine.Action.FinalFailedStreamAction: Equatable {
    public static func == (
        lhs: HTTP1ConnectionStateMachine.Action.FinalFailedStreamAction,
        rhs: HTTP1ConnectionStateMachine.Action.FinalFailedStreamAction
    ) -> Bool {
        switch (lhs, rhs) {
        case (.close(let lhsPromise), .close(let rhsPromise)):
            return lhsPromise?.futureResult == rhsPromise?.futureResult
        case (.informConnectionIsIdle, .informConnectionIsIdle):
            return true
        case (.failWritePromise(let lhsPromise), .failWritePromise(let rhsPromise)):
            return lhsPromise?.futureResult == rhsPromise?.futureResult
        case (.none, .none):
            return true

        default:
            return false
        }
    }
}
