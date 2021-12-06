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
import NIOConcurrencyHelpers
import NIOCore

// This is a MockRequestExecutor, that is synchronized on its EventLoop.
final class MockRequestExecutor {
    enum Errors: Error {
        case eof
        case unexpectedFileRegion
        case unexpectedByteBuffer
    }

    enum RequestParts: Equatable {
        case body(IOData)
        case endOfStream

        var isBody: Bool {
            switch self {
            case .body:
                return true
            case .endOfStream:
                return false
            }
        }
    }

    let eventLoop: EventLoop
    let _blockingQueue = BlockingQueue<RequestParts>()
    let pauseRequestBodyPartStreamAfterASingleWrite: Bool

    var isCancelled: Bool {
        if self.eventLoop.inEventLoop {
            return self._isCancelled
        } else {
            return try! self.eventLoop.submit { self._isCancelled }.wait()
        }
    }

    var signalledDemandForResponseBody: Bool {
        if self.eventLoop.inEventLoop {
            return self._signaledDemandForResponseBody
        } else {
            return try! self.eventLoop.submit { self._signaledDemandForResponseBody }.wait()
        }
    }

    var requestBodyPartsCount: Int {
        return self._blockingQueue.count
    }

    private var request: HTTPExecutableRequest?
    private var _requestBodyParts = CircularBuffer<RequestParts>()
    private var _signaledDemandForRequestBody: Bool = false
    private var _signaledDemandForResponseBody: Bool = false
    private var _whenWritable: EventLoopPromise<RequestParts>?
    private var _isCancelled: Bool = false

    init(pauseRequestBodyPartStreamAfterASingleWrite: Bool = false, eventLoop: EventLoop) {
        self.pauseRequestBodyPartStreamAfterASingleWrite = pauseRequestBodyPartStreamAfterASingleWrite
        self.eventLoop = eventLoop
    }

    func runRequest(_ request: HTTPExecutableRequest) {
        if self.eventLoop.inEventLoop {
            self.runRequest0(request)
        } else {
            self.eventLoop.execute {
                self.runRequest0(request)
            }
        }
    }

    private func runRequest0(_ request: HTTPExecutableRequest) {
        precondition(self.request == nil)
        self.request = request
        request.willExecuteRequest(self)
        request.requestHeadSent()
    }

    func receiveRequestBody(deadline: NIODeadline = .now() + .seconds(60), _ verify: (ByteBuffer) throws -> Void) throws {
        enum ReceiveAction {
            case value(RequestParts)
            case future(EventLoopFuture<RequestParts>)
        }

        switch try self._blockingQueue.popFirst(deadline: deadline) {
        case .body(.byteBuffer(let buffer)):
            try verify(buffer)
        case .body(.fileRegion):
            throw Errors.unexpectedFileRegion
        case .endOfStream:
            throw Errors.eof
        }
    }

    func receiveEndOfStream(deadline: NIODeadline = .now() + .seconds(60)) throws {
        enum ReceiveAction {
            case value(RequestParts)
            case future(EventLoopFuture<RequestParts>)
        }

        switch try self._blockingQueue.popFirst(deadline: deadline) {
        case .body(.byteBuffer):
            throw Errors.unexpectedByteBuffer
        case .body(.fileRegion):
            throw Errors.unexpectedFileRegion
        case .endOfStream:
            break
        }
    }

    func pauseRequestBodyStream() {
        if self.eventLoop.inEventLoop {
            self.pauseRequestBodyStream0()
        } else {
            self.eventLoop.execute {
                self.pauseRequestBodyStream0()
            }
        }
    }

    private func pauseRequestBodyStream0() {
        if self._signaledDemandForRequestBody == true {
            self._signaledDemandForRequestBody = false
            self.request!.pauseRequestBodyStream()
        }
    }

    func resumeRequestBodyStream() {
        if self.eventLoop.inEventLoop {
            self.resumeRequestBodyStream0()
        } else {
            self.eventLoop.execute {
                self.resumeRequestBodyStream0()
            }
        }
    }

    private func resumeRequestBodyStream0() {
        if self._signaledDemandForRequestBody == false {
            self._signaledDemandForRequestBody = true
            self.request!.resumeRequestBodyStream()
        }
    }

    func resetResponseStreamDemandSignal() {
        if self.eventLoop.inEventLoop {
            self.resetResponseStreamDemandSignal0()
        } else {
            self.eventLoop.execute {
                self.resetResponseStreamDemandSignal0()
            }
        }
    }

    private func resetResponseStreamDemandSignal0() {
        self._signaledDemandForResponseBody = false
    }
}

extension MockRequestExecutor: HTTPRequestExecutor {
    // this should always be called twice. When we receive the first call, the next call to produce
    // data is already scheduled. If we call pause here, once, after the second call new subsequent
    // calls should not be scheduled.
    func writeRequestBodyPart(_ part: IOData, request: HTTPExecutableRequest) {
        self.writeNextRequestPart(.body(part), request: request)
    }

    func finishRequestBodyStream(_ request: HTTPExecutableRequest) {
        self.writeNextRequestPart(.endOfStream, request: request)
    }

    private func writeNextRequestPart(_ part: RequestParts, request: HTTPExecutableRequest) {
        enum WriteAction {
            case pauseBodyStream
            case none
        }

        let stateChange = { () -> WriteAction in
            var pause = false
            if self._blockingQueue.isEmpty && self.pauseRequestBodyPartStreamAfterASingleWrite && part.isBody {
                pause = true
                self._signaledDemandForRequestBody = false
            }

            self._blockingQueue.append(.success(part))

            return pause ? .pauseBodyStream : .none
        }

        let action: WriteAction
        if self.eventLoop.inEventLoop {
            action = stateChange()
        } else {
            action = try! self.eventLoop.submit(stateChange).wait()
        }

        switch action {
        case .pauseBodyStream:
            request.pauseRequestBodyStream()
        case .none:
            return
        }
    }

    func demandResponseBodyStream(_: HTTPExecutableRequest) {
        if self.eventLoop.inEventLoop {
            self._signaledDemandForResponseBody = true
        } else {
            self.eventLoop.execute { self._signaledDemandForResponseBody = true }
        }
    }

    func cancelRequest(_: HTTPExecutableRequest) {
        if self.eventLoop.inEventLoop {
            self._isCancelled = true
        } else {
            self.eventLoop.execute { self._isCancelled = true }
        }
    }
}

extension MockRequestExecutor {
    final class BlockingQueue<Element> {
        private let condition = ConditionLock(value: false)
        private var buffer = CircularBuffer<Result<Element, Error>>()

        public struct TimeoutError: Error {}

        internal func append(_ element: Result<Element, Error>) {
            self.condition.lock()
            self.buffer.append(element)
            self.condition.unlock(withValue: true)
        }

        internal var isEmpty: Bool {
            self.condition.lock()
            defer { self.condition.unlock() }
            return self.buffer.isEmpty
        }

        internal var count: Int {
            self.condition.lock()
            defer { self.condition.unlock() }
            return self.buffer.count
        }

        internal func popFirst(deadline: NIODeadline) throws -> Element {
            let secondsUntilDeath = deadline - NIODeadline.now()
            guard self.condition.lock(whenValue: true,
                                      timeoutSeconds: .init(secondsUntilDeath.nanoseconds / 1_000_000_000)) else {
                throw TimeoutError()
            }
            let first = self.buffer.removeFirst()
            self.condition.unlock(withValue: !self.buffer.isEmpty)
            return try first.get()
        }
    }
}
