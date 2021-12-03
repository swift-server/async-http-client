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

#if compiler(>=5.5) && canImport(_Concurrency)
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOSSL

@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
final class Transaction {
    let logger: Logger

    let request: HTTPClientRequest.Prepared

    let connectionDeadline: NIODeadline
    let preferredEventLoop: EventLoop
    let requestOptions: RequestOptions

    private let stateLock = Lock()
    private var state: StateMachine = .init()

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

        self.state.registerContinuation(responseContinuation)
    }

    func cancel() {
        self.fail(HTTPClientError.cancelled)
    }

    // MARK: Request body helpers

    private func writeOnceAndOneTimeOnly(byteBuffer: ByteBuffer) {
        // TODO: @fabianfett
        let writeAction = self.stateLock.withLock {
            self.state.producedNextRequestPart(byteBuffer)
        }
        guard case .write(let part, let executor, true) = writeAction else {
            preconditionFailure("")
        }
        executor.writeRequestBodyPart(.byteBuffer(part), request: self)

        let finishAction = self.stateLock.withLock {
            self.state.finishRequestBodyStream()
        }

        guard case .forwardStreamFinished(let executor) = finishAction else {
            preconditionFailure("")
        }
        executor.finishRequestBodyStream(self)
    }

    private func continueRequestBodyStream(
        _ allocator: ByteBufferAllocator,
        next: @escaping ((ByteBufferAllocator) async throws -> ByteBuffer?)
    ) {
        Task {
            do {
                while let part = try await next(allocator) { // <---- dispatch point!
                    switch self.requestBodyStreamNextPart(part) {
                    case .pause:
                        return
                    case .continue:
                        continue
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

    enum AfterNextBodyPartAction {
        case `continue`
        case pause
    }

    private func requestBodyStreamNextPart(_ part: ByteBuffer) -> AfterNextBodyPartAction {
        let writeAction = self.stateLock.withLock {
            self.state.producedNextRequestPart(part)
        }

        switch writeAction {
        case .write(let part, let executor, let continueAfter):
            executor.writeRequestBodyPart(.byteBuffer(part), request: self)
            if continueAfter {
                return .continue
            } else {
                return .pause
            }

        case .ignore:
            // we only ignore reads, if the request has failed anyway. we should leave
            // the reader loop
            return .pause
        }
    }

    private func requestBodyStreamFinished() {
        let finishAction = self.stateLock.withLock {
            self.state.finishRequestBodyStream()
        }

        switch finishAction {
        case .none:
            // no more data to produce
            break

        case .forwardStreamFinished(let executor):
            executor.finishRequestBodyStream(self)
        }
        return
    }

    private func requestBodyStreamFailed(_ error: Error) {
        self.fail(error)
    }
}

// MARK: - Protocol Methods -

@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
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

@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
extension Transaction: HTTPExecutableRequest {
    var requestHead: HTTPRequestHead { self.request.head }
    var requestBody: HTTPClientRequest.Body? { self.request.body }

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

        case .resumeStream(let allocator):
            switch self.request.body?.mode {
            case .asyncSequence(_, let next):
                // it is safe to call this async here. it dispatches...
                self.continueRequestBodyStream(allocator, next: next)

            case .byteBuffer(let byteBuffer):
                self.writeOnceAndOneTimeOnly(byteBuffer: byteBuffer)

            case .none:
                break

            case .sequence(_, let create):
                let byteBuffer = create(allocator)
                self.writeOnceAndOneTimeOnly(byteBuffer: byteBuffer)
            }
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

        switch action {
        case .none:
            break

        case .failResponseHead(let continuation, let error, let scheduler, let executor):
            continuation.resume(throwing: error)
            scheduler?.cancelRequest(self) // NOTE: scheduler and executor are exclusive here
            executor?.cancelRequest(self)

        case .failResponseStream(let continuation, let error, let executor):
            continuation.resume(throwing: error)
            executor.cancelRequest(self)
        }
    }
}

@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
extension Transaction {
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
            }
        }
    }

    func cancelResponseStream(streamID: HTTPClientResponse.Body.IteratorStream.ID) {
        self.cancel()
    }
}
#endif
