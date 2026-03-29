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
import NIOCore
import NIOHTTP1

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension Transaction {
    @usableFromInline
    struct StateMachine {
        struct ExecutionContext {
            let executor: HTTPRequestExecutor
            let allocator: ByteBufferAllocator
            let continuation: CheckedContinuation<HTTPClientResponse, Error>
        }

        private enum State {
            case initialized(CheckedContinuation<HTTPClientResponse, Error>)
            case queued(CheckedContinuation<HTTPClientResponse, Error>, HTTPRequestScheduler)
            case deadlineExceededWhileQueued(CheckedContinuation<HTTPClientResponse, Error>)
            case executing(ExecutionContext, RequestStreamState, ResponseStreamState)
            case finished(error: Error?)
        }

        fileprivate enum RequestStreamState: Sendable {
            case requestHeadSent
            case producing
            case paused(continuation: CheckedContinuation<Void, Error>?)
            case finished
        }

        fileprivate enum ResponseStreamState: Sendable {
            // Waiting for response head. Valid transitions to: streamingBody.
            case waitingForResponseHead
            // streaming response body. Valid transitions to: finished.
            case streamingBody(TransactionBody.Source)
            case finished
        }

        private var state: State

        init(_ continuation: CheckedContinuation<HTTPClientResponse, Error>) {
            self.state = .initialized(continuation)
        }

        mutating func requestWasQueued(_ scheduler: HTTPRequestScheduler) {
            guard case .initialized(let continuation) = self.state else {
                // There might be a race between `requestWasQueued` and `willExecuteRequest`:
                //
                // If the request is created and passed to the HTTPClient on thread A, it will move into
                // the connection pool lock in thread A. If no connection is available, thread A will
                // add the request to the waiters and leave the connection pool lock.
                // `requestWasQueued` will be called outside the connection pool lock on thread A.
                // However if thread B has a connection that becomes available and thread B enters the
                // connection pool lock directly after thread A, the request will be immediately
                // scheduled for execution on thread B. After the thread B has left the lock it will
                // call `willExecuteRequest` directly after.
                //
                // Having an order in the connection pool lock, does not guarantee an order in calling:
                // `requestWasQueued` and `willExecuteRequest`.
                //
                // For this reason we must check the state here... If we are not `.initialized`, we are
                // already executing.
                return
            }

            self.state = .queued(continuation, scheduler)
        }

        enum FailAction {
            case none
            /// fail response before head received. scheduler and executor are exclusive here.
            case failResponseHead(
                CheckedContinuation<HTTPClientResponse, Error>,
                Error,
                HTTPRequestScheduler?,
                HTTPRequestExecutor?,
                bodyStreamContinuation: CheckedContinuation<Void, Error>?
            )
            /// fail response after response head received. fail the response stream (aka call to `next()`)
            case failResponseStream(
                TransactionBody.Source,
                Error,
                HTTPRequestExecutor,
                bodyStreamContinuation: CheckedContinuation<Void, Error>?
            )

            case failRequestStreamContinuation(CheckedContinuation<Void, Error>, Error)
        }

        mutating func fail(_ error: Error) -> FailAction {
            switch self.state {
            case .initialized(let continuation):
                self.state = .finished(error: error)
                return .failResponseHead(continuation, error, nil, nil, bodyStreamContinuation: nil)

            case .queued(let continuation, let scheduler):
                self.state = .finished(error: error)
                return .failResponseHead(continuation, error, scheduler, nil, bodyStreamContinuation: nil)
            case .deadlineExceededWhileQueued(let continuation):
                let realError: Error = {
                    if (error as? HTTPClientError) == .cancelled {
                        /// if we just get a `HTTPClientError.cancelled` we can use the original cancellation reason
                        /// to give a more descriptive error to the user.
                        return HTTPClientError.deadlineExceeded
                    } else {
                        /// otherwise we already had an intermediate connection error which we should present to the user instead
                        return error
                    }
                }()

                self.state = .finished(error: realError)
                return .failResponseHead(continuation, realError, nil, nil, bodyStreamContinuation: nil)
            case .executing(let context, let requestStreamState, .waitingForResponseHead):
                switch requestStreamState {
                case .paused(continuation: .some(let continuation)):
                    self.state = .finished(error: error)
                    return .failResponseHead(
                        context.continuation,
                        error,
                        nil,
                        context.executor,
                        bodyStreamContinuation: continuation
                    )

                case .requestHeadSent, .finished, .producing, .paused(continuation: .none):
                    self.state = .finished(error: error)
                    return .failResponseHead(
                        context.continuation,
                        error,
                        nil,
                        context.executor,
                        bodyStreamContinuation: nil
                    )
                }

            case .executing(let context, let requestStreamState, .streamingBody(let source)):
                self.state = .finished(error: error)
                switch requestStreamState {
                case .paused(let bodyStreamContinuation):
                    return .failResponseStream(
                        source,
                        error,
                        context.executor,
                        bodyStreamContinuation: bodyStreamContinuation
                    )
                case .finished, .producing, .requestHeadSent:
                    return .failResponseStream(source, error, context.executor, bodyStreamContinuation: nil)
                }

            case .finished(error: _),
                .executing(_, _, .finished):
                return .none
            }
        }

        // MARK: - Request -

        enum StartExecutionAction {
            case cancel(HTTPRequestExecutor)
            case cancelAndFail(HTTPRequestExecutor, CheckedContinuation<HTTPClientResponse, Error>, with: Error)
            case none
        }

        mutating func willExecuteRequest(_ executor: HTTPRequestExecutor) -> StartExecutionAction {
            switch self.state {
            case .initialized(let continuation), .queued(let continuation, _):
                let context = ExecutionContext(
                    executor: executor,
                    allocator: .init(),
                    continuation: continuation
                )
                self.state = .executing(context, .requestHeadSent, .waitingForResponseHead)
                return .none
            case .deadlineExceededWhileQueued(let continuation):
                let error = HTTPClientError.deadlineExceeded
                self.state = .finished(error: error)
                return .cancelAndFail(executor, continuation, with: error)

            case .finished(error: .some):
                return .cancel(executor)

            case .executing,
                .finished(error: .none):
                preconditionFailure("Invalid state: \(self.state)")
            }
        }

        enum ResumeProducingAction {
            case startStream(ByteBufferAllocator)
            case resumeStream(CheckedContinuation<Void, Error>)
            case none
        }

        mutating func resumeRequestBodyStream() -> ResumeProducingAction {
            switch self.state {
            case .initialized, .queued, .deadlineExceededWhileQueued:
                preconditionFailure(
                    "Received a resumeBodyRequest on a request, that isn't executing. Invalid state: \(self.state)"
                )

            case .executing(let context, .requestHeadSent, let responseState):
                // the request can start to send its body.
                self.state = .executing(context, .producing, responseState)
                return .startStream(context.allocator)

            case .executing(_, .producing, _):
                preconditionFailure(
                    "Received a resumeBodyRequest on a request, that is producing. Invalid state: \(self.state)"
                )

            case .executing(let context, .paused(.none), let responseState):
                // request stream is currently paused, but there is no write waiting. We don't need
                // to do anything.
                self.state = .executing(context, .producing, responseState)
                return .none

            case .executing(let context, .paused(.some(let continuation)), let responseState):
                // the request body was paused. we can start the body streaming again.
                self.state = .executing(context, .producing, responseState)
                return .resumeStream(continuation)

            case .executing(_, .finished, _):
                // the channels writability changed to writable after we have forwarded all the
                // request bytes. Can be ignored.
                return .none

            case .finished:
                return .none
            }
        }

        mutating func pauseRequestBodyStream() {
            switch self.state {
            case .initialized,
                .queued,
                .deadlineExceededWhileQueued,
                .executing(_, .requestHeadSent, _):
                preconditionFailure("A request stream can only be resumed, if the request was started")

            case .executing(let context, .producing, let responseSteam):
                self.state = .executing(context, .paused(continuation: nil), responseSteam)

            case .executing(_, .paused, _),
                .executing(_, .finished, _),
                .finished:
                // the channels writability changed to paused after we have already forwarded all
                // request bytes. Can be ignored.
                break
            }
        }

        enum NextWriteAction {
            case writeAndContinue(HTTPRequestExecutor)
            case writeAndWait(HTTPRequestExecutor)
            case fail
        }

        func writeNextRequestPart() -> NextWriteAction {
            switch self.state {
            case .initialized,
                .queued,
                .deadlineExceededWhileQueued,
                .executing(_, .requestHeadSent, _):
                preconditionFailure(
                    "A request stream can only produce, if the request was started. Invalid state: \(self.state)"
                )

            case .executing(let context, .producing, _):
                // We are currently producing the request body. The executors channel is writable.
                // For this reason we can continue to produce data.
                return .writeAndContinue(context.executor)

            case .executing(let context, .paused(continuation: .none), _):
                // We are currently pausing the request body, since the executor's channel is not
                // writable. We receive this call, since we were writable when we received the last
                // data. At that point, we wanted to produce more. While waiting for more request
                // bytes, the channel became not writable.
                //
                // Now is the point to pause producing. The user is required to call
                //   `writeNextRequestPart(continuation: )` next.
                return .writeAndWait(context.executor)

            case .executing(_, .paused(continuation: .some), _):
                preconditionFailure(
                    "A write continuation already exists, but we tried to set another one. Invalid state: \(self.state)"
                )

            case .finished, .executing(_, .finished, _):
                return .fail
            }
        }

        mutating func waitForRequestBodyDemand(continuation: CheckedContinuation<Void, Error>) {
            switch self.state {
            case .initialized,
                .queued,
                .deadlineExceededWhileQueued,
                .executing(_, .requestHeadSent, _),
                .executing(_, .finished, _):
                preconditionFailure(
                    "A request stream can only produce, if the request was started. Invalid state: \(self.state)"
                )

            case .executing(_, .producing, _):
                preconditionFailure()

            case .executing(_, .paused(continuation: .some), _):
                preconditionFailure()

            case .executing(let context, .paused(continuation: .none), let responseState):
                // We are currently pausing the request body, since the executor's channel is not
                // writable. We receive this call, since we were writable when we received the last
                // data. At that point, we wanted to produce more. While waiting for more request
                // bytes, the channel became not writable. Now is the point to pause producing.
                self.state = .executing(context, .paused(continuation: continuation), responseState)

            case .finished:
                preconditionFailure()
            }
        }

        enum FinishAction {
            // forward the notice that the request stream has finished.
            case forwardStreamFinished(HTTPRequestExecutor)
            case none
        }

        mutating func finishRequestBodyStream() -> FinishAction {
            switch self.state {
            case .initialized,
                .queued,
                .deadlineExceededWhileQueued,
                .executing(_, .finished, _):
                preconditionFailure("Invalid state: \(self.state)")

            case .executing(_, .paused(continuation: .some), _):
                preconditionFailure(
                    "Received a request body end, while having a registered back-pressure continuation. Invalid state: \(self.state)"
                )

            case .executing(let context, .producing, let responseState),
                .executing(let context, .paused(continuation: .none), let responseState),
                .executing(let context, .requestHeadSent, let responseState):

                switch responseState {
                case .finished:
                    // if the response stream has already finished before the request, we must succeed
                    // the final continuation.
                    self.state = .finished(error: nil)
                    return .forwardStreamFinished(context.executor)

                case .waitingForResponseHead, .streamingBody:
                    self.state = .executing(context, .finished, responseState)
                    return .forwardStreamFinished(context.executor)
                }

            case .finished:
                return .none
            }
        }

        // MARK: - Response -

        enum ReceiveResponseHeadAction {
            case succeedResponseHead(TransactionBody, CheckedContinuation<HTTPClientResponse, Error>)
            case none
        }

        mutating func receiveResponseHead<Delegate: NIOAsyncSequenceProducerDelegate>(
            _ head: HTTPResponseHead,
            delegate: Delegate
        ) -> ReceiveResponseHeadAction {
            switch self.state {
            case .initialized,
                .queued,
                .deadlineExceededWhileQueued,
                .executing(_, _, .streamingBody),
                .executing(_, _, .finished):
                preconditionFailure("invalid state \(self.state)")

            case .executing(let context, let requestState, .waitingForResponseHead):
                // The response head was received. Next we will wait for the consumer to create a
                // response body stream.
                let body = TransactionBody.makeSequence(
                    backPressureStrategy: .init(lowWatermark: 1, highWatermark: 1),
                    finishOnDeinit: true,
                    delegate: AnyAsyncSequenceProducerDelegate(delegate)
                )

                self.state = .executing(context, requestState, .streamingBody(body.source))
                return .succeedResponseHead(body.sequence, context.continuation)

            case .finished(error: .some):
                // If the request failed before, we don't need to do anything in response to
                // receiving the response head.
                return .none

            case .finished(error: .none):
                preconditionFailure("How can the request be finished without error, before receiving response head?")
            }
        }

        enum ProduceMoreAction {
            case none
            case requestMoreResponseBodyParts(HTTPRequestExecutor)
        }

        mutating func produceMore() -> ProduceMoreAction {
            switch self.state {
            case .initialized,
                .queued,
                .deadlineExceededWhileQueued,
                .executing(_, _, .waitingForResponseHead):
                preconditionFailure("invalid state \(self.state)")

            case .executing(let context, _, .streamingBody):
                return .requestMoreResponseBodyParts(context.executor)
            case .finished,
                .executing(_, _, .finished):
                return .none
            }
        }

        enum ReceiveResponsePartAction {
            case none
            case yieldResponseBodyParts(TransactionBody.Source, CircularBuffer<ByteBuffer>, HTTPRequestExecutor)
        }

        mutating func receiveResponseBodyParts(_ buffer: CircularBuffer<ByteBuffer>) -> ReceiveResponsePartAction {
            switch self.state {
            case .initialized, .queued, .deadlineExceededWhileQueued:
                preconditionFailure(
                    "Received a response body part, but request hasn't started yet. Invalid state: \(self.state)"
                )

            case .executing(_, _, .waitingForResponseHead):
                preconditionFailure("If we receive a response body, we must have received a head before")

            case .executing(let context, _, .streamingBody(let source)):
                return .yieldResponseBodyParts(source, buffer, context.executor)

            case .finished:
                // the request failed or was cancelled before, we can ignore further data
                return .none

            case .executing(_, _, .finished):
                preconditionFailure(
                    "Received response end. Must not receive further body parts after that. Invalid state: \(self.state)"
                )
            }
        }

        enum ReceiveResponseEndAction {
            case finishResponseStream(TransactionBody.Source, finalBody: CircularBuffer<ByteBuffer>?)
            case none
        }

        mutating func receiveResponseEnd(_ newChunks: CircularBuffer<ByteBuffer>?) -> ReceiveResponseEndAction {
            switch self.state {
            case .initialized,
                .queued,
                .deadlineExceededWhileQueued,
                .executing(_, _, .waitingForResponseHead):
                preconditionFailure(
                    "Received no response head, but received a response end. Invalid state: \(self.state)"
                )

            case .executing(let context, let requestState, .streamingBody(let source)):
                switch requestState {
                case .finished:
                    self.state = .finished(error: nil)
                case .paused, .producing, .requestHeadSent:
                    self.state = .executing(context, requestState, .finished)
                }
                return .finishResponseStream(source, finalBody: newChunks)

            case .finished:
                // the request failed or was cancelled before, we can ignore all events
                return .none
            case .executing(_, _, .finished):
                preconditionFailure(
                    "Already received an eof or error before. Must not receive further events. Invalid state: \(self.state)"
                )
            }
        }

        enum DeadlineExceededAction {
            case none
            case cancelSchedulerOnly(scheduler: HTTPRequestScheduler)
            /// fail response before head received. scheduler and executor are exclusive here.
            case cancel(
                requestContinuation: CheckedContinuation<HTTPClientResponse, Error>,
                scheduler: HTTPRequestScheduler?,
                executor: HTTPRequestExecutor?,
                bodyStreamContinuation: CheckedContinuation<Void, Error>?
            )
        }

        mutating func deadlineExceeded() -> DeadlineExceededAction {
            let error = HTTPClientError.deadlineExceeded
            switch self.state {
            case .initialized(let continuation):
                self.state = .finished(error: error)
                return .cancel(
                    requestContinuation: continuation,
                    scheduler: nil,
                    executor: nil,
                    bodyStreamContinuation: nil
                )

            case .queued(let continuation, let scheduler):
                self.state = .deadlineExceededWhileQueued(continuation)
                return .cancelSchedulerOnly(
                    scheduler: scheduler
                )
            case .deadlineExceededWhileQueued:
                return .none
            case .executing(let context, let requestStreamState, .waitingForResponseHead):
                switch requestStreamState {
                case .paused(continuation: .some(let continuation)):
                    self.state = .finished(error: error)
                    return .cancel(
                        requestContinuation: context.continuation,
                        scheduler: nil,
                        executor: context.executor,
                        bodyStreamContinuation: continuation
                    )
                case .requestHeadSent, .finished, .producing, .paused(continuation: .none):
                    self.state = .finished(error: error)
                    return .cancel(
                        requestContinuation: context.continuation,
                        scheduler: nil,
                        executor: context.executor,
                        bodyStreamContinuation: nil
                    )
                }

            case .executing, .finished:
                // The user specified deadline is only used until we received the response head.
                // If we already received the head, we have also resumed the continuation and
                // therefore return the HTTPClientResponse to the user. We do not want to cancel
                // the request body streaming nor the response body streaming afterwards.
                return .none
            }
        }
    }
}

@available(*, unavailable)
extension Transaction.StateMachine: Sendable {}
