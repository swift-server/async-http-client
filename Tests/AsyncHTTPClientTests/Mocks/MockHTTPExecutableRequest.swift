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
import NIOCore
import NIOHTTP1
import XCTest

final class MockHTTPExecutableRequest: HTTPExecutableRequest {
    enum Event {
        /// ``Event`` without associated values
        enum Kind: Hashable {
            case willExecuteRequest
            case requestHeadSent
            case resumeRequestBodyStream
            case pauseRequestBodyStream
            case receiveResponseHead
            case receiveResponseBodyParts
            case succeedRequest
            case fail
        }

        case willExecuteRequest(HTTPRequestExecutor)
        case requestHeadSent
        case resumeRequestBodyStream
        case pauseRequestBodyStream
        case receiveResponseHead(HTTPResponseHead)
        case receiveResponseBodyParts(CircularBuffer<ByteBuffer>)
        case succeedRequest(CircularBuffer<ByteBuffer>?)
        case fail(Error)

        var kind: Kind {
            switch self {
            case .willExecuteRequest: return .willExecuteRequest
            case .requestHeadSent: return .requestHeadSent
            case .resumeRequestBodyStream: return .resumeRequestBodyStream
            case .pauseRequestBodyStream: return .pauseRequestBodyStream
            case .receiveResponseHead: return .receiveResponseHead
            case .receiveResponseBodyParts: return .receiveResponseBodyParts
            case .succeedRequest: return .succeedRequest
            case .fail: return .fail
            }
        }
    }

    var logger: Logging.Logger = Logger(label: "request")
    var requestHead: NIOHTTP1.HTTPRequestHead
    var requestFramingMetadata: RequestFramingMetadata
    var requestOptions: RequestOptions = .forTests()

    /// if true and ``HTTPExecutableRequest`` method is called without setting a corresponding callback on `self` e.g.
    /// If ``HTTPExecutableRequest\.willExecuteRequest(_:)`` is called but ``willExecuteRequestCallback`` is not set,
    /// ``XCTestFail(_:)`` will be called to fail the current test.
    var raiseErrorIfUnimplementedMethodIsCalled: Bool = true
    private var file: StaticString
    private var line: UInt

    var willExecuteRequestCallback: ((HTTPRequestExecutor) -> Void)?
    var requestHeadSentCallback: (() -> Void)?
    var resumeRequestBodyStreamCallback: (() -> Void)?
    var pauseRequestBodyStreamCallback: (() -> Void)?
    var receiveResponseHeadCallback: ((HTTPResponseHead) -> Void)?
    var receiveResponseBodyPartsCallback: ((CircularBuffer<ByteBuffer>) -> Void)?
    var succeedRequestCallback: ((CircularBuffer<ByteBuffer>?) -> Void)?
    var failCallback: ((Error) -> Void)?

    /// captures all ``HTTPExecutableRequest`` method calls in the order of occurrence, including arguments.
    /// If you are not interested in the arguments you can use `events.map(\.kind)` to get all events without arguments.
    private(set) var events: [Event] = []

    init(
        head: NIOHTTP1.HTTPRequestHead = .init(version: .http1_1, method: .GET, uri: "http://localhost/"),
        framingMetadata: RequestFramingMetadata = .init(connectionClose: false, body: .fixedSize(0)),
        file: StaticString = #file,
        line: UInt = #line
    ) {
        self.requestHead = head
        self.requestFramingMetadata = framingMetadata
        self.file = file
        self.line = line
    }

    private func calledUnimplementedMethod(_ name: String) {
        guard self.raiseErrorIfUnimplementedMethodIsCalled else { return }
        XCTFail("\(name) invoked but it is not implemented", file: self.file, line: self.line)
    }

    func willExecuteRequest(_ executor: HTTPRequestExecutor) {
        self.events.append(.willExecuteRequest(executor))
        guard let willExecuteRequestCallback = willExecuteRequestCallback else {
            return self.calledUnimplementedMethod(#function)
        }
        willExecuteRequestCallback(executor)
    }

    func requestHeadSent() {
        self.events.append(.requestHeadSent)
        guard let requestHeadSentCallback = requestHeadSentCallback else {
            return self.calledUnimplementedMethod(#function)
        }
        requestHeadSentCallback()
    }

    func resumeRequestBodyStream() {
        self.events.append(.resumeRequestBodyStream)
        guard let resumeRequestBodyStreamCallback = resumeRequestBodyStreamCallback else {
            return self.calledUnimplementedMethod(#function)
        }
        resumeRequestBodyStreamCallback()
    }

    func pauseRequestBodyStream() {
        self.events.append(.pauseRequestBodyStream)
        guard let pauseRequestBodyStreamCallback = pauseRequestBodyStreamCallback else {
            return self.calledUnimplementedMethod(#function)
        }
        pauseRequestBodyStreamCallback()
    }

    func receiveResponseHead(_ head: HTTPResponseHead) {
        self.events.append(.receiveResponseHead(head))
        guard let receiveResponseHeadCallback = receiveResponseHeadCallback else {
            return self.calledUnimplementedMethod(#function)
        }
        receiveResponseHeadCallback(head)
    }

    func receiveResponseBodyParts(_ buffer: CircularBuffer<NIOCore.ByteBuffer>) {
        self.events.append(.receiveResponseBodyParts(buffer))
        guard let receiveResponseBodyPartsCallback = receiveResponseBodyPartsCallback else {
            return self.calledUnimplementedMethod(#function)
        }
        receiveResponseBodyPartsCallback(buffer)
    }

    func succeedRequest(_ buffer: CircularBuffer<NIOCore.ByteBuffer>?) {
        self.events.append(.succeedRequest(buffer))
        guard let succeedRequestCallback = succeedRequestCallback else {
            return self.calledUnimplementedMethod(#function)
        }
        succeedRequestCallback(buffer)
    }

    func fail(_ error: Error) {
        self.events.append(.fail(error))
        guard let failCallback = failCallback else {
            return self.calledUnimplementedMethod(#function)
        }
        failCallback(error)
    }
}
