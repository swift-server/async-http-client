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

import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import XCTest

@testable import AsyncHTTPClient

final class MockHTTPExecutableRequest: HTTPExecutableRequest {
    enum Event: Sendable {
        /// ``Event`` without associated values
        enum Kind: Hashable {
            case willExecuteRequest
            case requestHeadSent
            case resumeRequestBodyStream
            case pauseRequestBodyStream
            case requestBodySent
            case receiveResponseHead
            case receiveResponseBodyParts
            case receiveResponseEnd
            case fail
        }

        case willExecuteRequest(HTTPRequestExecutor)
        case requestHeadSent
        case resumeRequestBodyStream
        case pauseRequestBodyStream
        case requestBodySent
        case receiveResponseHead(HTTPResponseHead)
        case receiveResponseBodyParts(CircularBuffer<ByteBuffer>)
        case receiveResponseEnd(CircularBuffer<ByteBuffer>?, HTTPHeaders?)
        case fail(Error)

        var kind: Kind {
            switch self {
            case .willExecuteRequest: return .willExecuteRequest
            case .requestHeadSent: return .requestHeadSent
            case .resumeRequestBodyStream: return .resumeRequestBodyStream
            case .pauseRequestBodyStream: return .pauseRequestBodyStream
            case .requestBodySent: return .requestBodySent
            case .receiveResponseHead: return .receiveResponseHead
            case .receiveResponseBodyParts: return .receiveResponseBodyParts
            case .receiveResponseEnd: return .receiveResponseEnd
            case .fail: return .fail
            }
        }
    }

    let logger: Logging.Logger = Logger(label: "request")
    let requestHead: NIOHTTP1.HTTPRequestHead
    let requestFramingMetadata: RequestFramingMetadata
    let requestOptions: RequestOptions = .forTests()

    /// if true and ``HTTPExecutableRequest`` method is called without setting a corresponding callback on `self` e.g.
    /// If ``HTTPExecutableRequest\.willExecuteRequest(_:)`` is called but ``willExecuteRequestCallback`` is not set,
    /// ``XCTestFail(_:)`` will be called to fail the current test.
    let raiseErrorIfUnimplementedMethodIsCalled: Bool
    private let file: StaticString
    private let line: UInt

    struct Callbacks {
        var willExecuteRequestCallback: (@Sendable (HTTPRequestExecutor) -> Void)? = nil
        var requestHeadSentCallback: (@Sendable () -> Void)? = nil
        var resumeRequestBodyStreamCallback: (@Sendable () -> Void)? = nil
        var pauseRequestBodyStreamCallback: (@Sendable () -> Void)? = nil
        var requestBodyStreamSentCallback: (@Sendable () -> Void)? = nil
        var receiveResponseHeadCallback: (@Sendable (HTTPResponseHead) -> Void)? = nil
        var receiveResponseBodyPartsCallback: (@Sendable (CircularBuffer<ByteBuffer>) -> Void)? = nil
        var receiveResponseEndCallback: (@Sendable (CircularBuffer<ByteBuffer>?, HTTPHeaders?) -> Void)? = nil
        var failCallback: (@Sendable (Error) -> Void)? = nil
    }

    let callbacks: NIOLockedValueBox<Callbacks> = .init(.init())

    var willExecuteRequestCallback: (@Sendable (HTTPRequestExecutor) -> Void)? {
        get { self.callbacks.withLockedValue { $0.willExecuteRequestCallback } }
        set { self.callbacks.withLockedValue { $0.willExecuteRequestCallback = newValue } }
    }

    var requestHeadSentCallback: (@Sendable () -> Void)? {
        get { self.callbacks.withLockedValue { $0.requestHeadSentCallback } }
        set { self.callbacks.withLockedValue { $0.requestHeadSentCallback = newValue } }
    }

    var resumeRequestBodyStreamCallback: (@Sendable () -> Void)? {
        get { self.callbacks.withLockedValue { $0.resumeRequestBodyStreamCallback } }
        set { self.callbacks.withLockedValue { $0.resumeRequestBodyStreamCallback = newValue } }
    }

    var pauseRequestBodyStreamCallback: (@Sendable () -> Void)? {
        get { self.callbacks.withLockedValue { $0.pauseRequestBodyStreamCallback } }
        set { self.callbacks.withLockedValue { $0.pauseRequestBodyStreamCallback = newValue } }
    }

    var requestBodyStreamSentCallback: (@Sendable () -> Void)? {
        get { self.callbacks.withLockedValue { $0.requestBodyStreamSentCallback } }
        set { self.callbacks.withLockedValue { $0.requestBodyStreamSentCallback = newValue } }
    }

    var receiveResponseHeadCallback: (@Sendable (HTTPResponseHead) -> Void)? {
        get { self.callbacks.withLockedValue { $0.receiveResponseHeadCallback } }
        set { self.callbacks.withLockedValue { $0.receiveResponseHeadCallback = newValue } }
    }

    var receiveResponseBodyPartsCallback: (@Sendable (CircularBuffer<ByteBuffer>) -> Void)? {
        get { self.callbacks.withLockedValue { $0.receiveResponseBodyPartsCallback } }
        set { self.callbacks.withLockedValue { $0.receiveResponseBodyPartsCallback = newValue } }
    }

    var receiveResponseEndCallback: (@Sendable (CircularBuffer<ByteBuffer>?, HTTPHeaders?) -> Void)? {
        get { self.callbacks.withLockedValue { $0.receiveResponseEndCallback } }
        set { self.callbacks.withLockedValue { $0.receiveResponseEndCallback = newValue } }
    }

    var failCallback: (@Sendable (Error) -> Void)? {
        get { self.callbacks.withLockedValue { $0.failCallback } }
        set { self.callbacks.withLockedValue { $0.failCallback = newValue } }
    }

    /// captures all ``HTTPExecutableRequest`` method calls in the order of occurrence, including arguments.
    /// If you are not interested in the arguments you can use `events.map(\.kind)` to get all events without arguments.
    private let _events = NIOLockedValueBox<[Event]>([])
    private(set) var events: [Event] {
        get {
            self._events.withLockedValue { $0 }
        }
        set {
            self._events.withLockedValue { $0 = newValue }
        }
    }

    init(
        head: NIOHTTP1.HTTPRequestHead = .init(version: .http1_1, method: .GET, uri: "http://localhost/"),
        framingMetadata: RequestFramingMetadata = .init(connectionClose: false, body: .fixedSize(0)),
        raiseErrorIfUnimplementedMethodIsCalled: Bool = true,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        self.requestHead = head
        self.requestFramingMetadata = framingMetadata
        self.raiseErrorIfUnimplementedMethodIsCalled = raiseErrorIfUnimplementedMethodIsCalled
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

    func requestBodyStreamSent() {
        self.events.append(.requestBodySent)
        guard let requestBodyStreamSentCallback = self.requestBodyStreamSentCallback else {
            return self.calledUnimplementedMethod(#function)
        }
        requestBodyStreamSentCallback()
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

    func receiveResponseEnd(_ buffer: CircularBuffer<ByteBuffer>?, trailers: HTTPHeaders?) {
        self.events.append(.receiveResponseEnd(buffer, trailers))
        guard let receiveResponseEndCallback = self.receiveResponseEndCallback else {
            return self.calledUnimplementedMethod(#function)
        }
        receiveResponseEndCallback(buffer, trailers)
    }

    func fail(_ error: Error) {
        self.events.append(.fail(error))
        guard let failCallback = failCallback else {
            return self.calledUnimplementedMethod(#function)
        }
        failCallback(error)
    }
}
