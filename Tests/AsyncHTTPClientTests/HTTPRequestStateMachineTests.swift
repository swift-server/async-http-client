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
import NIOHTTP1
import NIOSSL
import XCTest

class HTTPRequestStateMachineTests: XCTestCase {
    func testSimpleGETRequest() {
        var state = HTTPRequestStateMachine(isChannelWritable: true)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .none)
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: false))

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok)
        XCTAssertEqual(state.receivedHTTPResponseHead(responseHead), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        let responseBody = ByteBuffer(bytes: [1, 2, 3, 4])
        XCTAssertEqual(state.receivedHTTPResponseBodyPart(responseBody), .forwardResponseBodyPart(responseBody))
        XCTAssertEqual(state.receivedHTTPResponseEnd(), .succeedRequest(.none))
    }

    func testPOSTRequestWithWriterBackpressure() {
        var state = HTTPRequestStateMachine(isChannelWritable: true)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/", headers: HTTPHeaders([("content-length", "4")]))
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(4))
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: true))
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
        XCTAssertEqual(state.requestStreamFinished(), .sendRequestEnd(succeedRequest: nil))

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok)
        XCTAssertEqual(state.receivedHTTPResponseHead(responseHead), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        let responseBody = ByteBuffer(bytes: [1, 2, 3, 4])
        XCTAssertEqual(state.receivedHTTPResponseBodyPart(responseBody), .forwardResponseBodyPart(responseBody))
        XCTAssertEqual(state.receivedHTTPResponseEnd(), .succeedRequest(.none))
    }

    func testPOSTContentLengthIsTooLong() {
        var state = HTTPRequestStateMachine(isChannelWritable: true)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/", headers: HTTPHeaders([("content-length", "4")]))
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(4))
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: true))
        let part0 = IOData.byteBuffer(ByteBuffer(bytes: [0, 1, 2, 3]))
        let part1 = IOData.byteBuffer(ByteBuffer(bytes: [0, 1, 2, 3]))
        XCTAssertEqual(state.requestStreamPartReceived(part0), .sendBodyPart(part0))

        let failAction = state.requestStreamPartReceived(part1)
        guard case .failRequest(let error, .close) = failAction else {
            return XCTFail("Unexpected action: \(failAction)")
        }

        XCTAssertEqual(error as? HTTPClientError, .bodyLengthMismatch)
    }

    func testPOSTContentLengthIsTooShort() {
        var state = HTTPRequestStateMachine(isChannelWritable: true)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/", headers: HTTPHeaders([("content-length", "8")]))
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(8))
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: true))
        let part0 = IOData.byteBuffer(ByteBuffer(bytes: [0, 1, 2, 3]))
        XCTAssertEqual(state.requestStreamPartReceived(part0), .sendBodyPart(part0))

        let failAction = state.requestStreamFinished()
        guard case .failRequest(let error, .close) = failAction else {
            return XCTFail("Unexpected action: \(failAction)")
        }

        XCTAssertEqual(error as? HTTPClientError, .bodyLengthMismatch)
    }

    func testRequestBodyStreamIsCancelledIfServerRespondsWith301() {
        var state = HTTPRequestStateMachine(isChannelWritable: true)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/", headers: HTTPHeaders([("content-length", "12")]))
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(12))
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: true))
        let part = IOData.byteBuffer(ByteBuffer(bytes: [0, 1, 2, 3]))
        XCTAssertEqual(state.requestStreamPartReceived(part), .sendBodyPart(part))

        // response is comming before having send all data
        let responseHead = HTTPResponseHead(version: .http1_1, status: .movedPermanently)
        XCTAssertEqual(state.receivedHTTPResponseHead(responseHead), .forwardResponseHead(responseHead, pauseRequestBodyStream: true))
        XCTAssertEqual(state.writabilityChanged(writable: false), .wait)
        XCTAssertEqual(state.writabilityChanged(writable: true), .wait)
        XCTAssertEqual(state.requestStreamPartReceived(part), .wait,
                       "Expected to drop all stream data after having received a response head, with status >= 300")

        XCTAssertEqual(state.receivedHTTPResponseEnd(), .succeedRequest(.close))

        XCTAssertEqual(state.requestStreamPartReceived(part), .wait,
                       "Expected to drop all stream data after having received a response head, with status >= 300")

        XCTAssertEqual(state.requestStreamFinished(), .wait,
                       "Expected to drop all stream data after having received a response head, with status >= 300")
    }

    func testRequestBodyStreamIsCancelledIfServerRespondsWith301WhileWriteBackpressure() {
        var state = HTTPRequestStateMachine(isChannelWritable: true)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/", headers: HTTPHeaders([("content-length", "12")]))
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(12))
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: true))
        let part = IOData.byteBuffer(ByteBuffer(bytes: [0, 1, 2, 3]))
        XCTAssertEqual(state.requestStreamPartReceived(part), .sendBodyPart(part))
        XCTAssertEqual(state.writabilityChanged(writable: false), .pauseRequestBodyStream)

        // response is comming before having send all data
        let responseHead = HTTPResponseHead(version: .http1_1, status: .movedPermanently)
        XCTAssertEqual(state.receivedHTTPResponseHead(responseHead), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        XCTAssertEqual(state.writabilityChanged(writable: true), .wait)
        XCTAssertEqual(state.requestStreamPartReceived(part), .wait,
                       "Expected to drop all stream data after having received a response head, with status >= 300")

        XCTAssertEqual(state.receivedHTTPResponseEnd(), .succeedRequest(.close))

        XCTAssertEqual(state.requestStreamPartReceived(part), .wait,
                       "Expected to drop all stream data after having received a response head, with status >= 300")

        XCTAssertEqual(state.requestStreamFinished(), .wait,
                       "Expected to drop all stream data after having received a response head, with status >= 300")
    }

    func testRequestBodyStreamIsContinuedIfServerRespondsWith200() {
        var state = HTTPRequestStateMachine(isChannelWritable: true)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/", headers: HTTPHeaders([("content-length", "12")]))
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(12))
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: true))
        let part0 = IOData.byteBuffer(ByteBuffer(bytes: 0...3))
        XCTAssertEqual(state.requestStreamPartReceived(part0), .sendBodyPart(part0))

        // response is coming before having send all data
        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok)
        XCTAssertEqual(state.receivedHTTPResponseHead(responseHead), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        XCTAssertEqual(state.receivedHTTPResponseEnd(), .wait)

        let part1 = IOData.byteBuffer(ByteBuffer(bytes: 4...7))
        XCTAssertEqual(state.requestStreamPartReceived(part1), .sendBodyPart(part1))
        let part2 = IOData.byteBuffer(ByteBuffer(bytes: 8...11))
        XCTAssertEqual(state.requestStreamPartReceived(part2), .sendBodyPart(part2))
        XCTAssertEqual(state.requestStreamFinished(), .sendRequestEnd(succeedRequest: .some(.none)))
    }

    func testRequestBodyStreamIsContinuedIfServerSendHeadWithStatus200() {
        var state = HTTPRequestStateMachine(isChannelWritable: true)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/", headers: HTTPHeaders([("content-length", "12")]))
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(12))
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: true))
        let part0 = IOData.byteBuffer(ByteBuffer(bytes: 0...3))
        XCTAssertEqual(state.requestStreamPartReceived(part0), .sendBodyPart(part0))

        // response is coming before having send all data
        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok)
        XCTAssertEqual(state.receivedHTTPResponseHead(responseHead), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))

        let part1 = IOData.byteBuffer(ByteBuffer(bytes: 4...7))
        XCTAssertEqual(state.requestStreamPartReceived(part1), .sendBodyPart(part1))
        let part2 = IOData.byteBuffer(ByteBuffer(bytes: 8...11))
        XCTAssertEqual(state.requestStreamPartReceived(part2), .sendBodyPart(part2))
        XCTAssertEqual(state.requestStreamFinished(), .sendRequestEnd(succeedRequest: nil))

        XCTAssertEqual(state.receivedHTTPResponseEnd(), .succeedRequest(.none))
    }

    func testRequestIsFailedIfRequestBodySizeIsWrongEvenAfterServerRespondedWith200() {
        var state = HTTPRequestStateMachine(isChannelWritable: true)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/", headers: HTTPHeaders([("content-length", "12")]))
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(12))
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: true))
        let part0 = IOData.byteBuffer(ByteBuffer(bytes: 0...3))
        XCTAssertEqual(state.requestStreamPartReceived(part0), .sendBodyPart(part0))

        // response is comming before having send all data
        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok)
        XCTAssertEqual(state.receivedHTTPResponseHead(responseHead), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        XCTAssertEqual(state.receivedHTTPResponseEnd(), .wait)

        let part1 = IOData.byteBuffer(ByteBuffer(bytes: 4...7))
        XCTAssertEqual(state.requestStreamPartReceived(part1), .sendBodyPart(part1))
        XCTAssertEqual(state.requestStreamFinished(), .failRequest(HTTPClientError.bodyLengthMismatch, .close))
        XCTAssertEqual(state.channelInactive(), .wait)
    }

    func testRequestIsFailedIfRequestBodySizeIsWrongEvenAfterServerSendHeadWithStatus200() {
        var state = HTTPRequestStateMachine(isChannelWritable: true)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/", headers: HTTPHeaders([("content-length", "12")]))
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(12))
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: true))
        let part0 = IOData.byteBuffer(ByteBuffer(bytes: 0...3))
        XCTAssertEqual(state.requestStreamPartReceived(part0), .sendBodyPart(part0))

        // response is comming before having send all data
        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok)
        XCTAssertEqual(state.receivedHTTPResponseHead(responseHead), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))

        let part1 = IOData.byteBuffer(ByteBuffer(bytes: 4...7))
        XCTAssertEqual(state.requestStreamPartReceived(part1), .sendBodyPart(part1))
        XCTAssertEqual(state.requestStreamFinished(), .failRequest(HTTPClientError.bodyLengthMismatch, .close))
        XCTAssertEqual(state.receivedHTTPResponseEnd(), .wait)
    }

    func testRequestIsNotSendUntilChannelIsWritable() {
        var state = HTTPRequestStateMachine(isChannelWritable: false)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .none)
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .wait)
        XCTAssertEqual(state.readEventCaught(), .read)
        XCTAssertEqual(state.writabilityChanged(writable: true), .sendRequestHead(requestHead, startBody: false))

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok)
        XCTAssertEqual(state.receivedHTTPResponseHead(responseHead), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        let responseBody = ByteBuffer(bytes: [1, 2, 3, 4])
        XCTAssertEqual(state.receivedHTTPResponseBodyPart(responseBody), .forwardResponseBodyPart(responseBody))
        XCTAssertEqual(state.receivedHTTPResponseEnd(), .succeedRequest(.none))
        XCTAssertEqual(state.channelInactive(), .wait)
    }

    func testResponseReadingWithBackpressure() {
        var state = HTTPRequestStateMachine(isChannelWritable: true)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .none)
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: false))

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok, headers: HTTPHeaders([("content-length", "12")]))
        XCTAssertEqual(state.receivedHTTPResponseHead(responseHead), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        let part0 = ByteBuffer(bytes: 0...3)
        let part1 = ByteBuffer(bytes: 4...7)
        let part2 = ByteBuffer(bytes: 8...11)
        XCTAssertEqual(state.receivedHTTPResponseBodyPart(part0), .forwardResponseBodyPart(part0))
        XCTAssertEqual(state.receivedHTTPResponseBodyPart(part1), .forwardResponseBodyPart(part1))
        XCTAssertEqual(state.readEventCaught(), .wait)
        XCTAssertEqual(state.readEventCaught(), .wait, "Expected to be able to consume a second read event")
        XCTAssertEqual(state.forwardMoreBodyParts(), .read)
        XCTAssertEqual(state.receivedHTTPResponseBodyPart(part2), .forwardResponseBodyPart(part2))
        XCTAssertEqual(state.forwardMoreBodyParts(), .wait)
        XCTAssertEqual(state.readEventCaught(), .read)
        XCTAssertEqual(state.receivedHTTPResponseEnd(), .succeedRequest(.none))
    }

    func testResponseReadingWithBackpressureEndOfResponseSetsCaughtReadEventFree() {
        var state = HTTPRequestStateMachine(isChannelWritable: true)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .none)
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: false))

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok, headers: HTTPHeaders([("content-length", "12")]))
        XCTAssertEqual(state.receivedHTTPResponseHead(responseHead), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        let part0 = ByteBuffer(bytes: 0...3)
        let part1 = ByteBuffer(bytes: 4...7)
        let part2 = ByteBuffer(bytes: 8...11)
        XCTAssertEqual(state.receivedHTTPResponseBodyPart(part0), .forwardResponseBodyPart(part0))
        XCTAssertEqual(state.readEventCaught(), .wait)
        XCTAssertEqual(state.forwardMoreBodyParts(), .read)
        XCTAssertEqual(state.receivedHTTPResponseBodyPart(part1), .forwardResponseBodyPart(part1))
        XCTAssertEqual(state.forwardMoreBodyParts(), .wait)
        XCTAssertEqual(state.forwardMoreBodyParts(), .wait, "Calling forward more bytes twice is okay")
        XCTAssertEqual(state.readEventCaught(), .read)
        XCTAssertEqual(state.receivedHTTPResponseBodyPart(part2), .forwardResponseBodyPart(part2))
        XCTAssertEqual(state.readEventCaught(), .wait)
        XCTAssertEqual(state.receivedHTTPResponseEnd(), .succeedRequest(.read))
    }

    func testCancellingARequestInStateInitializedKeepsTheConnectionAlive() {
        var state = HTTPRequestStateMachine(isChannelWritable: false)
        XCTAssertEqual(state.requestCancelled(), .failRequest(HTTPClientError.cancelled, .none))
    }

    func testCancellingARequestBeforeBeingSendKeepsTheConnectionAlive() {
        var state = HTTPRequestStateMachine(isChannelWritable: false)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .none)
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .wait)
        XCTAssertEqual(state.requestCancelled(), .failRequest(HTTPClientError.cancelled, .none))
    }

    func testCancellingARequestThatIsSent() {
        var state = HTTPRequestStateMachine(isChannelWritable: true)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .none)
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: false))
        XCTAssertEqual(state.requestCancelled(), .failRequest(HTTPClientError.cancelled, .close))
    }

    func testRemoteSuddenlyClosesTheConnection() {
        var state = HTTPRequestStateMachine(isChannelWritable: true)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/", headers: .init([("content-length", "4")]))
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(4))
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: true))
        XCTAssertEqual(state.requestCancelled(), .failRequest(HTTPClientError.remoteConnectionClosed, .close))
        XCTAssertEqual(state.requestStreamPartReceived(.byteBuffer(.init(bytes: 1...3))), .wait)
    }

    func testReadTimeoutLeadsToFailureWithEverythingAfterBeingIgnore() {
        var state = HTTPRequestStateMachine(isChannelWritable: true)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .none)
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: false))

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok, headers: HTTPHeaders([("content-length", "12")]))
        XCTAssertEqual(state.receivedHTTPResponseHead(responseHead), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        let part0 = ByteBuffer(bytes: 0...3)
        XCTAssertEqual(state.receivedHTTPResponseBodyPart(part0), .forwardResponseBodyPart(part0))
        XCTAssertEqual(state.idleReadTimeoutTriggered(), .failRequest(HTTPClientError.readTimeout, .close))
        XCTAssertEqual(state.receivedHTTPResponseBodyPart(ByteBuffer(bytes: 4...7)), .wait)
        XCTAssertEqual(state.receivedHTTPResponseBodyPart(ByteBuffer(bytes: 8...11)), .wait)
        XCTAssertEqual(state.forwardMoreBodyParts(), .wait)
        XCTAssertEqual(state.receivedHTTPResponseEnd(), .wait)
    }

    func testResponseWithStatus1XXAreIgnored() {
        var state = HTTPRequestStateMachine(isChannelWritable: true)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .none)
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: false))

        let continueHead = HTTPResponseHead(version: .http1_1, status: .continue)
        XCTAssertEqual(state.receivedHTTPResponseHead(continueHead), .wait)

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok)
        XCTAssertEqual(state.receivedHTTPResponseHead(responseHead), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        XCTAssertEqual(state.receivedHTTPResponseEnd(), .succeedRequest(.none))
    }

    func testReadTimeoutThatFiresToLateIsIgnored() {
        var state = HTTPRequestStateMachine(isChannelWritable: true)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .none)
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: false))

        let continueHead = HTTPResponseHead(version: .http1_1, status: .continue)
        XCTAssertEqual(state.receivedHTTPResponseHead(continueHead), .wait)

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok)
        XCTAssertEqual(state.receivedHTTPResponseHead(responseHead), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        XCTAssertEqual(state.receivedHTTPResponseEnd(), .succeedRequest(.none))
        XCTAssertEqual(state.idleReadTimeoutTriggered(), .wait, "A read timeout that fires to late must be ignored")
    }

    func testCancellationThatIsInvokedToLateIsIgnored() {
        var state = HTTPRequestStateMachine(isChannelWritable: true)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .none)
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: false))

        let continueHead = HTTPResponseHead(version: .http1_1, status: .continue)
        XCTAssertEqual(state.receivedHTTPResponseHead(continueHead), .wait)

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok)
        XCTAssertEqual(state.receivedHTTPResponseHead(responseHead), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        XCTAssertEqual(state.receivedHTTPResponseEnd(), .succeedRequest(.none))
        XCTAssertEqual(state.requestCancelled(), .wait, "A cancellation that happens to late is ignored")
    }

    func testErrorWhileRunningARequestClosesTheStream() {
        var state = HTTPRequestStateMachine(isChannelWritable: true)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .none)
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: false))

        XCTAssertEqual(state.errorHappened(NIOSSLError.uncleanShutdown), .failRequest(NIOSSLError.uncleanShutdown, .close))
        XCTAssertEqual(state.requestCancelled(), .wait, "A cancellation that happens to late is ignored")
    }
}

extension HTTPRequestStateMachine.Action: Equatable {
    public static func == (lhs: HTTPRequestStateMachine.Action, rhs: HTTPRequestStateMachine.Action) -> Bool {
        switch (lhs, rhs) {
        case (.sendRequestHead(let lhsHead, let lhsStartBody), .sendRequestHead(let rhsHead, let rhsStartBody)):
            return lhsHead == rhsHead && lhsStartBody == rhsStartBody
        case (.sendBodyPart(let lhsData), .sendBodyPart(let rhsData)):
            return lhsData == rhsData
        case (.sendRequestEnd(let lhsFinalAction), .sendRequestEnd(let rhsFinalAction)):
            return lhsFinalAction == rhsFinalAction

        case (.pauseRequestBodyStream, .pauseRequestBodyStream):
            return true
        case (.resumeRequestBodyStream, .resumeRequestBodyStream):
            return true

        case (.forwardResponseHead(let lhsHead, let lhsPauseRequestBodyStream), .forwardResponseHead(let rhsHead, let rhsPauseRequestBodyStream)):
            return lhsHead == rhsHead && lhsPauseRequestBodyStream == rhsPauseRequestBodyStream
        case (.forwardResponseBodyPart(let lhsData), .forwardResponseBodyPart(let rhsData)):
            return lhsData == rhsData

        case (.succeedRequest(let lhsFinalAction), .succeedRequest(let rhsFinalAction)):
            return lhsFinalAction == rhsFinalAction
        case (.failRequest(_, let lhsFinalAction), .failRequest(_, let rhsFinalAction)):
            return lhsFinalAction == rhsFinalAction

        case (.read, .read):
            return true
        case (.wait, .wait):
            return true
        default:
            return false
        }
    }
}
