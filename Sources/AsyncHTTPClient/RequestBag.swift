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

import struct Foundation.URL
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1

final class RequestBag<Delegate: HTTPClientResponseDelegate> {
    let task: HTTPClient.Task<Delegate.Response>
    var eventLoop: EventLoop {
        self.task.eventLoop
    }

    private let delegate: Delegate
    private let request: HTTPClient.Request

    // the request state is synchronized on the task eventLoop
    private var state: StateMachine

    // MARK: HTTPClientTask properties

    var logger: Logger {
        self.task.logger
    }

    let connectionDeadline: NIODeadline

    let idleReadTimeout: TimeAmount?

    let requestHead: HTTPRequestHead
    let requestFramingMetadata: RequestFramingMetadata

    let eventLoopPreference: HTTPClient.EventLoopPreference

    init(request: HTTPClient.Request,
         eventLoopPreference: HTTPClient.EventLoopPreference,
         task: HTTPClient.Task<Delegate.Response>,
         redirectHandler: RedirectHandler<Delegate.Response>?,
         connectionDeadline: NIODeadline,
         idleReadTimeout: TimeAmount?,
         delegate: Delegate) throws {
        self.eventLoopPreference = eventLoopPreference
        self.task = task
        self.state = .init(redirectHandler: redirectHandler)
        self.request = request
        self.connectionDeadline = connectionDeadline
        self.idleReadTimeout = idleReadTimeout
        self.delegate = delegate

        let (head, metadata) = try request.createRequestHead()
        self.requestHead = head
        self.requestFramingMetadata = metadata

        // TODO: comment in once we switch to using the Request bag in AHC
//        self.task.taskDelegate = self
//        self.task.futureResult.whenComplete { _ in
//            self.task.taskDelegate = nil
//        }
    }

    private func requestWasQueued0(_ scheduler: HTTPRequestScheduler) {
        self.task.eventLoop.assertInEventLoop()
        self.state.requestWasQueued(scheduler)
    }

    // MARK: - Request -

    private func willExecuteRequest0(_ executor: HTTPRequestExecutor) {
        self.task.eventLoop.assertInEventLoop()
        if !self.state.willExecuteRequest(executor) {
            return executor.cancelRequest(self)
        }
    }

    private func requestHeadSent0() {
        self.task.eventLoop.assertInEventLoop()

        self.delegate.didSendRequestHead(task: self.task, self.requestHead)

        if self.request.body == nil {
            self.delegate.didSendRequest(task: self.task)
        }
    }

    private func resumeRequestBodyStream0() {
        self.task.eventLoop.assertInEventLoop()

        let produceAction = self.state.resumeRequestBodyStream()

        switch produceAction {
        case .startWriter:
            guard let body = self.request.body else {
                preconditionFailure("Expected to have a body, if the `HTTPRequestStateMachine` resume a request stream")
            }

            let writer = HTTPClient.Body.StreamWriter {
                self.writeNextRequestPart($0)
            }

            body.stream(writer).whenComplete {
                self.finishRequestBodyStream($0)
            }

        case .succeedBackpressurePromise(let promise):
            promise?.succeed(())

        case .none:
            break
        }
    }

    private func pauseRequestBodyStream0() {
        self.task.eventLoop.assertInEventLoop()

        self.state.pauseRequestBodyStream()
    }

    private func writeNextRequestPart(_ part: IOData) -> EventLoopFuture<Void> {
        if self.eventLoop.inEventLoop {
            return self.writeNextRequestPart0(part)
        } else {
            return self.eventLoop.flatSubmit {
                self.writeNextRequestPart0(part)
            }
        }
    }

    private func writeNextRequestPart0(_ part: IOData) -> EventLoopFuture<Void> {
        self.task.eventLoop.assertInEventLoop()

        let action = self.state.writeNextRequestPart(part, taskEventLoop: self.task.eventLoop)

        switch action {
        case .failTask(let error):
            self.delegate.didReceiveError(task: self.task, error)
            self.task.fail(with: error, delegateType: Delegate.self)
            return self.task.eventLoop.makeFailedFuture(error)

        case .failFuture(let error):
            return self.task.eventLoop.makeFailedFuture(error)

        case .write(let part, let writer, let future):
            writer.writeRequestBodyPart(part, request: self)
            self.delegate.didSendRequestPart(task: self.task, part)
            return future
        }
    }

    private func finishRequestBodyStream(_ result: Result<Void, Error>) {
        self.task.eventLoop.assertInEventLoop()

        let action = self.state.finishRequestBodyStream(result)

        switch action {
        case .none:
            break
        case .forwardStreamFinished(let writer, let promise):
            writer.finishRequestBodyStream(self)
            promise?.succeed(())

            self.delegate.didSendRequest(task: self.task)

        case .forwardStreamFailureAndFailTask(let writer, let error, let promise):
            writer.cancelRequest(self)
            promise?.fail(error)
            self.failTask0(error)
        }
    }

    // MARK: Request delegate calls

    func failTask0(_ error: Error) {
        self.task.eventLoop.assertInEventLoop()

        self.delegate.didReceiveError(task: self.task, error)
        self.task.promise.fail(error)
    }

    // MARK: - Response -

    private func receiveResponseHead0(_ head: HTTPResponseHead) {
        self.task.eventLoop.assertInEventLoop()

        // runs most likely on channel eventLoop
        let forwardToDelegate = self.state.receiveResponseHead(head)

        guard forwardToDelegate else { return }

        self.delegate.didReceiveHead(task: self.task, head)
            .hop(to: self.task.eventLoop)
            .whenComplete { result in
                // After the head received, let's start to consume body data
                self.consumeMoreBodyData0(resultOfPreviousConsume: result)
            }
    }

    private func receiveResponseBodyParts0(_ buffer: CircularBuffer<ByteBuffer>) {
        self.task.eventLoop.assertInEventLoop()

        let maybeForwardBuffer = self.state.receiveResponseBodyParts(buffer)

        guard let forwardBuffer = maybeForwardBuffer else {
            return
        }

        self.delegate.didReceiveBodyPart(task: self.task, forwardBuffer)
            .hop(to: self.task.eventLoop)
            .whenComplete { result in
                // on task el
                self.consumeMoreBodyData0(resultOfPreviousConsume: result)
            }
    }

    private func succeedRequest0(_ buffer: CircularBuffer<ByteBuffer>?) {
        self.task.eventLoop.assertInEventLoop()
        let action = self.state.succeedRequest(buffer)

        switch action {
        case .none:
            break
        case .consume(let buffer):
            self.delegate.didReceiveBodyPart(task: self.task, buffer)
                .hop(to: self.task.eventLoop)
                .whenComplete {
                    switch $0 {
                    case .success:
                        self.consumeMoreBodyData0(resultOfPreviousConsume: $0)
                    case .failure(let error):
                        // if in the response stream consumption an error has occurred, we need to
                        // cancel the running request and fail the task.
                        self.fail(error)
                    }
                }

        case .succeedRequest:
            do {
                let response = try self.delegate.didFinishRequest(task: task)
                self.task.promise.succeed(response)
            } catch {
                self.task.promise.fail(error)
            }

        case .redirect(let handler, let head, let newURL):
            handler.redirect(status: head.status, to: newURL, promise: self.task.promise)
        }
    }

    private func consumeMoreBodyData0(resultOfPreviousConsume result: Result<Void, Error>) {
        self.task.eventLoop.assertInEventLoop()

        let consumptionAction = self.state.consumeMoreBodyData(resultOfPreviousConsume: result)

        switch consumptionAction {
        case .consume(let byteBuffer):
            self.delegate.didReceiveBodyPart(task: self.task, byteBuffer)
                .hop(to: self.task.eventLoop)
                .whenComplete {
                    switch $0 {
                    case .success:
                        self.consumeMoreBodyData0(resultOfPreviousConsume: $0)
                    case .failure(let error):
                        self.fail(error)
                    }
                }

        case .doNothing:
            break
        case .finishStream:
            do {
                let response = try self.delegate.didFinishRequest(task: task)
                self.task.promise.succeed(response)
            } catch {
                self.task.promise.fail(error)
            }

        case .failTask(let error, let executor):
            executor?.cancelRequest(self)
            self.failTask0(error)
        case .requestMoreFromExecutor(let executor):
            executor.demandResponseBodyStream(self)
        }
    }

    private func fail0(_ error: Error) {
        self.task.eventLoop.assertInEventLoop()

        let action = self.state.fail(error)

        switch action {
        case .failTask(let scheduler, let executor):
            scheduler?.cancelRequest(self)
            executor?.cancelRequest(self)
            self.failTask0(error)
        case .cancelExecutor(let executor):
            executor.cancelRequest(self)
        case .none:
            break
        }
    }
}

extension RequestBag: HTTPSchedulableRequest {
    func requestWasQueued(_ scheduler: HTTPRequestScheduler) {
        if self.task.eventLoop.inEventLoop {
            self.requestWasQueued0(scheduler)
        } else {
            self.task.eventLoop.execute {
                self.requestWasQueued0(scheduler)
            }
        }
    }

    func fail(_ error: Error) {
        if self.task.eventLoop.inEventLoop {
            self.fail0(error)
        } else {
            self.task.eventLoop.execute {
                self.fail0(error)
            }
        }
    }
}

extension RequestBag: HTTPExecutableRequest {
    func willExecuteRequest(_ executor: HTTPRequestExecutor) {
        if self.task.eventLoop.inEventLoop {
            self.willExecuteRequest0(executor)
        } else {
            self.task.eventLoop.execute {
                self.willExecuteRequest0(executor)
            }
        }
    }

    func requestHeadSent() {
        if self.task.eventLoop.inEventLoop {
            self.requestHeadSent0()
        } else {
            self.task.eventLoop.execute {
                self.requestHeadSent0()
            }
        }
    }

    func resumeRequestBodyStream() {
        if self.task.eventLoop.inEventLoop {
            self.resumeRequestBodyStream0()
        } else {
            self.task.eventLoop.execute {
                self.resumeRequestBodyStream0()
            }
        }
    }

    func pauseRequestBodyStream() {
        if self.task.eventLoop.inEventLoop {
            self.pauseRequestBodyStream0()
        } else {
            self.task.eventLoop.execute {
                self.pauseRequestBodyStream0()
            }
        }
    }

    func receiveResponseHead(_ head: HTTPResponseHead) {
        if self.task.eventLoop.inEventLoop {
            self.receiveResponseHead0(head)
        } else {
            self.task.eventLoop.execute {
                self.receiveResponseHead0(head)
            }
        }
    }

    func receiveResponseBodyParts(_ buffer: CircularBuffer<ByteBuffer>) {
        if self.task.eventLoop.inEventLoop {
            self.receiveResponseBodyParts0(buffer)
        } else {
            self.task.eventLoop.execute {
                self.receiveResponseBodyParts0(buffer)
            }
        }
    }

    func succeedRequest(_ buffer: CircularBuffer<ByteBuffer>?) {
        if self.task.eventLoop.inEventLoop {
            self.succeedRequest0(buffer)
        } else {
            self.task.eventLoop.execute {
                self.succeedRequest0(buffer)
            }
        }
    }
}

extension RequestBag: HTTPClientTaskDelegate {
    func cancel() {
        if self.task.eventLoop.inEventLoop {
            self.fail0(HTTPClientError.cancelled)
        } else {
            self.task.eventLoop.execute {
                self.fail0(HTTPClientError.cancelled)
            }
        }
    }
}
