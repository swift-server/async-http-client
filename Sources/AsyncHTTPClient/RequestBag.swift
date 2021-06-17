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

import NIO
import NIOHTTP1
import NIOConcurrencyHelpers
import Logging
import struct Foundation.URL

final class RequestBag<Delegate: HTTPClientResponseDelegate>: HTTPRequestTask {
    enum State {
        case initialized
        case queued(HTTP1RequestQueuer)
        case executing(HTTP1RequestExecutor, RequestStreamState, ResponseStreamState)
        case finished(error: Error?)
        case redirected(HTTPResponseHead, URL)
        case modifying
    }

    enum RequestStreamState {
        case initialized
        case producing
        case paused([EventLoopPromise<Void>])
        case finished
    }

    enum ResponseStreamState {
        enum Next {
            case askExecutorForMore
            case error(Error)
            case eof
        }

        case initialized
        case buffering(CircularBuffer<ByteBuffer>, next: Next)
        case waitingForRemote(CircularBuffer<ByteBuffer>)
    }

    let task: HTTPClient.Task<Delegate.Response>
    let redirectHandler: RedirectHandler<Delegate.Response>?
    let delegate: Delegate
    let request: HTTPClient.Request

    let stateLock = Lock()

    private var _isCancelled: Bool = false

    // Request execution state. Synchronized with `stateLock`
    private var _state: State = .initialized

    let eventLoopPreference: HTTPClient.EventLoopPreference
    var eventLoop: EventLoop {
        self.task.eventLoop
    }

    var logger: Logger {
        self.task.logger
    }

    let connectionDeadline: NIODeadline
    let idleReadTimeout: TimeAmount?

    init(request: HTTPClient.Request,
         eventLoopPreference: HTTPClient.EventLoopPreference,
         task: HTTPClient.Task<Delegate.Response>,
         redirectHandler: RedirectHandler<Delegate.Response>?,
         connectionDeadline: NIODeadline,
         idleReadTimeout: TimeAmount?,
         delegate: Delegate) {
        self.eventLoopPreference = eventLoopPreference
        self.task = task
        self.redirectHandler = redirectHandler
        self.request = request
        self.connectionDeadline = connectionDeadline
        self.idleReadTimeout = idleReadTimeout
        self.delegate = delegate

//        self.task.taskDelegate = self
//        self.task.futureResult.whenComplete { _ in
//            self.task.taskDelegate = nil
//        }
    }

    func willBeExecutedOnConnection(_ connection: HTTPConnectionPool.Connection) {
//        self.task.setConnection(connection)
    }

    func requestWasQueued(_ queuer: HTTP1RequestQueuer) {
        self.stateLock.withLock {
            guard case .initialized = self._state else {
                // There might be a race between `requestWasQueued` and `willExecuteRequest`. For
                // this reason we must check the state here... If we are not `.initialized`, we are
                // already executing.
                return
            }

            self._state = .queued(queuer)
        }
    }

    // MARK: - Request streaming -

    func willExecuteRequest(_ writer: HTTP1RequestExecutor) -> Bool {
        let start = self.stateLock.withLock { () -> Bool in
            switch self._state {
            case .initialized:
                self._state = .executing(writer, .initialized, .initialized)
                return true
            case .queued:
                self._state = .executing(writer, .initialized, .initialized)
                return true
            case .finished(error: .some):
                return false
            case .executing, .redirected, .finished(error: .none), .modifying:
                preconditionFailure("Invalid state: \(self._state)")
            }
        }

        return start
    }

    func requestHeadSent(_ head: HTTPRequestHead) {
        self.didSendRequestHead(head)
    }

    enum StartProducingAction {
        case startWriter(HTTPClient.Body.StreamWriter, body: HTTPClient.Body)
        case finishRequestStream(HTTP1RequestExecutor)
        case none
    }

    func startRequestBodyStream() {
        let produceAction = self.stateLock.withLock { () -> StartProducingAction in
            guard case .executing(let executor, .initialized, .initialized) = self._state else {
                if case .finished(.some) = self._state {
                    return .none
                }
                preconditionFailure("Expected the state to be either initialized or failed")
            }

            guard let body = self.request.body else {
                self._state = .executing(executor, .finished, .initialized)
                return .finishRequestStream(executor)
            }

            let streamWriter = HTTPClient.Body.StreamWriter { part -> EventLoopFuture<Void> in
                self.writeNextRequestPart(part)
            }

            self._state = .executing(executor, .producing, .initialized)

            return .startWriter(streamWriter, body: body)
        }

        switch produceAction {
        case .startWriter(let writer, body: let body):
            func start(writer: HTTPClient.Body.StreamWriter, body: HTTPClient.Body) {
                body.stream(writer).whenComplete {
                    self.finishRequestBodyStream($0)
                }
            }

            if self.task.eventLoop.inEventLoop {
                start(writer: writer, body: body)
            } else {
                return self.task.eventLoop.execute {
                    start(writer: writer, body: body)
                }
            }

        case .finishRequestStream(let writer):
            writer.finishRequestBodyStream(task: self)

            func runDidSendRequest() {
                self.didSendRequest()
            }

            if !self.task.eventLoop.inEventLoop {
                runDidSendRequest()
            } else {
                self.task.eventLoop.execute {
                    runDidSendRequest()
                }
            }

        case .none:
            break
        }
    }

    func pauseRequestBodyStream() {
        self.stateLock.withLock {
            switch self._state {
            case .initialized, .queued:
                preconditionFailure("A request stream can only be paused, if the request was started")
            case .executing(let executor, let requestState, let responseState):
                switch requestState {
                case .initialized:
                    preconditionFailure("Request stream must be started before it can be paused")
                case .producing:
                    self._state = .executing(executor, .paused(.init()), responseState)
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
                preconditionFailure("Invalid state")
            }
        }
    }

    func resumeRequestBodyStream() {
        let promises = self.stateLock.withLock { () -> [EventLoopPromise<Void>]? in
            switch self._state {
            case .initialized, .queued:
                preconditionFailure("A request stream can only be resumed, if the request was started")
            case .executing(let executor, let requestState, let responseState):
                switch requestState {
                case .initialized:
                    preconditionFailure("Request stream must be started before it can be paused")
                case .producing:
                    preconditionFailure("Expected that pause is only called when if we were paused before")
                case .paused(let promises):
                    self._state = .executing(executor, .producing, responseState)
                    return promises
                case .finished:
                    // the channels writability changed to writable after we have forwarded all the
                    // request bytes. Can be ignored.
                    return nil
                }

            case .redirected:
                // if we are redirected, we should cancel our request body stream anyway
                return nil

            case .finished:
                preconditionFailure("Invalid state")

            case .modifying:
                preconditionFailure("Invalid state")
            }
        }

        promises?.forEach { $0.succeed(()) }
    }

    enum WriteAction {
        case write(IOData, HTTP1RequestExecutor, EventLoopFuture<Void>)

        case failTask(Error)
        case failFuture(Error)
    }

    func writeNextRequestPart(_ part: IOData) -> EventLoopFuture<Void> {
        // this method is invoked with bodyPart and returns a future that signals that
        // more data can be send.
        // it may be invoked on any eventLoop

        let action = self.stateLock.withLock { () -> WriteAction in
            switch self._state {
            case .initialized, .queued:
                preconditionFailure("Invalid state: \(self._state)")
            case .executing(let executor, let requestState, let responseState):
                switch requestState {
                case .initialized:
                    preconditionFailure("Request stream must be started before it can be paused")
                case .producing:
                    return .write(part, executor, self.task.eventLoop.makeSucceededFuture(()))

                case .paused(var promises):
                    // backpressure is signaled to the writer using unfulfilled futures. let's
                    // create a new one for this write
                    self._state = .modifying
                    let promise = self.task.eventLoop.makePromise(of: Void.self)
                    promises.append(promise)
                    self._state = .executing(executor, .paused(promises), responseState)
                    return .write(part, executor, promise.futureResult)

                case .finished:
                    let error = HTTPClientError.writeAfterRequestSent
                    self._state = .finished(error: error)
                    return .failTask(error)
                }
            case .redirected:
                // if we are redirected we can cancel the upload stream
                return .failFuture(HTTPClientError.cancelled)
            case .finished(error: .some(let error)):
                return .failFuture(error)
            case .finished(error: .none):
                preconditionFailure("A write was made, after the request has completed")
            case .modifying:
                preconditionFailure("Invalid state")
            }
        }

        switch action {
        case .failTask(let error):
            if self.task.eventLoop.inEventLoop {
                self.delegate.didReceiveError(task: self.task, error)
                self.task.fail(with: error, delegateType: Delegate.self)
            } else {
                self.task.eventLoop.execute {
                    self.delegate.didReceiveError(task: self.task, error)
                    self.task.fail(with: error, delegateType: Delegate.self)
                }
            }
            return self.task.eventLoop.makeFailedFuture(error)

        case .failFuture(let error):
            return self.task.eventLoop.makeFailedFuture(error)

        case .write(let part, let writer, let future):
            writer.writeRequestBodyPart(part, task: self)
            self.didSendRequestPart(part)
            #warning("This is potentially dangerous... This could hot loop!")
            return future
        }
    }

    enum FinishAction {
        case forwardStreamFinished(HTTP1RequestExecutor, [EventLoopPromise<Void>]?)
        case forwardStreamFailureAndFailTask(HTTP1RequestExecutor, Error, [EventLoopPromise<Void>]?)
        case none
    }

    func finishRequestBodyStream(_ result: Result<Void, Error>) {
        let action = self.stateLock.withLock { () -> FinishAction in
            switch self._state {
            case .initialized, .queued:
                preconditionFailure("Invalid state: \(self._state)")
            case .executing(let executor, let requestState, let responseState):
                switch requestState {
                case .initialized:
                    preconditionFailure("Request stream must be started before it can be finished")
                case .producing:
                    switch result {
                    case .success:
                        self._state = .executing(executor, .finished, responseState)
                        return .forwardStreamFinished(executor, nil)
                    case .failure(let error):
                        self._state = .finished(error: error)
                        return .forwardStreamFailureAndFailTask(executor, error, nil)
                    }

                case .paused(let promises):
                    switch result {
                    case .success:
                        self._state = .executing(executor, .finished, responseState)
                        return .forwardStreamFinished(executor, promises)
                    case .failure(let error):
                        self._state = .finished(error: error)
                        return .forwardStreamFailureAndFailTask(executor, error, promises)
                    }

                case .finished:
                    preconditionFailure("How can a finished request stream, be finished again?")
                }
            case .redirected:
                return .none
            case .finished(error: _):
                return .none
            case .modifying:
                preconditionFailure("Invalid state")
            }
        }

        switch action {
        case .none:
            break
        case .forwardStreamFinished(let writer, let promises):
            writer.finishRequestBodyStream(task: self)
            promises?.forEach { $0.succeed(()) }
            self.didSendRequest()
        case .forwardStreamFailureAndFailTask(let writer, let error, let promises):
            writer.cancelRequest(task: self)
            promises?.forEach { $0.fail(error) }
            self.failTask(error)
        }
    }

    // MARK: Request delegate calls

    func didSendRequestHead(_ head: HTTPRequestHead) {
        guard self.task.eventLoop.inEventLoop else {
            return self.task.eventLoop.execute {
                self.didSendRequestHead(head)
            }
        }

        self.delegate.didSendRequestHead(task: self.task, head)
    }

    func didSendRequestPart(_ part: IOData) {
        guard self.task.eventLoop.inEventLoop else {
            return self.task.eventLoop.execute {
                self.didSendRequestPart(part)
            }
        }

        self.delegate.didSendRequestPart(task: self.task, part)
    }

    func didSendRequest() {
        guard self.task.eventLoop.inEventLoop else {
            return self.task.eventLoop.execute {
                self.didSendRequest()
            }
        }

        self.delegate.didSendRequest(task: self.task)
    }

    func failTask(_ error: Error) {
        self.task.promise.fail(error)

        guard self.task.eventLoop.inEventLoop else {
            return self.task.eventLoop.execute {
                self.delegate.didReceiveError(task: self.task, error)
            }
        }

        self.delegate.didReceiveError(task: self.task, error)
    }

    // MARK: - Response -

    func receiveResponseHead(_ head: HTTPResponseHead) {
        // runs most likely on channel eventLoop
        let forwardToDelegate = self.stateLock.withLock { () -> Bool in
            switch self._state {
            case .initialized, .queued:
                preconditionFailure("How can we receive a response, if the request hasn't started yet.")
            case .executing(let executor, let requestState, let responseState):
                guard case .initialized = responseState else {
                    preconditionFailure("If we receive a response, we must not have received something else before")
                }

                if let redirectURL = self.redirectHandler?.redirectTarget(status: head.status, headers: head.headers) {
                    self._state = .redirected(head, redirectURL)
                    return false
                } else {
                    self._state = .executing(executor, requestState, .buffering(.init(), next: .askExecutorForMore))
                    return true
                }
            case .redirected:
                preconditionFailure("This state can only be reached after we have received a HTTP head")
            case .finished(error: .some):
                return false
            case .finished(error: .none):
                preconditionFailure("How can the request be finished without error, before receiving response head?")
            case .modifying:
                preconditionFailure("Invalid state")
            }
        }

        guard forwardToDelegate else { return }

        // dispatch onto task eventLoop
        func runOnTaskEventLoop() {
            self.delegate.didReceiveHead(task: self.task, head)
                .hop(to: self.task.eventLoop)
                .whenComplete { result in
                    // After the head received, let's start to consume body data
                    self.consumeMoreBodyData(resultOfPreviousConsume: result)
                }
        }

        if self.task.eventLoop.inEventLoop {
            runOnTaskEventLoop()
        } else {
            self.task.eventLoop.execute {
                runOnTaskEventLoop()
            }
        }
    }

    func receiveResponseBodyPart(_ byteBuffer: ByteBuffer) {
        let forwardBuffer = self.stateLock.withLock { () -> ByteBuffer? in
            switch self._state {
            case .initialized, .queued:
                preconditionFailure("How can we receive a response body part, if the request hasn't started yet.")
            case .executing(_, _, .initialized):
                preconditionFailure("If we receive a response body, we must have received a head before")

            case .executing(let executor, let requestState, .buffering(var buffer, next: let next)):
                guard case .askExecutorForMore = next else {
                    preconditionFailure("If we have received an error or eof before, why did we get another body part? Next: \(next)")
                }

                self._state = .modifying
                buffer.append(byteBuffer)
                self._state = .executing(executor, requestState, .buffering(buffer, next: next))
                return nil
            case .executing(let executor, let requestState, .waitingForRemote(let buffer)):
                assert(buffer.isEmpty, "If we wait for remote, the buffer must be empty")
                self._state = .executing(executor, requestState, .buffering(buffer, next: .askExecutorForMore))
                return byteBuffer
            case .redirected:
                // ignore body
                return nil
            case .finished(error: .some):
                return nil
            case .finished(error: .none):
                preconditionFailure("How can the request be finished without error, before receiving response head?")
            case .modifying:
                preconditionFailure("Invalid state")
            }
        }

        guard let forwardBuffer = forwardBuffer else {
            return
        }

        // dispatch onto task eventLoop
        func runOnTaskEventLoop() {
            self.delegate.didReceiveBodyPart(task: self.task, forwardBuffer)
                .hop(to: self.task.eventLoop)
                .whenComplete { result in
                    // on task el
                    self.consumeMoreBodyData(resultOfPreviousConsume: result)
                }
        }

        if self.task.eventLoop.inEventLoop {
            runOnTaskEventLoop()
        } else {
            self.task.eventLoop.execute {
                runOnTaskEventLoop()
            }
        }
    }

    func receiveResponseEnd() {
        let forward = self.stateLock.withLock { () -> Bool in
            switch self._state {
            case .initialized, .queued:
                preconditionFailure("How can we receive a response body part, if the request hasn't started yet.")
            case .executing(_, _, .initialized):
                preconditionFailure("If we receive a response body, we must have received a head before")

            case .executing(let executor, let requestState, .buffering(let buffer, next: let next)):
                guard case .askExecutorForMore = next else {
                    preconditionFailure("If we have received an error or eof before, why did we get another body part? Next: \(next)")
                }

                self._state = .executing(executor, requestState, .buffering(buffer, next: .eof))
                return false

            case .executing(_, _, .waitingForRemote(let buffer)):
                assert(buffer.isEmpty, "If we wait for remote, the buffer must be empty")
                #warning("We need to consider that the request is NOT done here!")
                self._state = .finished(error: nil)
                return true

            case .redirected(let head, let redirectURL):
                self._state = .finished(error: nil)
                self.redirectHandler!.redirect(status: head.status, to: redirectURL, promise: self.task.promise)
                return false

            case .finished(error: .some):
                return false

            case .finished(error: .none):
                preconditionFailure("How can the request be finished without error, before receiving response head?")
            case .modifying:
                preconditionFailure("Invalid state")
            }
        }

        guard forward else {
            return
        }

        // dispatch onto task eventLoop
        func runOnTaskEventLoop() {
            do {
                let response = try self.delegate.didFinishRequest(task: task)
                self.task.promise.succeed(response)
            } catch {
                self.task.promise.fail(error)
            }
        }

        if self.task.eventLoop.inEventLoop {
            runOnTaskEventLoop()
        } else {
            self.task.eventLoop.execute {
                runOnTaskEventLoop()
            }
        }
    }

    func consumeMoreBodyData(resultOfPreviousConsume result: Result<Void, Error>) {
        switch result {
        case .success:
            self.consumeMoreBodyData()
        case .failure(let error):
            self.failWithConsumptionError(error)
        }
    }

    func failWithConsumptionError(_ error: Error) {
        let (executor, errorToFailWith) = self.stateLock.withLock { () -> (HTTP1RequestExecutor?, Error?) in
            switch self._state {
            case .initialized, .queued:
                preconditionFailure("Invalid state")
            case .executing(_, _, .initialized):
                preconditionFailure("Invalid state: Must have received response head, before this method is called for the first time")

            case .executing(_, _, .buffering(_, next: .error(let connectionError))):
                // if an error was received from the connection, we fail the task with the one
                // from the connection, since it happened first.
                self._state = .finished(error: connectionError)
                return (nil, connectionError)

            case .executing(let executor, _, .buffering(_, _)):
                self._state = .finished(error: error)
                return (executor, error)

            case .executing(_, _, .waitingForRemote):
                preconditionFailure("Invalid state... We just returned from a consumption function. We can't already be waiting")

            case .redirected:
                preconditionFailure("Invalid state... Redirect don't call out to delegate functions. Thus we should never land here.")

            case .finished(error: .some):
                // don't overwrite existing errors
                return (nil, nil)

            case .finished(error: .none):
                preconditionFailure("Invalid state... If no error occured, this must not be called, after the request was finished")

            case .modifying:
                preconditionFailure()
            }
        }

        executor?.cancelRequest(task: self)

        guard let errorToFailWith = errorToFailWith else { return }

        self.failTask(errorToFailWith)
    }

    enum ConsumeAction {
        case requestMoreFromExecutor(HTTP1RequestExecutor)
        case consume(ByteBuffer)
        case finishStream
        case failTask(Error)
        case doNothing
    }

    func consumeMoreBodyData() {
        let action = self.stateLock.withLock { () -> ConsumeAction in
            switch self._state {
            case .initialized, .queued:
                preconditionFailure("Invalid state")
            case .executing(_, _, .initialized):
                preconditionFailure("Invalid state: Must have received response head, before this method is called for the first time")
            case .executing(let executor, let requestState, .buffering(var buffer, next: .askExecutorForMore)):
                self._state = .modifying

                if let byteBuffer = buffer.popFirst() {
                    self._state = .executing(executor, requestState, .buffering(buffer, next: .askExecutorForMore))
                    return .consume(byteBuffer)
                }

                // buffer is empty, wait for more
                self._state = .executing(executor, requestState, .waitingForRemote(buffer))
                return .requestMoreFromExecutor(executor)

            case .executing(let executor, let requestState, .buffering(var buffer, next: .eof)):
                self._state = .modifying

                if let byteBuffer = buffer.popFirst() {
                    self._state = .executing(executor, requestState, .buffering(buffer, next: .eof))
                    return .consume(byteBuffer)
                }

                // buffer is empty, wait for more
                self._state = .finished(error: nil)
                return .finishStream

            case .executing(_, _, .buffering(_, next: .error(let error))):
                self._state = .finished(error: error)
                return .failTask(error)

            case .executing(_, _, .waitingForRemote):
                preconditionFailure("Invalid state... We just returned from a consumption function. We can't already be waiting")

            case .redirected:
                return .doNothing

            case .finished(error: .some):
                return .doNothing

            case .finished(error: .none):
                preconditionFailure("Invalid state... If no error occured, this must not be called, after the request was finished")

            case .modifying:
                preconditionFailure()
            }
        }

        self.logger.trace("Will run action", metadata: ["action": "\(action)"])

        switch action {
        case .consume(let byteBuffer):
            func executeOnEL() {
                self.delegate.didReceiveBodyPart(task: self.task, byteBuffer).whenComplete {
                    switch $0 {
                    case .success:
                        self.consumeMoreBodyData(resultOfPreviousConsume: $0)
                    case .failure(let error):
                        self.fail(error)
                    }
                }
            }

            if self.task.eventLoop.inEventLoop {
                executeOnEL()
            } else {
                self.task.eventLoop.execute {
                    executeOnEL()
                }
            }
        case .doNothing:
            break
        case .finishStream:
            func executeOnEL() {
                do {
                    let response = try self.delegate.didFinishRequest(task: task)
                    self.task.promise.succeed(response)
                } catch {
                    self.task.promise.fail(error)
                }
            }

            if self.task.eventLoop.inEventLoop {
                executeOnEL()
            } else {
                self.task.eventLoop.execute {
                    executeOnEL()
                }
            }
        case .failTask(let error):
            self.failTask(error)
        case .requestMoreFromExecutor(let executor):
            executor.demandResponseBodyStream(task: self)
        }
    }

    func fail(_ error: Error) {
        let (queuer, executor, forward) = self.stateLock.withLock {
            () -> (HTTP1RequestQueuer?, HTTP1RequestExecutor?, Bool) in

            switch self._state {
            case .initialized:
                self._state = .finished(error: error)
                return (nil, nil, true)
            case .queued(let queuer):
                self._state = .finished(error: error)
                return (queuer, nil, true)
            case .executing(let executor, let requestState, .buffering(_, next: .eof)):
                self._state = .executing(executor, requestState, .buffering(.init(), next: .error(error)))
                return (nil, executor, false)
            case .executing(let executor, let requestState, .buffering(_, next: .askExecutorForMore)):
                self._state = .executing(executor, requestState, .buffering(.init(), next: .error(error)))
                return (nil, executor, false)
            case .executing(let executor, _, .buffering(_, next: .error(_))):
                // this would override another error, let's keep the first one
                return (nil, executor, false)

            case .executing(let executor, _, .initialized):
                self._state = .finished(error: error)
                return (nil, executor, true)

            case .executing(let executor, _, .waitingForRemote(_)):
                self._state = .finished(error: error)
                return (nil, executor, true)

            case .redirected:
                self._state = .finished(error: error)
                return (nil, nil, true)

            case .finished(.none):
                // An error occured after the request has finished. Ignore...
                return (nil, nil, false)

            case .finished(.some(_)):
                // this might happen, if the stream consumer has failed... let's just drop the data
                return (nil, nil, false)

            case .modifying:
                preconditionFailure("Invalid state")
            }
        }

        queuer?.cancelRequest(task: self)
        executor?.cancelRequest(task: self)

        if forward {
            self.failTask(error)
        }
    }
}

extension RequestBag: HTTPClientTaskDelegate {
    func cancel() {
        self.fail(HTTPClientError.cancelled)
    }
}
