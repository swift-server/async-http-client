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
import XCTest

class HTTPRequestStateMachineTests: XCTestCase {
    func testSimpleGETRequest() {
        var state = HTTPRequestStateMachine(isChannelWritable: true, idleReadTimeout: nil)
        XCTAssertEqual(state.start(), .verifyRequest)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        XCTAssertEqual(state.requestVerified(requestHead), .sendRequestHead(requestHead, startBody: false))

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok)
        XCTAssertEqual(state.receivedHTTPResponseHead(responseHead), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        let responseBody = ByteBuffer(bytes: [1, 2, 3, 4])
        XCTAssertEqual(state.receivedHTTPResponseBodyPart(responseBody), .forwardResponseBodyPart(responseBody))
        XCTAssertEqual(state.receivedHTTPResponseEnd(), .succeedRequest(.none))
    }

    func testPOSTRequestWithWriterBackpressure() {
        var state = HTTPRequestStateMachine(isChannelWritable: true, idleReadTimeout: nil)
        XCTAssertEqual(state.start(), .verifyRequest)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/", headers: HTTPHeaders([("content-length", "4")]))
        XCTAssertEqual(state.requestVerified(requestHead), .sendRequestHead(requestHead, startBody: true))
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
        XCTAssertEqual(state.receivedHTTPResponseHead(responseHead), .forwardResponseHead(responseHead, pauseRequestBodyStream: false))
        let responseBody = ByteBuffer(bytes: [1, 2, 3, 4])
        XCTAssertEqual(state.receivedHTTPResponseBodyPart(responseBody), .forwardResponseBodyPart(responseBody))
        XCTAssertEqual(state.receivedHTTPResponseEnd(), .succeedRequest(.none))
    }

    func testPOSTContentLengthIsTooLong() {
        var state = HTTPRequestStateMachine(isChannelWritable: true, idleReadTimeout: nil)
        XCTAssertEqual(state.start(), .verifyRequest)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/", headers: HTTPHeaders([("content-length", "4")]))
        XCTAssertEqual(state.requestVerified(requestHead), .sendRequestHead(requestHead, startBody: true))
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
        var state = HTTPRequestStateMachine(isChannelWritable: true, idleReadTimeout: nil)
        XCTAssertEqual(state.start(), .verifyRequest)
        let requestHead = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/", headers: HTTPHeaders([("content-length", "8")]))
        XCTAssertEqual(state.requestVerified(requestHead), .sendRequestHead(requestHead, startBody: true))
        let part0 = IOData.byteBuffer(ByteBuffer(bytes: [0, 1, 2, 3]))
        XCTAssertEqual(state.requestStreamPartReceived(part0), .sendBodyPart(part0))

        let failAction = state.requestStreamFinished()
        guard case .failRequest(let error, .close) = failAction else {
            return XCTFail("Unexpected action: \(failAction)")
        }

        XCTAssertEqual(error as? HTTPClientError, .bodyLengthMismatch)
    }
}

extension HTTPRequestStateMachine.Action: Equatable {
    public static func == (lhs: HTTPRequestStateMachine.Action, rhs: HTTPRequestStateMachine.Action) -> Bool {
        switch (lhs, rhs) {
        case (.verifyRequest, .verifyRequest):
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
