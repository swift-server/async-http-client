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

import NIOConcurrencyHelpers
import NIOCore

@testable import AsyncHTTPClient

// This is a MockRequestExecutor, that is synchronized on its EventLoop.
final class MockRequestExecutor {
    enum Errors: Error {
        case eof
        case unexpectedFileRegion
        case unexpectedByteBuffer
    }

    enum RequestParts: Equatable, Sendable {
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

    var isCancelled: Bool {
        self.cancellationLock.value
    }

    var signalledDemandForResponseBody: Bool {
        self.responseBodyDemandLock.value
    }

    var requestBodyPartsCount: Int {
        self.blockingQueue.count
    }

    let eventLoop: EventLoop
    let pauseRequestBodyPartStreamAfterASingleWrite: Bool

    private let blockingQueue = BlockingQueue<RequestParts>()
    private let responseBodyDemandLock = ConditionLock(value: false)
    private let cancellationLock = ConditionLock(value: false)

    private struct State: Sendable {
        var request: HTTPExecutableRequest?
        var _signaledDemandForRequestBody: Bool = false
    }

    private let state: NIOLockedValueBox<State>

    init(pauseRequestBodyPartStreamAfterASingleWrite: Bool = false, eventLoop: EventLoop) {
        self.state = NIOLockedValueBox(State())
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
        self.state.withLockedValue {
            precondition($0.request == nil)
            $0.request = request
        }
        request.willExecuteRequest(self)
        request.requestHeadSent()
    }

    func receiveRequestBody(deadline: NIODeadline = .now() + .seconds(5), _ verify: (ByteBuffer) throws -> Void) throws
    {
        enum ReceiveAction {
            case value(RequestParts)
            case future(EventLoopFuture<RequestParts>)
        }

        switch try self.blockingQueue.popFirst(deadline: deadline) {
        case .body(.byteBuffer(let buffer)):
            try verify(buffer)
        case .body(.fileRegion):
            throw Errors.unexpectedFileRegion
        case .endOfStream:
            throw Errors.eof
        }
    }

    func receiveEndOfStream(deadline: NIODeadline = .now() + .seconds(5)) throws {
        enum ReceiveAction {
            case value(RequestParts)
            case future(EventLoopFuture<RequestParts>)
        }

        switch try self.blockingQueue.popFirst(deadline: deadline) {
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
        let request = self.state.withLockedValue {
            if $0._signaledDemandForRequestBody == true {
                $0._signaledDemandForRequestBody = false
                return $0.request
            } else {
                return nil
            }
        }

        request?.pauseRequestBodyStream()
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
        let request = self.state.withLockedValue {
            if $0._signaledDemandForRequestBody == false {
                $0._signaledDemandForRequestBody = true
                return $0.request
            } else {
                return nil
            }
        }

        request?.resumeRequestBodyStream()
    }

    func resetResponseStreamDemandSignal() {
        self.responseBodyDemandLock.lock()
        self.responseBodyDemandLock.unlock(withValue: false)
    }

    func receiveResponseDemand(deadline: NIODeadline = .now() + .seconds(5)) throws {
        let secondsUntilDeath = deadline - NIODeadline.now()
        guard
            self.responseBodyDemandLock.lock(
                whenValue: true,
                timeoutSeconds: .init(secondsUntilDeath.nanoseconds / 1_000_000_000)
            )
        else {
            throw TimeoutError()
        }

        self.responseBodyDemandLock.unlock()
    }

    func receiveCancellation(deadline: NIODeadline = .now() + .seconds(5)) throws {
        let secondsUntilDeath = deadline - NIODeadline.now()
        guard
            self.cancellationLock.lock(
                whenValue: true,
                timeoutSeconds: .init(secondsUntilDeath.nanoseconds / 1_000_000_000)
            )
        else {
            throw TimeoutError()
        }

        self.cancellationLock.unlock()
    }
}

extension MockRequestExecutor: HTTPRequestExecutor {
    // this should always be called twice. When we receive the first call, the next call to produce
    // data is already scheduled. If we call pause here, once, after the second call new subsequent
    // calls should not be scheduled.
    func writeRequestBodyPart(_ part: IOData, request: HTTPExecutableRequest, promise: EventLoopPromise<Void>?) {
        self.writeNextRequestPart(.body(part), request: request)
        promise?.succeed(())
    }

    func finishRequestBodyStream(_ request: HTTPExecutableRequest, promise: EventLoopPromise<Void>?) {
        self.writeNextRequestPart(.endOfStream, request: request)
        promise?.succeed(())
    }

    private func writeNextRequestPart(_ part: RequestParts, request: HTTPExecutableRequest) {
        enum WriteAction {
            case pauseBodyStream
            case none
        }

        let stateChange = { @Sendable () -> WriteAction in
            var pause = false
            if self.blockingQueue.isEmpty && self.pauseRequestBodyPartStreamAfterASingleWrite && part.isBody {
                pause = true
                self.state.withLockedValue {
                    $0._signaledDemandForRequestBody = false
                }
            }

            self.blockingQueue.append(.success(part))

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
        self.responseBodyDemandLock.lock()
        self.responseBodyDemandLock.unlock(withValue: true)
    }

    func cancelRequest(_: HTTPExecutableRequest) {
        self.cancellationLock.lock()
        self.cancellationLock.unlock(withValue: true)
    }
}

extension MockRequestExecutor {
    public struct TimeoutError: Error {}

    final class BlockingQueue<Element> {
        private let condition = ConditionLock(value: false)
        private var buffer = CircularBuffer<Result<Element, Error>>()

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
            guard
                self.condition.lock(
                    whenValue: true,
                    timeoutSeconds: .init(secondsUntilDeath.nanoseconds / 1_000_000_000)
                )
            else {
                throw TimeoutError()
            }
            let first = self.buffer.removeFirst()
            self.condition.unlock(withValue: !self.buffer.isEmpty)
            return try first.get()
        }
    }
}

extension MockRequestExecutor.BlockingQueue: @unchecked Sendable where Element: Sendable {}
