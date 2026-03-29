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

import NIOCore
import NIOHTTP1

import struct Foundation.URL

extension HTTPClient {
    /// The maximum body size allowed, before a redirect response is cancelled. 3KB.
    ///
    /// Why 3KB? We feel like this is a good compromise between potentially reusing the
    /// connection in HTTP/1.1 mode (if we load all data from the redirect response we can
    /// reuse the connection) and not being to wasteful in the amount of data that is thrown
    /// away being transferred.
    fileprivate static let maxBodySizeRedirectResponse = 1024 * 3
}

extension RequestBag {
    struct StateMachine {
        fileprivate enum State {
            case initialized(RedirectHandler<Delegate.Response>?)
            case queued(HTTPRequestScheduler, RedirectHandler<Delegate.Response>?)
            /// if the deadline was exceeded while in the `.queued(_:)` state,
            /// we wait until the request pool fails the request with a potential more descriptive error message,
            /// if a connection failure has occured while the request was queued.
            case deadlineExceededWhileQueued
            case executing(HTTPRequestExecutor, RequestStreamState, ResponseStreamState)
            case finished(error: Error?)
            case redirected(HTTPRequestExecutor, RedirectHandler<Delegate.Response>, Int, HTTPResponseHead, URL)
            case modifying
        }

        fileprivate enum RequestStreamState {
            case initialized
            case producing
            case paused(EventLoopPromise<Void>?)
            case finished
        }

        fileprivate enum ResponseStreamState {
            enum Next {
                case askExecutorForMore
                case error(Error)
                case eof
            }

            case initialized(RedirectHandler<Delegate.Response>?)
            case buffering(CircularBuffer<ByteBuffer>, next: Next)
            case waitingForRemote
        }

        private var state: State

        init(redirectHandler: RedirectHandler<Delegate.Response>?) {
            self.state = .initialized(redirectHandler)
        }
    }
}

extension RequestBag.StateMachine {
    mutating func requestWasQueued(_ scheduler: HTTPRequestScheduler) {
        guard case .initialized(let redirectHandler) = self.state else {
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

        self.state = .queued(scheduler, redirectHandler)
    }

    enum WillExecuteRequestAction {
        case cancelExecuter(HTTPRequestExecutor)
        case failTaskAndCancelExecutor(Error, HTTPRequestExecutor)
        case none
    }

    mutating func willExecuteRequest(_ executor: HTTPRequestExecutor) -> WillExecuteRequestAction {
        switch self.state {
        case .initialized(let redirectHandler), .queued(_, let redirectHandler):
            self.state = .executing(executor, .initialized, .initialized(redirectHandler))
            return .none
        case .deadlineExceededWhileQueued:
            let error: Error = HTTPClientError.deadlineExceeded
            self.state = .finished(error: error)
            return .failTaskAndCancelExecutor(error, executor)
        case .finished(error: .some):
            return .cancelExecuter(executor)
        case .executing, .redirected, .finished(error: .none), .modifying:
            preconditionFailure("Invalid state: \(self.state)")
        }
    }

    enum ResumeProducingAction {
        case startWriter
        case succeedBackpressurePromise(EventLoopPromise<Void>?)
        case none
    }

    mutating func resumeRequestBodyStream() -> ResumeProducingAction {
        switch self.state {
        case .initialized, .queued, .deadlineExceededWhileQueued:
            preconditionFailure("A request stream can only be resumed, if the request was started")

        case .executing(let executor, .initialized, .initialized(let redirectHandler)):
            self.state = .executing(executor, .producing, .initialized(redirectHandler))
            return .startWriter

        case .executing(_, .producing, _):
            preconditionFailure("Expected that resume is only called when if we were paused before")

        case .executing(let executor, .paused(let promise), let responseState):
            self.state = .executing(executor, .producing, responseState)
            return .succeedBackpressurePromise(promise)

        case .executing(_, .finished, _):
            // the channels writability changed to writable after we have forwarded all the
            // request bytes. Can be ignored.
            return .none

        case .executing(_, .initialized, .buffering), .executing(_, .initialized, .waitingForRemote):
            preconditionFailure("Invalid states: Response can not be received before request")

        case .redirected:
            // if we are redirected, we should cancel our request body stream anyway
            return .none

        case .finished:
            // If this task has been cancelled we may be in an error state. As a matter of
            // defensive programming, we also tolerate receiving this notification if we've ended cleanly:
            // while it shouldn't happen, nothing will go wrong if we just ignore it.
            // All paths through this state machine should cancel our request body stream to get here anyway.
            return .none

        case .modifying:
            preconditionFailure("Invalid state: \(self.state)")
        }
    }

    mutating func pauseRequestBodyStream() {
        switch self.state {
        case .initialized, .queued, .deadlineExceededWhileQueued:
            preconditionFailure("A request stream can only be paused, if the request was started")
        case .executing(let executor, let requestState, let responseState):
            switch requestState {
            case .initialized:
                preconditionFailure("Request stream must be started before it can be paused")
            case .producing:
                self.state = .executing(executor, .paused(nil), responseState)
            case .paused:
                preconditionFailure("Expected that pause is only called when if we were producing before")
            case .finished:
                // the channels writability changed to not writable after we have forwarded the
                // last bytes from our side.
                break
            }
        case .redirected:
            // if we are redirected, we should cancel our request body stream anyway
            break
        case .finished:
            // the request is already finished nothing further to do
            break
        case .modifying:
            preconditionFailure("Invalid state: \(self.state)")
        }
    }

    enum WriteAction {
        case write(IOData, HTTPRequestExecutor, EventLoopFuture<Void>)

        case failTask(Error)
        case failFuture(Error)
    }

    mutating func writeNextRequestPart(_ part: IOData, taskEventLoop: EventLoop) -> WriteAction {
        switch self.state {
        case .initialized, .queued, .deadlineExceededWhileQueued:
            preconditionFailure("Invalid state: \(self.state)")
        case .executing(let executor, let requestState, let responseState):
            switch requestState {
            case .initialized:
                preconditionFailure("Request stream must be started before it can be paused")
            case .producing:
                return .write(part, executor, taskEventLoop.makeSucceededFuture(()))

            case .paused(.none):
                // backpressure is signaled to the writer using unfulfilled futures. if there
                // is no existing, unfulfilled promise, let's create a new one
                let promise = taskEventLoop.makePromise(of: Void.self)
                self.state = .executing(executor, .paused(promise), responseState)
                return .write(part, executor, promise.futureResult)

            case .paused(.some(let promise)):
                // backpressure is signaled to the writer using unfulfilled futures. if an
                // unfulfilled promise already exist, let's reuse the promise
                return .write(part, executor, promise.futureResult)

            case .finished:
                let error = HTTPClientError.writeAfterRequestSent
                self.state = .finished(error: error)
                return .failTask(error)
            }
        case .redirected:
            // if we are redirected we can cancel the upload stream
            return .failFuture(HTTPClientError.cancelled)
        case .finished(error: .some(let error)):
            return .failFuture(error)
        case .finished(error: .none):
            return .failFuture(HTTPClientError.requestStreamCancelled)
        case .modifying:
            preconditionFailure("Invalid state: \(self.state)")
        }
    }

    enum FinishAction {
        case forwardStreamFinished(HTTPRequestExecutor, EventLoopPromise<Void>?)
        case forwardStreamFailureAndFailTask(HTTPRequestExecutor, Error, EventLoopPromise<Void>?)
        case none
    }

    mutating func finishRequestBodyStream(_ result: Result<Void, Error>) -> FinishAction {
        switch self.state {
        case .initialized, .queued, .deadlineExceededWhileQueued:
            preconditionFailure("Invalid state: \(self.state)")
        case .executing(let executor, let requestState, let responseState):
            switch requestState {
            case .initialized:
                preconditionFailure("Request stream must be started before it can be finished")
            case .producing:
                switch result {
                case .success:
                    self.state = .executing(executor, .finished, responseState)
                    return .forwardStreamFinished(executor, nil)
                case .failure(let error):
                    self.state = .finished(error: error)
                    return .forwardStreamFailureAndFailTask(executor, error, nil)
                }

            case .paused(let promise):
                switch result {
                case .success:
                    self.state = .executing(executor, .finished, responseState)
                    return .forwardStreamFinished(executor, promise)
                case .failure(let error):
                    self.state = .finished(error: error)
                    return .forwardStreamFailureAndFailTask(executor, error, promise)
                }

            case .finished:
                preconditionFailure("How can a finished request stream, be finished again?")
            }
        case .redirected:
            return .none
        case .finished(error: _):
            return .none
        case .modifying:
            preconditionFailure("Invalid state: \(self.state)")
        }
    }

    enum ReceiveResponseHeadAction {
        case none
        case forwardResponseHead(HTTPResponseHead)
        case signalBodyDemand(HTTPRequestExecutor)
        case redirect(HTTPRequestExecutor, RedirectHandler<Delegate.Response>, HTTPResponseHead, URL)
    }

    /// The response head has been received.
    ///
    /// - Parameter head: The response' head
    /// - Returns: Whether the response should be forwarded to the delegate. Will be `false` if the request follows a redirect.
    mutating func receiveResponseHead(_ head: HTTPResponseHead) -> ReceiveResponseHeadAction {
        switch self.state {
        case .initialized, .queued, .deadlineExceededWhileQueued:
            preconditionFailure("How can we receive a response, if the request hasn't started yet.")
        case .executing(let executor, let requestState, let responseState):
            guard case .initialized(let redirectHandler) = responseState else {
                preconditionFailure("If we receive a response, we must not have received something else before")
            }

            if let redirectHandler = redirectHandler,
                let redirectURL = redirectHandler.redirectTarget(
                    status: head.status,
                    responseHeaders: head.headers
                )
            {
                // If we will redirect, we need to consume the response's body ASAP, to be able to
                // reuse the existing connection. We will consume a response body, if the body is
                // smaller than 3kb.
                switch head.contentLength {
                case .some(0...(HTTPClient.maxBodySizeRedirectResponse)), .none:
                    self.state = .redirected(executor, redirectHandler, 0, head, redirectURL)
                    return .signalBodyDemand(executor)
                case .some:
                    self.state = .finished(error: HTTPClientError.cancelled)
                    return .redirect(executor, redirectHandler, head, redirectURL)
                }
            } else {
                self.state = .executing(executor, requestState, .buffering(.init(), next: .askExecutorForMore))
                return .forwardResponseHead(head)
            }
        case .redirected:
            preconditionFailure("This state can only be reached after we have received a HTTP head")
        case .finished(error: .some):
            return .none
        case .finished(error: .none):
            preconditionFailure("How can the request be finished without error, before receiving response head?")
        case .modifying:
            preconditionFailure("Invalid state: \(self.state)")
        }
    }

    enum ReceiveResponseBodyAction {
        case none
        case forwardResponsePart(ByteBuffer)
        case signalBodyDemand(HTTPRequestExecutor)
        case redirect(HTTPRequestExecutor, RedirectHandler<Delegate.Response>, HTTPResponseHead, URL)
    }

    mutating func receiveResponseBodyParts(_ buffer: CircularBuffer<ByteBuffer>) -> ReceiveResponseBodyAction {
        switch self.state {
        case .initialized, .queued, .deadlineExceededWhileQueued:
            preconditionFailure("How can we receive a response body part, if the request hasn't started yet.")
        case .executing(_, _, .initialized):
            preconditionFailure("If we receive a response body, we must have received a head before")

        case .executing(let executor, let requestState, .buffering(var currentBuffer, next: let next)):
            guard case .askExecutorForMore = next else {
                preconditionFailure(
                    "If we have received an error or eof before, why did we get another body part? Next: \(next)"
                )
            }

            self.state = .modifying
            if currentBuffer.isEmpty {
                currentBuffer = buffer
            } else {
                currentBuffer.append(contentsOf: buffer)
            }
            self.state = .executing(executor, requestState, .buffering(currentBuffer, next: next))
            return .none
        case .executing(let executor, let requestState, .waitingForRemote):
            if buffer.count > 0 {
                var buffer = buffer
                let first = buffer.removeFirst()
                self.state = .executing(executor, requestState, .buffering(buffer, next: .askExecutorForMore))
                return .forwardResponsePart(first)
            } else {
                return .none
            }
        case .redirected(let executor, let redirectHandler, var receivedBytes, let head, let redirectURL):
            let partsLength = buffer.reduce(into: 0) { $0 += $1.readableBytes }
            receivedBytes += partsLength

            if receivedBytes > HTTPClient.maxBodySizeRedirectResponse {
                self.state = .finished(error: HTTPClientError.cancelled)
                return .redirect(executor, redirectHandler, head, redirectURL)
            } else {
                self.state = .redirected(executor, redirectHandler, receivedBytes, head, redirectURL)
                return .signalBodyDemand(executor)
            }

        case .finished(error: .some):
            return .none
        case .finished(error: .none):
            preconditionFailure("How can the request be finished without error, before receiving response head?")
        case .modifying:
            preconditionFailure("Invalid state: \(self.state)")
        }
    }

    enum ReceiveResponseEndAction {
        case consume(ByteBuffer)
        case redirect(RedirectHandler<Delegate.Response>, HTTPResponseHead, URL)
        case succeedRequest
        case none
    }

    mutating func receiveResponseEnd(_ newChunks: CircularBuffer<ByteBuffer>?) -> ReceiveResponseEndAction {
        switch self.state {
        case .initialized, .queued, .deadlineExceededWhileQueued:
            preconditionFailure("How can we receive a response body part, if the request hasn't started yet.")
        case .executing(_, _, .initialized):
            preconditionFailure("If we receive a response body, we must have received a head before")

        case .executing(let executor, let requestState, .buffering(var buffer, next: let next)):
            guard case .askExecutorForMore = next else {
                preconditionFailure(
                    "If we have received an error or eof before, why did we get another body part? Next: \(next)"
                )
            }

            if buffer.isEmpty, let newChunks = newChunks, !newChunks.isEmpty {
                buffer = newChunks
            } else if let newChunks = newChunks, !newChunks.isEmpty {
                buffer.append(contentsOf: newChunks)
            }

            self.state = .executing(executor, requestState, .buffering(buffer, next: .eof))
            return .none

        case .executing(let executor, let requestState, .waitingForRemote):
            guard var newChunks = newChunks, !newChunks.isEmpty else {
                self.state = .finished(error: nil)
                return .succeedRequest
            }

            let first = newChunks.removeFirst()
            self.state = .executing(executor, requestState, .buffering(newChunks, next: .eof))
            return .consume(first)

        case .redirected(_, let redirectHandler, _, let head, let redirectURL):
            self.state = .finished(error: nil)
            return .redirect(redirectHandler, head, redirectURL)

        case .finished(error: .some):
            return .none

        case .finished(error: .none):
            preconditionFailure("How can the request be finished without error, before receiving response head?")
        case .modifying:
            preconditionFailure("Invalid state: \(self.state)")
        }
    }

    enum ConsumeAction {
        case requestMoreFromExecutor(HTTPRequestExecutor)
        case consume(ByteBuffer)
        case finishStream
        case failTask(Error, executorToCancel: HTTPRequestExecutor?)
        case doNothing
    }

    mutating func consumeMoreBodyData(resultOfPreviousConsume result: Result<Void, Error>) -> ConsumeAction {
        switch result {
        case .success:
            return self.consumeMoreBodyData()
        case .failure(let error):
            return self.failWithConsumptionError(error)
        }
    }

    private mutating func failWithConsumptionError(_ error: Error) -> ConsumeAction {
        switch self.state {
        case .initialized, .queued, .deadlineExceededWhileQueued:
            preconditionFailure("Invalid state: \(self.state)")
        case .executing(_, _, .initialized):
            preconditionFailure(
                "Invalid state: Must have received response head, before this method is called for the first time"
            )

        case .executing(_, _, .buffering(_, next: .error(let connectionError))):
            // if an error was received from the connection, we fail the task with the one
            // from the connection, since it happened first.
            self.state = .finished(error: connectionError)
            return .failTask(connectionError, executorToCancel: nil)

        case .executing(let executor, _, .buffering(_, _)):
            self.state = .finished(error: error)
            return .failTask(error, executorToCancel: executor)

        case .executing(_, _, .waitingForRemote):
            preconditionFailure(
                "Invalid state... We just returned from a consumption function. We can't already be waiting"
            )

        case .redirected:
            preconditionFailure(
                "Invalid state... Redirect don't call out to delegate functions. Thus we should never land here."
            )

        case .finished(error: .some):
            // don't overwrite existing errors
            return .doNothing

        case .finished(error: .none):
            preconditionFailure(
                "Invalid state... If no error occured, this must not be called, after the request was finished"
            )

        case .modifying:
            preconditionFailure()
        }
    }

    private mutating func consumeMoreBodyData() -> ConsumeAction {
        switch self.state {
        case .initialized, .queued, .deadlineExceededWhileQueued:
            preconditionFailure("Invalid state: \(self.state)")

        case .executing(_, _, .initialized):
            preconditionFailure(
                "Invalid state: Must have received response head, before this method is called for the first time"
            )

        case .executing(let executor, let requestState, .buffering(var buffer, next: .askExecutorForMore)):
            self.state = .modifying

            if let byteBuffer = buffer.popFirst() {
                self.state = .executing(executor, requestState, .buffering(buffer, next: .askExecutorForMore))
                return .consume(byteBuffer)
            }

            // buffer is empty, wait for more
            self.state = .executing(executor, requestState, .waitingForRemote)
            return .requestMoreFromExecutor(executor)

        case .executing(let executor, let requestState, .buffering(var buffer, next: .eof)):
            self.state = .modifying

            if let byteBuffer = buffer.popFirst() {
                self.state = .executing(executor, requestState, .buffering(buffer, next: .eof))
                return .consume(byteBuffer)
            }

            self.state = .finished(error: nil)
            return .finishStream

        case .executing(_, _, .buffering(_, next: .error(let error))):
            self.state = .finished(error: error)
            return .failTask(error, executorToCancel: nil)

        case .executing(_, _, .waitingForRemote):
            preconditionFailure(
                "Invalid state... We just returned from a consumption function. We can't already be waiting"
            )

        case .redirected:
            return .doNothing

        case .finished(error: .some):
            return .doNothing

        case .finished(error: .none):
            preconditionFailure(
                "Invalid state... If no error occurred, this must not be called, after the request was finished"
            )

        case .modifying:
            preconditionFailure()
        }
    }

    enum DeadlineExceededAction {
        case cancelScheduler(HTTPRequestScheduler?)
        case fail(FailAction)
    }

    mutating func deadlineExceeded() -> DeadlineExceededAction {
        switch self.state {
        case .queued(let queuer, _):
            /// We do not fail the request immediately because we want to give the scheduler a chance of throwing a better error message
            /// We therefore depend on the scheduler failing the request after we cancel the request.
            self.state = .deadlineExceededWhileQueued
            return .cancelScheduler(queuer)

        case .initialized,
            .deadlineExceededWhileQueued,
            .executing,
            .finished,
            .redirected,
            .modifying:
            /// if we are not in the queued state, we can fail early by just calling down to `self.fail(_:)`
            /// which does the appropriate state transition for us.
            return .fail(self.fail(HTTPClientError.deadlineExceeded))
        }
    }

    enum FailAction {
        case failTask(Error, HTTPRequestScheduler?, HTTPRequestExecutor?)
        case cancelExecutor(HTTPRequestExecutor)
        case none
    }

    mutating func fail(_ error: Error) -> FailAction {
        switch self.state {
        case .initialized:
            self.state = .finished(error: error)
            return .failTask(error, nil, nil)
        case .queued(let queuer, _):
            self.state = .finished(error: error)
            return .failTask(error, queuer, nil)
        case .executing(let executor, let requestState, .buffering(_, next: .eof)):
            self.state = .executing(executor, requestState, .buffering(.init(), next: .error(error)))
            return .cancelExecutor(executor)
        case .executing(let executor, _, .buffering(_, next: .askExecutorForMore)):
            self.state = .finished(error: error)
            return .failTask(error, nil, executor)
        case .executing(let executor, _, .buffering(_, next: .error(_))):
            // this would override another error, let's keep the first one
            return .cancelExecutor(executor)
        case .executing(let executor, _, .initialized):
            self.state = .finished(error: error)
            return .failTask(error, nil, executor)
        case .executing(let executor, _, .waitingForRemote):
            self.state = .finished(error: error)
            return .failTask(error, nil, executor)
        case .redirected:
            self.state = .finished(error: error)
            return .failTask(error, nil, nil)
        case .finished(.none):
            // An error occurred after the request has finished. Ignore...
            return .none
        case .deadlineExceededWhileQueued:
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
            return .failTask(realError, nil, nil)
        case .finished(.some(_)):
            // this might happen, if the stream consumer has failed... let's just drop the data
            return .none
        case .modifying:
            preconditionFailure("Invalid state: \(self.state)")
        }
    }
}

extension HTTPResponseHead {
    var contentLength: Int? {
        guard let header = self.headers.first(name: "content-length") else {
            return nil
        }
        return Int(header)
    }
}
