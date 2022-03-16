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

#if compiler(>=5.5.2) && canImport(_Concurrency)
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOSSL

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
final class Transaction: @unchecked Sendable {
    let logger: Logger

    let request: HTTPClientRequest.Prepared

    let connectionDeadline: NIODeadline
    let preferredEventLoop: EventLoop
    let requestOptions: RequestOptions

    private let stateLock = Lock()
    private var state: StateMachine

    init(
        request: HTTPClientRequest.Prepared,
        requestOptions: RequestOptions,
        logger: Logger,
        connectionDeadline: NIODeadline,
        preferredEventLoop: EventLoop,
        responseContinuation: CheckedContinuation<HTTPClientResponse, Error>
    ) {
        self.request = request
        self.requestOptions = requestOptions
        self.logger = logger
        self.connectionDeadline = connectionDeadline
        self.preferredEventLoop = preferredEventLoop
        self.state = StateMachine(responseContinuation)
    }

    func cancel() {
        self.fail(HTTPClientError.cancelled)
    }

    // MARK: Request body helpers

    private func writeOnceAndOneTimeOnly(byteBuffer: ByteBuffer) {
        // This method is synchronously invoked after sending the request head. For this reason we
        // can make a number of assumptions, how the state machine will react.
        let writeAction = self.stateLock.withLock {
            self.state.writeNextRequestPart()
        }

        switch writeAction {
        case .writeAndWait(let executor), .writeAndContinue(let executor):
            executor.writeRequestBodyPart(.byteBuffer(byteBuffer), request: self, promise: nil)

        case .fail:
            // an error/cancellation has happened. we don't need to continue here
            return
        }

        self.requestBodyStreamFinished()
    }

    private func continueRequestBodyStream(
        _ allocator: ByteBufferAllocator,
        next: @escaping ((ByteBufferAllocator) async throws -> ByteBuffer?)
    ) {
        Task {
            do {
                while let part = try await next(allocator) {
                    do {
                        try await self.writeRequestBodyPart(part)
                    } catch {
                        // If a write fails, the request has failed somewhere else. We must exit the
                        // write loop though. We don't need to report the error somewhere.
                        return
                    }
                }

                self.requestBodyStreamFinished()
            } catch {
                // The only chance of reaching this catch block, is an error thrown in the `next`
                // call above.
                self.requestBodyStreamFailed(error)
            }
        }
    }

    struct BreakTheWriteLoopError: Swift.Error {}

    private func writeRequestBodyPart(_ part: ByteBuffer) async throws {
        self.stateLock.lock()
        switch self.state.writeNextRequestPart() {
        case .writeAndContinue(let executor):
            self.stateLock.unlock()
            executor.writeRequestBodyPart(.byteBuffer(part), request: self, promise: nil)

        case .writeAndWait(let executor):
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.state.waitForRequestBodyDemand(continuation: continuation)
                self.stateLock.unlock()

                executor.writeRequestBodyPart(.byteBuffer(part), request: self, promise: nil)
            }

        case .fail:
            self.stateLock.unlock()
            throw BreakTheWriteLoopError()
        }
    }

    private func requestBodyStreamFinished() {
        let finishAction = self.stateLock.withLock {
            self.state.finishRequestBodyStream()
        }

        switch finishAction {
        case .none:
            // an error/cancellation has happened. nothing to do.
            break

        case .forwardStreamFinished(let executor, let succeedContinuation):
            executor.finishRequestBodyStream(self, promise: nil)
            succeedContinuation?.resume(returning: nil)
        }
        return
    }

    private func requestBodyStreamFailed(_ error: Error) {
        self.fail(error)
    }
}

// MARK: - Protocol Methods -

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension Transaction: HTTPSchedulableRequest {
    var poolKey: ConnectionPool.Key { self.request.poolKey }
    var tlsConfiguration: TLSConfiguration? { return nil }
    var requiredEventLoop: EventLoop? { return nil }

    func requestWasQueued(_ scheduler: HTTPRequestScheduler) {
        self.stateLock.withLock {
            self.state.requestWasQueued(scheduler)
        }
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension Transaction: HTTPExecutableRequest {
    var requestHead: HTTPRequestHead { self.request.head }

    var requestFramingMetadata: RequestFramingMetadata { self.request.requestFramingMetadata }

    // MARK: Request

    func willExecuteRequest(_ executor: HTTPRequestExecutor) {
        let action = self.stateLock.withLock {
            self.state.willExecuteRequest(executor)
        }

        switch action {
        case .cancel(let executor):
            executor.cancelRequest(self)

        case .none:
            break
        }
    }

    func requestHeadSent() {}

    func resumeRequestBodyStream() {
        let action = self.stateLock.withLock {
            self.state.resumeRequestBodyStream()
        }

        switch action {
        case .none:
            break

        case .startStream(let allocator):
            switch self.request.body?.mode {
            case .asyncSequence(_, let next):
                // it is safe to call this async here. it dispatches...
                self.continueRequestBodyStream(allocator, next: next)

            case .byteBuffer(let byteBuffer):
                self.writeOnceAndOneTimeOnly(byteBuffer: byteBuffer)

            case .none:
                break

            case .sequence(_, _, let create):
                let byteBuffer = create(allocator)
                self.writeOnceAndOneTimeOnly(byteBuffer: byteBuffer)
            }

        case .resumeStream(let continuation):
            continuation.resume(returning: ())
        }
    }

    func pauseRequestBodyStream() {
        self.stateLock.withLock {
            self.state.pauseRequestBodyStream()
        }
    }

    // MARK: Response

    func receiveResponseHead(_ head: HTTPResponseHead) {
        let action = self.stateLock.withLock {
            self.state.receiveResponseHead(head)
        }

        switch action {
        case .none:
            break

        case .succeedResponseHead(let head, let continuation):
            let asyncResponse = HTTPClientResponse(
                bag: self,
                version: head.version,
                status: head.status,
                headers: head.headers
            )
            continuation.resume(returning: asyncResponse)
        }
    }

    func receiveResponseBodyParts(_ buffer: CircularBuffer<ByteBuffer>) {
        let action = self.stateLock.withLock {
            self.state.receiveResponseBodyParts(buffer)
        }
        switch action {
        case .none:
            break
        case .succeedContinuation(let continuation, let bytes):
            continuation.resume(returning: bytes)
        }
    }

    func succeedRequest(_ buffer: CircularBuffer<ByteBuffer>?) {
        let succeedAction = self.stateLock.withLock {
            self.state.succeedRequest(buffer)
        }
        switch succeedAction {
        case .finishResponseStream(let continuation):
            continuation.resume(returning: nil)
        case .succeedContinuation(let continuation, let byteBuffer):
            continuation.resume(returning: byteBuffer)
        case .none:
            break
        }
    }

    func fail(_ error: Error) {
        let action = self.stateLock.withLock {
            self.state.fail(error)
        }
        self.performFailAction(action)
    }

    private func performFailAction(_ action: StateMachine.FailAction) {
        switch action {
        case .none:
            break

        case .failResponseHead(let continuation, let error, let scheduler, let executor, let bodyStreamContinuation):
            continuation.resume(throwing: error)
            bodyStreamContinuation?.resume(throwing: error)
            scheduler?.cancelRequest(self) // NOTE: scheduler and executor are exclusive here
            executor?.cancelRequest(self)

        case .failResponseStream(let continuation, let error, let executor, let bodyStreamContinuation):
            continuation.resume(throwing: error)
            bodyStreamContinuation?.resume(throwing: error)
            executor.cancelRequest(self)

        case .failRequestStreamContinuation(let bodyStreamContinuation, let error):
            bodyStreamContinuation.resume(throwing: error)
        }
    }

    func deadlineExceeded() {
        let action = self.stateLock.withLock {
            self.state.deadlineExceeded()
        }
        self.performDeadlineExceededAction(action)
    }

    private func performDeadlineExceededAction(_ action: StateMachine.DeadlineExceededAction) {
        switch action {
        case .cancel(let requestContinuation, let scheduler, let executor, let bodyStreamContinuation):
            requestContinuation.resume(throwing: HTTPClientError.deadlineExceeded)
            scheduler?.cancelRequest(self)
            executor?.cancelRequest(self)
            bodyStreamContinuation?.resume(throwing: HTTPClientError.deadlineExceeded)

        case .none:
            break
        }
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension Transaction {
    func responseBodyDeinited() {
        let deinitedAction = self.stateLock.withLock {
            self.state.responseBodyDeinited()
        }

        switch deinitedAction {
        case .cancel(let executor):
            executor.cancelRequest(self)
        case .none:
            break
        }
    }

    func nextResponsePart(streamID: HTTPClientResponse.Body.IteratorStream.ID) async throws -> ByteBuffer? {
        try await withCheckedThrowingContinuation { continuation in
            let action = self.stateLock.withLock {
                self.state.consumeNextResponsePart(streamID: streamID, continuation: continuation)
            }
            switch action {
            case .succeedContinuation(let continuation, let result):
                continuation.resume(returning: result)

            case .failContinuation(let continuation, let error):
                continuation.resume(throwing: error)

            case .askExecutorForMore(let executor):
                executor.demandResponseBodyStream(self)

            case .none:
                return
            }
        }
    }

    func responseBodyIteratorDeinited(streamID: HTTPClientResponse.Body.IteratorStream.ID) {
        let action = self.stateLock.withLock {
            self.state.responseBodyIteratorDeinited(streamID: streamID)
        }
        self.performFailAction(action)
    }
}
#endif
