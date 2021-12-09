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
import NIOCore
import NIOHTTP1

@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
extension Transaction {
    struct StateMachine {
        struct ExecutionContext {
            let executor: HTTPRequestExecutor
            let allocator: ByteBufferAllocator
            let continuation: CheckedContinuation<HTTPClientResponse, Error>
        }

        private enum State {
            case initialized(CheckedContinuation<HTTPClientResponse, Error>)
            case queued(CheckedContinuation<HTTPClientResponse, Error>, HTTPRequestScheduler)
            case executing(ExecutionContext, RequestStreamState, ResponseStreamState)
            case finished(error: Error?, HTTPClientResponse.Body.IteratorStream.ID?)
        }

        fileprivate enum RequestStreamState {
            case requestHeadSent
            case producing
            case paused
            case finished
        }

        fileprivate enum ResponseStreamState {
            enum Next {
                case askExecutorForMore
                case error(Error)
                case endOfFile
            }

            case waitingForResponseHead
            case waitingForStream(CircularBuffer<ByteBuffer>, next: Next)
            case buffering(HTTPClientResponse.Body.IteratorStream.ID, CircularBuffer<ByteBuffer>, next: Next)
            case waitingForRemote(HTTPClientResponse.Body.IteratorStream.ID, CheckedContinuation<ByteBuffer?, Error>)
            case finished(HTTPClientResponse.Body.IteratorStream.ID, CheckedContinuation<ByteBuffer?, Error>)
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
            case failResponseHead(CheckedContinuation<HTTPClientResponse, Error>, Error, HTTPRequestScheduler?, HTTPRequestExecutor?)
            /// fail response after response head received. fail the response stream (aka call to `next()`)
            case failResponseStream(CheckedContinuation<ByteBuffer?, Error>, Error, HTTPRequestExecutor)
        }

        mutating func fail(_ error: Error) -> FailAction {
            switch self.state {
            case .initialized(let continuation):
                self.state = .finished(error: error, nil)
                return .failResponseHead(continuation, error, nil, nil)

            case .queued(let continuation, let scheduler):
                self.state = .finished(error: error, nil)
                return .failResponseHead(continuation, error, scheduler, nil)

            case .executing(let context, _, .waitingForResponseHead):
                self.state = .finished(error: error, nil)
                return .failResponseHead(context.continuation, error, nil, context.executor)

            case .executing(_, _, .waitingForStream(_, next: .error)),
                 .executing(_, _, .buffering(_, _, next: .error)):
                // We have an error buffered that we will forward to the response stream. We always
                // only forward the first error.
                return .none

            case .executing(let context, let requestStreamState, .waitingForStream(let buffer, next: .askExecutorForMore)),
                 .executing(let context, let requestStreamState, .waitingForStream(let buffer, next: .endOfFile)):
                // We have already received a response head, but no AsyncIterator has been seen so
                // far. We should deliver the error on the first call to `next`.

                switch requestStreamState {
                case .requestHeadSent:
                    preconditionFailure("Invalid state: \(self.state)")

                case .paused, .finished:
                    // The request body stream is paused or finished. We don't need to change the
                    // requestStreamState, producing is already paused/finished.
                    self.state = .executing(context, requestStreamState, .waitingForStream(buffer, next: .error(error)))
                    return .none

                case .producing:
                    // The request body stream is producing. We stop the request body stream, by
                    // changing the request stream state to paused. This will lead to no further
                    // produce calls. Once the next bytes are delivered.
                    self.state = .executing(context, .paused, .waitingForStream(buffer, next: .error(error)))
                    return .none
                }

            case .executing(let context, let requestStreamState, .buffering(let streamID, let buffer, next: .askExecutorForMore)),
                 .executing(let context, let requestStreamState, .buffering(let streamID, let buffer, next: .endOfFile)):

                switch requestStreamState {
                case .requestHeadSent:
                    preconditionFailure("Invalid state: \(self.state)")

                case .paused, .finished:
                    self.state = .executing(context, requestStreamState, .buffering(streamID, buffer, next: .error(error)))
                    return .none

                case .producing:
                    self.state = .executing(context, .paused, .buffering(streamID, buffer, next: .error(error)))
                    return .none
                }

            case .executing(let context, _, .waitingForRemote(let streamID, let continuation)):
                // We are in response streaming. The response stream is waiting for the next bytes
                // from the server. We can fail the call to `next` immediately.
                self.state = .finished(error: error, streamID)
                return .failResponseStream(continuation, error, context.executor)

            case .finished(error: _, _):
                // The request has already failed, succeeded, or the users is not interested in the
                // response. There is no more way to reach the user code. Just drop the error.
                return .none

            case .executing(let context, _, .finished(let streamID, let continuation)):
                self.state = .finished(error: error, streamID)
                return .failResponseStream(continuation, error, context.executor)
            }
        }

        // MARK: - Request -

        enum StartExecutionAction {
            case cancel(HTTPRequestExecutor)
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

            case .finished(error: .some, .none):
                return .cancel(executor)

            case .executing,
                 .finished(error: .none, _),
                 .finished(error: .some, .some):
                preconditionFailure("Invalid state: \(self.state)")
            }
        }

        enum ResumeProducingAction {
            case resumeStream(ByteBufferAllocator)
            case none
        }

        mutating func resumeRequestBodyStream() -> ResumeProducingAction {
            switch self.state {
            case .initialized, .queued:
                preconditionFailure("Received a resumeBodyRequest on a request, that isn't executing. Invalid state: \(self.state)")

            case .executing(let context, .requestHeadSent, let responseState):
                // the request can start to send its body.
                self.state = .executing(context, .producing, responseState)
                return .resumeStream(context.allocator)

            case .executing(_, .producing, _):
                preconditionFailure("Received a resumeBodyRequest on a request, that is producing. Invalid state: \(self.state)")

            case .executing(let context, .paused, let responseState):
                // the request body was paused. we can start the body streaming again.
                self.state = .executing(context, .producing, responseState)
                return .resumeStream(context.allocator)

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
                 .executing(_, .requestHeadSent, _):
                preconditionFailure("A request stream can only be resumed, if the request was started")

            case .executing(let context, .producing, let responseSteam):
                self.state = .executing(context, .paused, responseSteam)

            case .executing(_, .paused, _),
                 .executing(_, .finished, _),
                 .finished:
                // the channels writability changed to paused after we have already forwarded all
                // request bytes. Can be ignored.
                break
            }
        }

        enum NextWriteAction {
            case write(ByteBuffer, HTTPRequestExecutor, continue: Bool)
            case none
        }

        func producedNextRequestPart(_ part: ByteBuffer) -> NextWriteAction {
            switch self.state {
            case .initialized,
                 .queued,
                 .executing(_, .requestHeadSent, _),
                 .executing(_, .finished, _):
                preconditionFailure("A request stream can only produce, if the request was started. Invalid state: \(self.state)")

            case .executing(let context, .producing, _):
                // We are currently producing the request body. The executors channel is writable.
                // For this reason we can continue to produce data.
                return .write(part, context.executor, continue: true)

            case .executing(let context, .paused, _):
                // We are currently pausing the request body, since the executor's channel is not
                // writable. We receive this call, since we were writable when we received the last
                // data. At that point, we wanted to produce more. While waiting for more request
                // bytes, the channel became not writable. Now is the point to pause producing.
                return .write(part, context.executor, continue: false)

            case .finished:
                return .none
            }
        }

        enum FinishAction {
            // forward the notice that the request stream has finished. If finalContinuation is not
            // nil, succeed the continuation with nil to signal the requests end.
            case forwardStreamFinished(HTTPRequestExecutor, finalContinuation: CheckedContinuation<ByteBuffer?, Error>?)
            case none
        }

        mutating func finishRequestBodyStream() -> FinishAction {
            switch self.state {
            case .initialized,
                 .queued,
                 .executing(_, .finished, _):
                preconditionFailure("Invalid state: \(self.state)")

            case .executing(let context, .producing, let responseState),
                 .executing(let context, .paused, let responseState),
                 .executing(let context, .requestHeadSent, let responseState):

                switch responseState {
                case .finished(let registeredStreamID, let continuation):
                    // if the response stream has already finished before the request, we must succeed
                    // the final continuation.
                    self.state = .finished(error: nil, registeredStreamID)
                    return .forwardStreamFinished(context.executor, finalContinuation: continuation)

                case .waitingForResponseHead, .waitingForStream, .waitingForRemote, .buffering:
                    self.state = .executing(context, .finished, responseState)
                    return .forwardStreamFinished(context.executor, finalContinuation: nil)
                }

            case .finished:
                return .none
            }
        }

        // MARK: - Response -

        enum ReceiveResponseHeadAction {
            case succeedResponseHead(HTTPResponseHead, CheckedContinuation<HTTPClientResponse, Error>)
            case none
        }

        mutating func receiveResponseHead(_ head: HTTPResponseHead) -> ReceiveResponseHeadAction {
            switch self.state {
            case .initialized,
                 .queued,
                 .executing(_, _, .waitingForStream),
                 .executing(_, _, .buffering),
                 .executing(_, _, .waitingForRemote):
                preconditionFailure("How can we receive a response, if the request hasn't started yet.")

            case .executing(let context, let requestState, .waitingForResponseHead):
                self.state = .executing(context, requestState, .waitingForStream(.init(), next: .askExecutorForMore))
                return .succeedResponseHead(head, context.continuation)

            case .finished(error: .some, _):
                return .none

            case .executing(_, _, .finished),
                 .finished(error: .none, _):
                preconditionFailure("How can the request be finished without error, before receiving response head?")
            }
        }

        enum ReceiveResponsePartAction {
            case none
            case succeedContinuation(CheckedContinuation<ByteBuffer?, Error>, ByteBuffer)
        }

        mutating func receiveResponseBodyParts(_ buffer: CircularBuffer<ByteBuffer>) -> ReceiveResponsePartAction {
            switch self.state {
            case .initialized, .queued:
                preconditionFailure("Received a response body part, but request hasn't started yet. Invalid state: \(self.state)")

            case .executing(_, _, .waitingForResponseHead):
                preconditionFailure("If we receive a response body, we must have received a head before")

            case .executing(let context, let requestState, .buffering(let streamID, var currentBuffer, next: let next)):
                guard case .askExecutorForMore = next else {
                    preconditionFailure("If we have received an error or eof before, why did we get another body part? Next: \(next)")
                }

                if currentBuffer.isEmpty {
                    currentBuffer = buffer
                } else {
                    currentBuffer.append(contentsOf: buffer)
                }
                self.state = .executing(context, requestState, .buffering(streamID, currentBuffer, next: next))
                return .none

            case .executing(let executor, let requestState, .waitingForStream(var currentBuffer, next: let next)):
                guard case .askExecutorForMore = next else {
                    preconditionFailure("If we have received an error or eof before, why did we get another body part? Next: \(next)")
                }

                if currentBuffer.isEmpty {
                    currentBuffer = buffer
                } else {
                    currentBuffer.append(contentsOf: buffer)
                }
                self.state = .executing(executor, requestState, .waitingForStream(currentBuffer, next: next))
                return .none

            case .executing(let executor, let requestState, .waitingForRemote(let streamID, let continuation)):
                var buffer = buffer
                let first = buffer.removeFirst()
                self.state = .executing(executor, requestState, .buffering(streamID, buffer, next: .askExecutorForMore))
                return .succeedContinuation(continuation, first)

            case .finished:
                // the request failed or was cancelled before, we can ignore further data
                return .none

            case .executing(_, _, .finished):
                preconditionFailure("Received response end. Must not receive further body parts after that. Invalid state: \(self.state)")
            }
        }

        enum ResponseBodyDeinitedAction {
            case cancel(HTTPRequestExecutor)
            case none
        }

        mutating func responseBodyDeinited() -> ResponseBodyDeinitedAction {
            switch self.state {
            case .initialized,
                 .queued,
                 .executing(_, _, .waitingForResponseHead):
                preconditionFailure("Got notice about a deinited response, before we even received a response. Invalid state: \(self.state)")

            case .executing(_, _, .waitingForStream(_, next: .endOfFile)):
                self.state = .finished(error: nil, nil)
                return .none

            case .executing(let context, _, .waitingForStream(_, next: .askExecutorForMore)):
                self.state = .finished(error: nil, nil)
                return .cancel(context.executor)

            case .executing(_, _, .waitingForStream(_, next: .error(let error))):
                self.state = .finished(error: error, nil)
                return .none

            case .finished:
                // body was released after the response was consumed
                return .none

            case .executing(_, _, .buffering),
                 .executing(_, _, .waitingForRemote),
                 .executing(_, _, .finished):
                // user is consuming the stream with an iterator
                return .none
            }
        }

        mutating func cancelResponseStream(streamID: HTTPClientResponse.Body.IteratorStream.ID) -> FailAction {
            switch self.state {
            case .initialized, .queued, .executing(_, _, .waitingForResponseHead):
                preconditionFailure("Got notice about a deinited response body iterator, before we even received a response. Invalid state: \(self.state)")

            case .executing(_, _, .buffering(let registeredStreamID, _, next: _)),
                 .executing(_, _, .waitingForRemote(let registeredStreamID, _)):
                self.verifyStreamIDIsEqual(registered: registeredStreamID, this: streamID)
                return self.fail(HTTPClientError.cancelled)

            case .executing(_, _, .waitingForStream),
                 .executing(_, _, .finished),
                 .finished:
                // the iterator went out of memory after the request was done. nothing to do.
                return .none
            }
        }

        enum ConsumeAction {
            case succeedContinuation(CheckedContinuation<ByteBuffer?, Error>, ByteBuffer?)
            case failContinuation(CheckedContinuation<ByteBuffer?, Error>, Error)
            case askExecutorForMore(HTTPRequestExecutor)
            case none
        }

        struct TriedToRegisteredASecondConsumer: Error {}

        mutating func consumeNextResponsePart(
            streamID: HTTPClientResponse.Body.IteratorStream.ID,
            continuation: CheckedContinuation<ByteBuffer?, Error>
        ) -> ConsumeAction {
            switch self.state {
            case .initialized,
                 .queued,
                 .executing(_, _, .waitingForResponseHead):
                preconditionFailure("If we receive a response body, we must have received a head before")

            case .executing(_, _, .finished):
                preconditionFailure("This is an invalid state at this point. We are waiting for the request stream to finish to succeed the response stream. By sending a fi")

            case .executing(let context, let requestState, .waitingForStream(var buffer, next: .askExecutorForMore)):
                if buffer.isEmpty {
                    self.state = .executing(context, requestState, .waitingForRemote(streamID, continuation))
                    return .askExecutorForMore(context.executor)
                } else {
                    let toReturn = buffer.removeFirst()
                    self.state = .executing(context, requestState, .buffering(streamID, buffer, next: .askExecutorForMore))
                    return .succeedContinuation(continuation, toReturn)
                }

            case .executing(_, _, .waitingForStream(_, next: .error(let error))):
                self.state = .finished(error: error, streamID)
                return .failContinuation(continuation, error)

            case .executing(_, _, .waitingForStream(let buffer, next: .endOfFile)) where buffer.isEmpty:
                self.state = .finished(error: nil, streamID)
                return .succeedContinuation(continuation, nil)

            case .executing(let context, let requestState, .waitingForStream(var buffer, next: .endOfFile)):
                assert(!buffer.isEmpty)
                let toReturn = buffer.removeFirst()
                self.state = .executing(context, requestState, .buffering(streamID, buffer, next: .endOfFile))
                return .succeedContinuation(continuation, toReturn)

            case .executing(let context, let requestState, .buffering(let registeredStreamID, var buffer, next: .askExecutorForMore)):
                self.verifyStreamIDIsEqual(registered: registeredStreamID, this: streamID)

                if buffer.isEmpty {
                    self.state = .executing(context, requestState, .waitingForRemote(streamID, continuation))
                    return .askExecutorForMore(context.executor)
                } else {
                    let toReturn = buffer.removeFirst()
                    self.state = .executing(context, requestState, .buffering(streamID, buffer, next: .askExecutorForMore))
                    return .succeedContinuation(continuation, toReturn)
                }

            case .executing(_, _, .buffering(let registeredStreamID, _, next: .error(let error))):
                self.verifyStreamIDIsEqual(registered: registeredStreamID, this: streamID)
                self.state = .finished(error: error, registeredStreamID)
                return .failContinuation(continuation, error)

            case .executing(_, _, .buffering(let registeredStreamID, let buffer, next: .endOfFile)) where buffer.isEmpty:
                self.verifyStreamIDIsEqual(registered: registeredStreamID, this: streamID)
                self.state = .finished(error: nil, registeredStreamID)
                return .succeedContinuation(continuation, nil)

            case .executing(let context, let requestState, .buffering(let registeredStreamID, var buffer, next: .endOfFile)):
                self.verifyStreamIDIsEqual(registered: registeredStreamID, this: streamID)
                if let toReturn = buffer.popFirst() {
                    // As long as we have bytes in the local store, we can hand them to the user.
                    self.state = .executing(context, requestState, .buffering(streamID, buffer, next: .endOfFile))
                    return .succeedContinuation(continuation, toReturn)
                }

                switch requestState {
                case .requestHeadSent, .paused, .producing:
                    // if the request isn't finished yet, we don't succeed the final response stream
                    // continuation. We will succeed it once the request has been fully send.
                    self.state = .executing(context, requestState, .finished(streamID, continuation))
                    return .none
                case .finished:
                    // if the request is finished, we can succeed the final continuation.
                    self.state = .finished(error: nil, streamID)
                    return .succeedContinuation(continuation, nil)
                }

            case .executing(_, _, .waitingForRemote(let registeredStreamID, _)):
                self.verifyStreamIDIsEqual(registered: registeredStreamID, this: streamID)
                preconditionFailure("A body response continuation from this iterator already exists! Queuing calls to `next()` is not supported.")

            case .finished(error: .some(let error), let registeredStreamID):
                guard registeredStreamID == streamID else {
                    return .failContinuation(continuation, TriedToRegisteredASecondConsumer())
                }
                return .failContinuation(continuation, error)

            case .finished(error: .none, let registeredStreamID):
                guard registeredStreamID == streamID else {
                    return .failContinuation(continuation, TriedToRegisteredASecondConsumer())
                }
                return .succeedContinuation(continuation, nil)
            }
        }

        private func verifyStreamIDIsEqual(
            registered: HTTPClientResponse.Body.IteratorStream.ID,
            this: HTTPClientResponse.Body.IteratorStream.ID,
            file: StaticString = #file,
            line: UInt = #line
        ) {
            if registered != this {
                preconditionFailure(
                    "Tried to use a second iterator on response body stream. Multiple iterators are not supported.",
                    file: file, line: line
                )
            }
        }

        enum ReceiveResponseEndAction {
            case succeedContinuation(CheckedContinuation<ByteBuffer?, Error>, ByteBuffer)
            case finishResponseStream(CheckedContinuation<ByteBuffer?, Error>)
            case none
        }

        mutating func succeedRequest(_ newChunks: CircularBuffer<ByteBuffer>?) -> ReceiveResponseEndAction {
            switch self.state {
            case .initialized,
                 .queued,
                 .executing(_, _, .waitingForResponseHead):
                preconditionFailure("Received no response head, but received a response end. Invalid state: \(self.state)")

            case .executing(let context, let requestState, .waitingForStream(var buffer, next: .askExecutorForMore)):
                if let newChunks = newChunks, !newChunks.isEmpty {
                    buffer.append(contentsOf: newChunks)
                }
                self.state = .executing(context, requestState, .waitingForStream(buffer, next: .endOfFile))
                return .none

            case .executing(let context, let requestState, .waitingForRemote(let streamID, let continuation)):
                if var newChunks = newChunks, !newChunks.isEmpty {
                    let first = newChunks.removeFirst()
                    self.state = .executing(context, requestState, .buffering(streamID, newChunks, next: .endOfFile))
                    return .succeedContinuation(continuation, first)
                }

                self.state = .finished(error: nil, streamID)
                return .finishResponseStream(continuation)

            case .executing(let context, let requestState, .buffering(let streamID, var buffer, next: .askExecutorForMore)):
                if let newChunks = newChunks, !newChunks.isEmpty {
                    buffer.append(contentsOf: newChunks)
                }
                self.state = .executing(context, requestState, .buffering(streamID, buffer, next: .endOfFile))
                return .none

            case .finished:
                // the request failed or was cancelled before, we can ignore all events
                return .none

            case .executing(_, _, .waitingForStream(_, next: .error)),
                 .executing(_, _, .waitingForStream(_, next: .endOfFile)),
                 .executing(_, _, .buffering(_, _, next: .error)),
                 .executing(_, _, .buffering(_, _, next: .endOfFile)),
                 .executing(_, _, .finished(_, _)):
                preconditionFailure("Already received an eof or error before. Must not receive further events. Invalid state: \(self.state)")
            }
        }
    }
}

#endif
