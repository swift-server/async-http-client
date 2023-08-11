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
import NIOConcurrencyHelpers

@dynamicMemberLookup
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

    let logger: Logging.Logger = Logger(label: "request")
    

    private let file: StaticString
    private let line: UInt
    
    struct State: Sendable {
        var requestHead: NIOHTTP1.HTTPRequestHead
        var requestFramingMetadata: RequestFramingMetadata
        var requestOptions: RequestOptions = .forTests()
        /// if true and ``HTTPExecutableRequest`` method is called without setting a corresponding callback on `self` e.g.
        /// If ``HTTPExecutableRequest\.willExecuteRequest(_:)`` is called but ``willExecuteRequestCallback`` is not set,
        /// ``XCTestFail(_:)`` will be called to fail the current test.
        var raiseErrorIfUnimplementedMethodIsCalled: Bool = true
        var willExecuteRequestCallback: (@Sendable (HTTPRequestExecutor) -> Void)?
        var requestHeadSentCallback: (@Sendable () -> Void)?
        var resumeRequestBodyStreamCallback: (@Sendable () -> Void)?
        var pauseRequestBodyStreamCallback: (@Sendable () -> Void)?
        var receiveResponseHeadCallback: (@Sendable (HTTPResponseHead) -> Void)?
        var receiveResponseBodyPartsCallback: (@Sendable (CircularBuffer<ByteBuffer>) -> Void)?
        var succeedRequestCallback: (@Sendable (CircularBuffer<ByteBuffer>?) -> Void)?
        var failCallback: (@Sendable (Error) -> Void)?
        
        /// captures all ``HTTPExecutableRequest`` method calls in the order of occurrence, including arguments.
        /// If you are not interested in the arguments you can use `events.map(\.kind)` to get all events without arguments.
        fileprivate(set) var events: [Event] = []
    }
    
    private let state: NIOLockedValueBox<State>
    
    var requestHead: NIOHTTP1.HTTPRequestHead {
        get { self.state.withLockedValue { $0.requestHead } }
        set { self.state.withLockedValue { $0.requestHead = newValue } }
    }
    
    var requestFramingMetadata: AsyncHTTPClient.RequestFramingMetadata {
        get { self.state.withLockedValue { $0.requestFramingMetadata } }
        set { self.state.withLockedValue { $0.requestFramingMetadata = newValue } }
    }
    
    var requestOptions: AsyncHTTPClient.RequestOptions {
        get { self.state.withLockedValue { $0.requestOptions } }
        set { self.state.withLockedValue { $0.requestOptions = newValue } }
    }
    
    subscript<Property: Sendable>(dynamicMember keyPath: KeyPath<State, Property>) -> Property {
        state.withLockedValue { $0[keyPath: keyPath] }
    }
    
    subscript<Property: Sendable>(dynamicMember keyPath: WritableKeyPath<State, Property>) -> Property {
        get {
            state.withLockedValue { $0[keyPath: keyPath] }
        }
        set {
            state.withLockedValue { $0[keyPath: keyPath] = newValue }
        }
    }

    init(
        head: NIOHTTP1.HTTPRequestHead = .init(version: .http1_1, method: .GET, uri: "http://localhost/"),
        framingMetadata: RequestFramingMetadata = .init(connectionClose: false, body: .fixedSize(0)),
        file: StaticString = #file,
        line: UInt = #line
    ) {
        self.state = .init(.init(requestHead: head, requestFramingMetadata: framingMetadata))
        self.file = file
        self.line = line
    }

    private func calledUnimplementedMethod(_ name: String) {
        guard self.raiseErrorIfUnimplementedMethodIsCalled else { return }
        XCTFail("\(name) invoked but it is not implemented", file: self.file, line: self.line)
    }

    func willExecuteRequest(_ executor: HTTPRequestExecutor) {
        self.events.append(.willExecuteRequest(executor))
        guard let willExecuteRequestCallback = self.willExecuteRequestCallback else {
            return self.calledUnimplementedMethod(#function)
        }
        willExecuteRequestCallback(executor)
    }

    func requestHeadSent() {
        self.events.append(.requestHeadSent)
        guard let requestHeadSentCallback = self.requestHeadSentCallback else {
            return self.calledUnimplementedMethod(#function)
        }
        requestHeadSentCallback()
    }

    func resumeRequestBodyStream() {
        self.events.append(.resumeRequestBodyStream)
        guard let resumeRequestBodyStreamCallback = self.resumeRequestBodyStreamCallback else {
            return self.calledUnimplementedMethod(#function)
        }
        resumeRequestBodyStreamCallback()
    }

    func pauseRequestBodyStream() {
        self.events.append(.pauseRequestBodyStream)
        guard let pauseRequestBodyStreamCallback = self.pauseRequestBodyStreamCallback else {
            return self.calledUnimplementedMethod(#function)
        }
        pauseRequestBodyStreamCallback()
    }

    func receiveResponseHead(_ head: HTTPResponseHead) {
        self.events.append(.receiveResponseHead(head))
        guard let receiveResponseHeadCallback = self.receiveResponseHeadCallback else {
            return self.calledUnimplementedMethod(#function)
        }
        receiveResponseHeadCallback(head)
    }

    func receiveResponseBodyParts(_ buffer: CircularBuffer<NIOCore.ByteBuffer>) {
        self.events.append(.receiveResponseBodyParts(buffer))
        guard let receiveResponseBodyPartsCallback = self.receiveResponseBodyPartsCallback else {
            return self.calledUnimplementedMethod(#function)
        }
        receiveResponseBodyPartsCallback(buffer)
    }

    func succeedRequest(_ buffer: CircularBuffer<NIOCore.ByteBuffer>?) {
        self.events.append(.succeedRequest(buffer))
        guard let succeedRequestCallback = self.succeedRequestCallback else {
            return self.calledUnimplementedMethod(#function)
        }
        succeedRequestCallback(buffer)
    }

    func fail(_ error: Error) {
        self.events.append(.fail(error))
        guard let failCallback = self.failCallback else {
            return self.calledUnimplementedMethod(#function)
        }
        failCallback(error)
    }
}
