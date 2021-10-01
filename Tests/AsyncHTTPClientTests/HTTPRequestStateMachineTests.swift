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
import NIOSSL
import XCTest

class HTTPRequestStateMachineTests: XCTestCase {
    func testSimpleGETRequest() {
        var state = HTTPRequestStateMachine(isChannelWritable: true, ignoreUncleanSSLShutdown: false)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .none)
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: false))

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok)
        XCTAssertEqual(state.channelRead(.head(responseHead)), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        let responseBody = ByteBuffer(bytes: [1, 2, 3, 4])
        XCTAssertEqual(state.channelRead(.body(responseBody)), .wait)
        XCTAssertEqual(state.channelRead(.end(nil)), .succeedRequest(.none, .init([responseBody])))
        XCTAssertEqual(state.channelReadComplete(), .wait)
    }

    func testPOSTRequestWithWriterBackpressure() {
        var state = HTTPRequestStateMachine(isChannelWritable: true, ignoreUncleanSSLShutdown: false)
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
        XCTAssertEqual(state.requestStreamFinished(), .sendRequestEnd)

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok)
        XCTAssertEqual(state.channelRead(.head(responseHead)), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        let responseBody = ByteBuffer(bytes: [1, 2, 3, 4])
        XCTAssertEqual(state.channelRead(.body(responseBody)), .wait)
        XCTAssertEqual(state.channelRead(.end(nil)), .succeedRequest(.none, .init([responseBody])))
        XCTAssertEqual(state.channelReadComplete(), .wait)
    }

    func testPOSTContentLengthIsTooLong() {
        var state = HTTPRequestStateMachine(isChannelWritable: true, ignoreUncleanSSLShutdown: false)
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
        var state = HTTPRequestStateMachine(isChannelWritable: true, ignoreUncleanSSLShutdown: false)
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
        var state = HTTPRequestStateMachine(isChannelWritable: true, ignoreUncleanSSLShutdown: false)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/", headers: HTTPHeaders([("content-length", "12")]))
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(12))
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: true))
        let part = IOData.byteBuffer(ByteBuffer(bytes: [0, 1, 2, 3]))
        XCTAssertEqual(state.requestStreamPartReceived(part), .sendBodyPart(part))

        // response is coming before having send all data
        let responseHead = HTTPResponseHead(version: .http1_1, status: .movedPermanently)
        XCTAssertEqual(state.channelRead(.head(responseHead)), .forwardResponseHead(responseHead, pauseRequestBodyStream: true))
        XCTAssertEqual(state.writabilityChanged(writable: false), .wait)
        XCTAssertEqual(state.writabilityChanged(writable: true), .wait)
        XCTAssertEqual(state.requestStreamPartReceived(part), .wait,
                       "Expected to drop all stream data after having received a response head, with status >= 300")

        XCTAssertEqual(state.channelRead(.end(nil)), .succeedRequest(.close, .init()))

        XCTAssertEqual(state.requestStreamPartReceived(part), .wait,
                       "Expected to drop all stream data after having received a response head, with status >= 300")

        XCTAssertEqual(state.requestStreamFinished(), .wait,
                       "Expected to drop all stream data after having received a response head, with status >= 300")
    }

    func testRequestBodyStreamIsCancelledIfServerRespondsWith301WhileWriteBackpressure() {
        var state = HTTPRequestStateMachine(isChannelWritable: true, ignoreUncleanSSLShutdown: false)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/", headers: HTTPHeaders([("content-length", "12")]))
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(12))
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: true))
        let part = IOData.byteBuffer(ByteBuffer(bytes: [0, 1, 2, 3]))
        XCTAssertEqual(state.requestStreamPartReceived(part), .sendBodyPart(part))
        XCTAssertEqual(state.writabilityChanged(writable: false), .pauseRequestBodyStream)

        // response is coming before having send all data
        let responseHead = HTTPResponseHead(version: .http1_1, status: .movedPermanently)
        XCTAssertEqual(state.channelRead(.head(responseHead)), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        XCTAssertEqual(state.writabilityChanged(writable: true), .wait)
        XCTAssertEqual(state.requestStreamPartReceived(part), .wait,
                       "Expected to drop all stream data after having received a response head, with status >= 300")

        XCTAssertEqual(state.channelRead(.end(nil)), .succeedRequest(.close, .init()))

        XCTAssertEqual(state.requestStreamPartReceived(part), .wait,
                       "Expected to drop all stream data after having received a response head, with status >= 300")

        XCTAssertEqual(state.requestStreamFinished(), .wait,
                       "Expected to drop all stream data after having received a response head, with status >= 300")
    }

    func testRequestBodyStreamIsContinuedIfServerRespondsWith200() {
        var state = HTTPRequestStateMachine(isChannelWritable: true, ignoreUncleanSSLShutdown: false)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/", headers: HTTPHeaders([("content-length", "12")]))
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(12))
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: true))
        let part0 = IOData.byteBuffer(ByteBuffer(bytes: 0...3))
        XCTAssertEqual(state.requestStreamPartReceived(part0), .sendBodyPart(part0))

        // response is coming before having send all data
        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok)
        XCTAssertEqual(state.channelRead(.head(responseHead)), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        XCTAssertEqual(state.channelRead(.end(nil)), .forwardResponseBodyParts(.init()))

        let part1 = IOData.byteBuffer(ByteBuffer(bytes: 4...7))
        XCTAssertEqual(state.requestStreamPartReceived(part1), .sendBodyPart(part1))
        let part2 = IOData.byteBuffer(ByteBuffer(bytes: 8...11))
        XCTAssertEqual(state.requestStreamPartReceived(part2), .sendBodyPart(part2))
        XCTAssertEqual(state.requestStreamFinished(), .succeedRequest(.sendRequestEnd, .init()))
    }

    func testRequestBodyStreamIsContinuedIfServerSendHeadWithStatus200() {
        var state = HTTPRequestStateMachine(isChannelWritable: true, ignoreUncleanSSLShutdown: false)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/", headers: HTTPHeaders([("content-length", "12")]))
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(12))
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: true))
        let part0 = IOData.byteBuffer(ByteBuffer(bytes: 0...3))
        XCTAssertEqual(state.requestStreamPartReceived(part0), .sendBodyPart(part0))

        // response is coming before having send all data
        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok)
        XCTAssertEqual(state.channelRead(.head(responseHead)), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))

        let part1 = IOData.byteBuffer(ByteBuffer(bytes: 4...7))
        XCTAssertEqual(state.requestStreamPartReceived(part1), .sendBodyPart(part1))
        let part2 = IOData.byteBuffer(ByteBuffer(bytes: 8...11))
        XCTAssertEqual(state.requestStreamPartReceived(part2), .sendBodyPart(part2))
        XCTAssertEqual(state.requestStreamFinished(), .sendRequestEnd)

        XCTAssertEqual(state.channelRead(.end(nil)), .succeedRequest(.none, .init()))
    }

    func testRequestIsFailedIfRequestBodySizeIsWrongEvenAfterServerRespondedWith200() {
        var state = HTTPRequestStateMachine(isChannelWritable: true, ignoreUncleanSSLShutdown: false)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/", headers: HTTPHeaders([("content-length", "12")]))
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(12))
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: true))
        let part0 = IOData.byteBuffer(ByteBuffer(bytes: 0...3))
        XCTAssertEqual(state.requestStreamPartReceived(part0), .sendBodyPart(part0))

        // response is coming before having send all data
        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok)
        XCTAssertEqual(state.channelRead(.head(responseHead)), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        XCTAssertEqual(state.channelRead(.end(nil)), .forwardResponseBodyParts(.init()))

        let part1 = IOData.byteBuffer(ByteBuffer(bytes: 4...7))
        XCTAssertEqual(state.requestStreamPartReceived(part1), .sendBodyPart(part1))
        XCTAssertEqual(state.requestStreamFinished(), .failRequest(HTTPClientError.bodyLengthMismatch, .close))
        XCTAssertEqual(state.channelInactive(), .wait)
    }

    func testRequestIsFailedIfRequestBodySizeIsWrongEvenAfterServerSendHeadWithStatus200() {
        var state = HTTPRequestStateMachine(isChannelWritable: true, ignoreUncleanSSLShutdown: false)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/", headers: HTTPHeaders([("content-length", "12")]))
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(12))
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: true))
        let part0 = IOData.byteBuffer(ByteBuffer(bytes: 0...3))
        XCTAssertEqual(state.requestStreamPartReceived(part0), .sendBodyPart(part0))

        // response is coming before having send all data
        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok)
        XCTAssertEqual(state.channelRead(.head(responseHead)), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))

        let part1 = IOData.byteBuffer(ByteBuffer(bytes: 4...7))
        XCTAssertEqual(state.requestStreamPartReceived(part1), .sendBodyPart(part1))
        XCTAssertEqual(state.requestStreamFinished(), .failRequest(HTTPClientError.bodyLengthMismatch, .close))
        XCTAssertEqual(state.channelRead(.end(nil)), .wait)
    }

    func testRequestIsNotSendUntilChannelIsWritable() {
        var state = HTTPRequestStateMachine(isChannelWritable: false, ignoreUncleanSSLShutdown: false)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .none)
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .wait)
        XCTAssertEqual(state.read(), .read)
        XCTAssertEqual(state.writabilityChanged(writable: true), .sendRequestHead(requestHead, startBody: false))

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok)
        XCTAssertEqual(state.channelRead(.head(responseHead)), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        let responseBody = ByteBuffer(bytes: [1, 2, 3, 4])
        XCTAssertEqual(state.channelRead(.body(responseBody)), .wait)
        XCTAssertEqual(state.channelRead(.end(nil)), .succeedRequest(.none, .init([responseBody])))
        XCTAssertEqual(state.channelInactive(), .wait)
    }

    func testConnectionBecomesInactiveWhileWaitingForWritable() {
        var state = HTTPRequestStateMachine(isChannelWritable: false, ignoreUncleanSSLShutdown: false)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .none)
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .wait)
        XCTAssertEqual(state.channelInactive(), .failRequest(HTTPClientError.remoteConnectionClosed, .none))
    }

    func testResponseReadingWithBackpressure() {
        var state = HTTPRequestStateMachine(isChannelWritable: true, ignoreUncleanSSLShutdown: false)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .none)
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: false))

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
        XCTAssertEqual(state.channelRead(.end(nil)), .succeedRequest(.none, .init()))
        XCTAssertEqual(state.channelReadComplete(), .wait)
        XCTAssertEqual(state.read(), .read)
        XCTAssertEqual(state.demandMoreResponseBodyParts(), .wait)
    }

    func testChannelReadCompleteTriggersButNoBodyDataWasReceivedSoFar() {
        var state = HTTPRequestStateMachine(isChannelWritable: true, ignoreUncleanSSLShutdown: false)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .none)
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: false))

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok, headers: HTTPHeaders([("content-length", "12")]))
        XCTAssertEqual(state.channelRead(.head(responseHead)), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        let part0 = ByteBuffer(bytes: 0...3)
        let part1 = ByteBuffer(bytes: 4...7)
        let part2 = ByteBuffer(bytes: 8...11)
        XCTAssertEqual(state.channelReadComplete(), .wait)
        XCTAssertEqual(state.read(), .read)
        XCTAssertEqual(state.channelRead(.body(part0)), .wait)
        XCTAssertEqual(state.channelRead(.body(part1)), .wait)
        XCTAssertEqual(state.channelReadComplete(), .forwardResponseBodyParts(.init([part0, part1])))
        XCTAssertEqual(state.read(), .wait)
        XCTAssertEqual(state.demandMoreResponseBodyParts(), .read)
        XCTAssertEqual(state.channelReadComplete(), .wait)
        XCTAssertEqual(state.read(), .read)
        XCTAssertEqual(state.channelRead(.body(part2)), .wait)
        XCTAssertEqual(state.channelRead(.end(nil)), .succeedRequest(.none, .init([part2])))
        XCTAssertEqual(state.channelReadComplete(), .wait)
        XCTAssertEqual(state.read(), .read)
        XCTAssertEqual(state.demandMoreResponseBodyParts(), .wait)
    }

    func testResponseReadingWithBackpressureEndOfResponseAllowsReadEventsToTriggerDirectly() {
        var state = HTTPRequestStateMachine(isChannelWritable: true, ignoreUncleanSSLShutdown: false)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .none)
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: false))

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok, headers: HTTPHeaders([("content-length", "12")]))
        XCTAssertEqual(state.channelRead(.head(responseHead)), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        let part0 = ByteBuffer(bytes: 0...3)
        let part1 = ByteBuffer(bytes: 4...7)
        let part2 = ByteBuffer(bytes: 8...11)
        XCTAssertEqual(state.channelRead(.body(part0)), .wait)
        XCTAssertEqual(state.channelReadComplete(), .forwardResponseBodyParts(.init([part0])))
        XCTAssertEqual(state.read(), .wait)
        XCTAssertEqual(state.demandMoreResponseBodyParts(), .read)
        XCTAssertEqual(state.channelRead(.body(part1)), .wait)
        XCTAssertEqual(state.channelReadComplete(), .forwardResponseBodyParts(.init([part1])))
        XCTAssertEqual(state.demandMoreResponseBodyParts(), .wait)
        XCTAssertEqual(state.demandMoreResponseBodyParts(), .wait, "Calling forward more bytes twice is okay")
        XCTAssertEqual(state.read(), .read)
        XCTAssertEqual(state.channelRead(.body(part2)), .wait)
        XCTAssertEqual(state.read(), .read, "Calling `read` while we wait for a channelReadComplete doesn't crash")
        XCTAssertEqual(state.demandMoreResponseBodyParts(), .wait, "Calling `demandMoreResponseBodyParts` while we wait for a channelReadComplete doesn't crash")
        XCTAssertEqual(state.channelReadComplete(), .forwardResponseBodyParts(.init([part2])))
        XCTAssertEqual(state.demandMoreResponseBodyParts(), .wait)
        XCTAssertEqual(state.read(), .read)
        XCTAssertEqual(state.channelRead(.end(nil)), .succeedRequest(.none, .init()))
        XCTAssertEqual(state.demandMoreResponseBodyParts(), .wait)
        XCTAssertEqual(state.read(), .read)
    }

    func testCancellingARequestInStateInitializedKeepsTheConnectionAlive() {
        var state = HTTPRequestStateMachine(isChannelWritable: false, ignoreUncleanSSLShutdown: false)
        XCTAssertEqual(state.requestCancelled(), .failRequest(HTTPClientError.cancelled, .none))
    }

    func testCancellingARequestBeforeBeingSendKeepsTheConnectionAlive() {
        var state = HTTPRequestStateMachine(isChannelWritable: false, ignoreUncleanSSLShutdown: false)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .none)
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .wait)
        XCTAssertEqual(state.requestCancelled(), .failRequest(HTTPClientError.cancelled, .none))
    }

    func testConnectionBecomesWritableBeforeFirstRequest() {
        var state = HTTPRequestStateMachine(isChannelWritable: false, ignoreUncleanSSLShutdown: false)
        XCTAssertEqual(state.writabilityChanged(writable: true), .wait)

        // --- sending request
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .none)
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: false))

        // --- receiving response
        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok, headers: ["content-length": "4"])
        XCTAssertEqual(state.channelRead(.head(responseHead)), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        let responseBody = ByteBuffer(bytes: [1, 2, 3, 4])
        XCTAssertEqual(state.channelRead(.body(responseBody)), .wait)
        XCTAssertEqual(state.channelRead(.end(nil)), .succeedRequest(.none, .init([responseBody])))
        XCTAssertEqual(state.channelReadComplete(), .wait)
    }

    func testCancellingARequestThatIsSent() {
        var state = HTTPRequestStateMachine(isChannelWritable: true, ignoreUncleanSSLShutdown: false)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .none)
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: false))
        XCTAssertEqual(state.requestCancelled(), .failRequest(HTTPClientError.cancelled, .close))
    }

    func testRemoteSuddenlyClosesTheConnection() {
        var state = HTTPRequestStateMachine(isChannelWritable: true, ignoreUncleanSSLShutdown: false)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/", headers: .init([("content-length", "4")]))
        let metadata = RequestFramingMetadata(connectionClose: false, body: .fixedSize(4))
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: true))
        XCTAssertEqual(state.requestCancelled(), .failRequest(HTTPClientError.remoteConnectionClosed, .close))
        XCTAssertEqual(state.requestStreamPartReceived(.byteBuffer(.init(bytes: 1...3))), .wait)
    }

    func testReadTimeoutLeadsToFailureWithEverythingAfterBeingIgnored() {
        var state = HTTPRequestStateMachine(isChannelWritable: true, ignoreUncleanSSLShutdown: false)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .none)
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: false))

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok, headers: HTTPHeaders([("content-length", "12")]))
        XCTAssertEqual(state.channelRead(.head(responseHead)), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        let part0 = ByteBuffer(bytes: 0...3)
        XCTAssertEqual(state.channelRead(.body(part0)), .wait)
        XCTAssertEqual(state.idleReadTimeoutTriggered(), .failRequest(HTTPClientError.readTimeout, .close))
        XCTAssertEqual(state.channelRead(.body(ByteBuffer(bytes: 4...7))), .wait)
        XCTAssertEqual(state.channelRead(.body(ByteBuffer(bytes: 8...11))), .wait)
        XCTAssertEqual(state.demandMoreResponseBodyParts(), .wait)
        XCTAssertEqual(state.channelRead(.end(nil)), .wait)
    }

    func testResponseWithStatus1XXAreIgnored() {
        var state = HTTPRequestStateMachine(isChannelWritable: true, ignoreUncleanSSLShutdown: false)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .none)
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: false))

        let continueHead = HTTPResponseHead(version: .http1_1, status: .continue)
        XCTAssertEqual(state.channelRead(.head(continueHead)), .wait)

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok)
        XCTAssertEqual(state.channelRead(.head(responseHead)), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        XCTAssertEqual(state.channelRead(.end(nil)), .succeedRequest(.none, .init()))
        XCTAssertEqual(state.channelReadComplete(), .wait)
        XCTAssertEqual(state.read(), .read)
    }

    func testReadTimeoutThatFiresToLateIsIgnored() {
        var state = HTTPRequestStateMachine(isChannelWritable: true, ignoreUncleanSSLShutdown: false)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .none)
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: false))

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok)
        XCTAssertEqual(state.channelRead(.head(responseHead)), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        XCTAssertEqual(state.channelRead(.end(nil)), .succeedRequest(.none, .init()))
        XCTAssertEqual(state.idleReadTimeoutTriggered(), .wait, "A read timeout that fires to late must be ignored")
    }

    func testCancellationThatIsInvokedToLateIsIgnored() {
        var state = HTTPRequestStateMachine(isChannelWritable: true, ignoreUncleanSSLShutdown: false)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .none)
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: false))

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok)
        XCTAssertEqual(state.channelRead(.head(responseHead)), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        XCTAssertEqual(state.channelRead(.end(nil)), .succeedRequest(.none, .init()))
        XCTAssertEqual(state.requestCancelled(), .wait, "A cancellation that happens to late is ignored")
    }

    func testErrorWhileRunningARequestClosesTheStream() {
        var state = HTTPRequestStateMachine(isChannelWritable: true, ignoreUncleanSSLShutdown: false)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .none)
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: false))

        XCTAssertEqual(state.errorHappened(NIOSSLError.uncleanShutdown), .failRequest(NIOSSLError.uncleanShutdown, .close))
        XCTAssertEqual(state.requestCancelled(), .wait, "A cancellation that happens to late is ignored")
    }

    func testCanReadHTTP1_0ResponseWithoutBody() {
        var state = HTTPRequestStateMachine(isChannelWritable: true, ignoreUncleanSSLShutdown: false)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .none)
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: false))

        let responseHead = HTTPResponseHead(version: .http1_0, status: .internalServerError)
        XCTAssertEqual(state.channelRead(.head(responseHead)), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        XCTAssertEqual(state.demandMoreResponseBodyParts(), .wait)
        XCTAssertEqual(state.channelReadComplete(), .wait)
        XCTAssertEqual(state.read(), .read)
        XCTAssertEqual(state.channelReadComplete(), .wait)
        XCTAssertEqual(state.channelRead(.end(nil)), .succeedRequest(.close, []))
        XCTAssertEqual(state.channelInactive(), .wait)
    }

    func testCanReadHTTP1_0ResponseWithBody() {
        var state = HTTPRequestStateMachine(isChannelWritable: true, ignoreUncleanSSLShutdown: false)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .none)
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: false))

        let responseHead = HTTPResponseHead(version: .http1_0, status: .internalServerError)
        let body = ByteBuffer(string: "foo bar")
        XCTAssertEqual(state.channelRead(.head(responseHead)), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        XCTAssertEqual(state.demandMoreResponseBodyParts(), .wait)
        XCTAssertEqual(state.channelReadComplete(), .wait)
        XCTAssertEqual(state.read(), .read)
        XCTAssertEqual(state.channelReadComplete(), .wait)
        XCTAssertEqual(state.channelRead(.body(body)), .wait)
        XCTAssertEqual(state.channelRead(.end(nil)), .succeedRequest(.close, [body]))
        XCTAssertEqual(state.channelInactive(), .wait)
    }

    func testFailHTTP1_0RequestThatIsStillUploading() {
        var state = HTTPRequestStateMachine(isChannelWritable: true, ignoreUncleanSSLShutdown: false)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .stream)
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: true))

        let part1: ByteBuffer = .init(string: "foo")
        XCTAssertEqual(state.requestStreamPartReceived(.byteBuffer(part1)), .sendBodyPart(.byteBuffer(part1)))
        let responseHead = HTTPResponseHead(version: .http1_0, status: .ok)
        let body = ByteBuffer(string: "foo bar")
        XCTAssertEqual(state.channelRead(.head(responseHead)), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        XCTAssertEqual(state.demandMoreResponseBodyParts(), .wait)
        XCTAssertEqual(state.channelReadComplete(), .wait)
        XCTAssertEqual(state.read(), .read)
        XCTAssertEqual(state.channelReadComplete(), .wait)
        XCTAssertEqual(state.channelRead(.body(body)), .wait)
        XCTAssertEqual(state.channelRead(.end(nil)), .failRequest(HTTPClientError.remoteConnectionClosed, .close))
        XCTAssertEqual(state.channelInactive(), .wait)
    }

    func testFailHTTP1RequestWithoutContentLengthWithNIOSSLErrorUncleanShutdown() {
        var state = HTTPRequestStateMachine(isChannelWritable: true, ignoreUncleanSSLShutdown: false)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .none)
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: false))

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok)
        let body = ByteBuffer(string: "foo bar")
        XCTAssertEqual(state.channelRead(.head(responseHead)), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        XCTAssertEqual(state.demandMoreResponseBodyParts(), .wait)
        XCTAssertEqual(state.channelRead(.body(body)), .wait)
        XCTAssertEqual(state.errorHappened(NIOSSLError.uncleanShutdown), .failRequest(NIOSSLError.uncleanShutdown, .close))
        XCTAssertEqual(state.channelRead(.end(nil)), .wait)
        XCTAssertEqual(state.channelInactive(), .wait)
    }

    func testFailHTTP1RequestWithoutContentLengthWithNIOSSLErrorUncleanShutdownButIgnoreIt() {
        var state = HTTPRequestStateMachine(isChannelWritable: true, ignoreUncleanSSLShutdown: true)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .none)
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: false))

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok)
        let body = ByteBuffer(string: "foo bar")
        XCTAssertEqual(state.channelRead(.head(responseHead)), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        XCTAssertEqual(state.demandMoreResponseBodyParts(), .wait)
        XCTAssertEqual(state.read(), .read)
        XCTAssertEqual(state.channelRead(.body(body)), .wait)
        XCTAssertEqual(state.channelReadComplete(), .forwardResponseBodyParts([body]))
        XCTAssertEqual(state.errorHappened(NIOSSLError.uncleanShutdown), .wait)
        XCTAssertEqual(state.channelRead(.end(nil)), .succeedRequest(.close, []))
        XCTAssertEqual(state.channelInactive(), .wait)
    }

    func testFailHTTP1RequestWithContentLengthWithNIOSSLErrorUncleanShutdownButIgnoreIt() {
        var state = HTTPRequestStateMachine(isChannelWritable: true, ignoreUncleanSSLShutdown: true)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .none)
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: false))

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok, headers: ["content-length": "30"])
        let body = ByteBuffer(string: "foo bar")
        XCTAssertEqual(state.channelRead(.head(responseHead)), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        XCTAssertEqual(state.demandMoreResponseBodyParts(), .wait)
        XCTAssertEqual(state.read(), .read)
        XCTAssertEqual(state.channelRead(.body(body)), .wait)
        XCTAssertEqual(state.channelReadComplete(), .forwardResponseBodyParts([body]))
        XCTAssertEqual(state.errorHappened(NIOSSLError.uncleanShutdown), .wait)
        XCTAssertEqual(state.errorHappened(HTTPParserError.invalidEOFState), .failRequest(HTTPParserError.invalidEOFState, .close))
        XCTAssertEqual(state.channelInactive(), .wait)
    }

    func testFailHTTPRequestWithContentLengthBecauseOfChannelInactiveWaitingForDemand() {
        var state = HTTPRequestStateMachine(isChannelWritable: true, ignoreUncleanSSLShutdown: false)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .none)
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: false))

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok, headers: ["Content-Length": "50"])
        let body = ByteBuffer(string: "foo bar")
        XCTAssertEqual(state.channelRead(.head(responseHead)), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        XCTAssertEqual(state.demandMoreResponseBodyParts(), .wait)
        XCTAssertEqual(state.channelReadComplete(), .wait)
        XCTAssertEqual(state.read(), .read)
        XCTAssertEqual(state.channelRead(.body(body)), .wait)
        XCTAssertEqual(state.channelReadComplete(), .forwardResponseBodyParts([body]))
        XCTAssertEqual(state.read(), .wait)

        XCTAssertEqual(state.channelRead(.body(ByteBuffer(string: " baz lightyear"))), .wait)
        XCTAssertEqual(state.channelReadComplete(), .wait)
        XCTAssertEqual(state.channelInactive(), .failRequest(HTTPClientError.remoteConnectionClosed, .none))
    }

    func testFailHTTPRequestWithContentLengthBecauseOfChannelInactiveWaitingForRead() {
        var state = HTTPRequestStateMachine(isChannelWritable: true, ignoreUncleanSSLShutdown: false)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .none)
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: false))

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok, headers: ["Content-Length": "50"])
        let body = ByteBuffer(string: "foo bar")
        XCTAssertEqual(state.channelRead(.head(responseHead)), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        XCTAssertEqual(state.demandMoreResponseBodyParts(), .wait)
        XCTAssertEqual(state.channelReadComplete(), .wait)
        XCTAssertEqual(state.read(), .read)
        XCTAssertEqual(state.channelRead(.body(body)), .wait)
        XCTAssertEqual(state.channelReadComplete(), .forwardResponseBodyParts([body]))
        XCTAssertEqual(state.demandMoreResponseBodyParts(), .wait)

        XCTAssertEqual(state.channelRead(.body(ByteBuffer(string: " baz lightyear"))), .wait)
        XCTAssertEqual(state.channelReadComplete(), .wait)
        XCTAssertEqual(state.channelInactive(), .failRequest(HTTPClientError.remoteConnectionClosed, .none))
    }

    func testFailHTTPRequestWithContentLengthBecauseOfChannelInactiveWaitingForReadAndDemand() {
        var state = HTTPRequestStateMachine(isChannelWritable: true, ignoreUncleanSSLShutdown: false)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        let metadata = RequestFramingMetadata(connectionClose: false, body: .none)
        XCTAssertEqual(state.startRequest(head: requestHead, metadata: metadata), .sendRequestHead(requestHead, startBody: false))

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok, headers: ["Content-Length": "50"])
        let body = ByteBuffer(string: "foo bar")
        XCTAssertEqual(state.channelRead(.head(responseHead)), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        XCTAssertEqual(state.demandMoreResponseBodyParts(), .wait)
        XCTAssertEqual(state.channelReadComplete(), .wait)
        XCTAssertEqual(state.read(), .read)
        XCTAssertEqual(state.channelRead(.body(body)), .wait)
        XCTAssertEqual(state.channelReadComplete(), .forwardResponseBodyParts([body]))

        XCTAssertEqual(state.channelRead(.body(ByteBuffer(string: " baz lightyear"))), .wait)
        XCTAssertEqual(state.channelReadComplete(), .wait)
        XCTAssertEqual(state.channelInactive(), .failRequest(HTTPClientError.remoteConnectionClosed, .none))
    }
}

extension HTTPRequestStateMachine.Action: Equatable {
    public static func == (lhs: HTTPRequestStateMachine.Action, rhs: HTTPRequestStateMachine.Action) -> Bool {
        switch (lhs, rhs) {
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

        case (.wait, .wait):
            return true

        default:
            return false
        }
    }
}
