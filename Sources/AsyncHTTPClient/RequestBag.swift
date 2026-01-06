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
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOSSL
import Tracing

@preconcurrency
final class RequestBag<Delegate: HTTPClientResponseDelegate & Sendable>: Sendable {
    /// Defends against the call stack getting too large when consuming body parts.
    ///
    /// If the response body comes in lots of tiny chunks, we'll deliver those tiny chunks to users
    /// one at a time.
    private static var maxConsumeBodyPartStackDepth: Int {
        50
    }

    let poolKey: ConnectionPool.Key

    let task: HTTPClient.Task<Delegate.Response>
    var eventLoop: EventLoop {
        self.task.eventLoop
    }

    private let delegate: Delegate

    struct LoopBoundState: @unchecked Sendable {
        // The 'StateMachine' *isn't* Sendable (it holds various objects which aren't). This type
        // needs to be sendable so that we can construct a loop bound box off of the event loop
        // to hold this state and then subsequently only access it from the event loop. This needs
        // to happen so that the request bag can be constructed off of the event loop. If it's
        // constructed on the event loop then there's a timing window between users issuing
        // a request and calling shutdown where the underlying pool doesn't know about the request
        // so the shutdown call may cancel it.
        var request: HTTPClient.Request
        var state: StateMachine
        var consumeBodyPartStackDepth: Int
        // if a redirect occurs, we store the task for it so we can propagate cancellation
        var redirectTask: HTTPClient.Task<Delegate.Response>? = nil

        // - Distributed tracing
        var tracing: HTTPClient.TracingConfiguration
        // The current span, representing the entire request/response made by an execute call.
        var activeSpan: (any Span)? = nil
    }

    private let loopBoundState: NIOLoopBoundBox<LoopBoundState>

    // MARK: HTTPClientTask properties

    var logger: Logger {
        self.task.logger
    }

    // Available unconditionally, so we can simplify callsites which can just try to pass this value
    // regardless if the real tracer exists or not.
    var anyTracer: (any Sendable)? {
        self.task.tracing._tracer
    }
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    var tracer: (any Tracer)? {
        self.task.tracer
    }

    let connectionDeadline: NIODeadline

    let requestOptions: RequestOptions

    let requestHead: HTTPRequestHead
    let requestFramingMetadata: RequestFramingMetadata

    let eventLoopPreference: HTTPClient.EventLoopPreference

    let tlsConfiguration: TLSConfiguration?

    init(
        request: HTTPClient.Request,
        eventLoopPreference: HTTPClient.EventLoopPreference,
        task: HTTPClient.Task<Delegate.Response>,
        redirectHandler: RedirectHandler<Delegate.Response>?,
        connectionDeadline: NIODeadline,
        requestOptions: RequestOptions,
        delegate: Delegate
    ) throws {
        self.poolKey = .init(request, dnsOverride: requestOptions.dnsOverride)
        self.eventLoopPreference = eventLoopPreference
        self.task = task

        let loopBoundState = LoopBoundState(
            request: request,
            state: StateMachine(redirectHandler: redirectHandler),
            consumeBodyPartStackDepth: 0,
            tracing: task.tracing
        )
        self.loopBoundState = NIOLoopBoundBox.makeBoxSendingValue(loopBoundState, eventLoop: task.eventLoop)
        self.connectionDeadline = connectionDeadline
        self.requestOptions = requestOptions
        self.delegate = delegate

        let (head, metadata) = try request.createRequestHead()
        self.requestHead = head
        self.requestFramingMetadata = metadata

        self.tlsConfiguration = request.tlsConfiguration

        self.task.taskDelegate = self
        self.task.futureResult.whenComplete { _ in
            self.task.taskDelegate = nil
        }
    }

    private func requestWasQueued0(_ scheduler: HTTPRequestScheduler) {
        self.logger.debug("Request was queued (waiting for a connection to become available)")
        self.loopBoundState.value.state.requestWasQueued(scheduler)
    }

    // MARK: - Request -

    private func willExecuteRequest0(_ executor: HTTPRequestExecutor) {
        // Immediately start a span for the "whole" request
        self.loopBoundState.value.startRequestSpan(tracer: self.anyTracer)

        let action = self.loopBoundState.value.state.willExecuteRequest(executor)
        switch action {
        case .cancelExecuter(let executor):
            executor.cancelRequest(self)
            self.loopBoundState.value.failRequestSpanAsCancelled()
        case .failTaskAndCancelExecutor(let error, let executor):
            self.delegate.didReceiveError(task: self.task, error)
            self.task.failInternal(with: error)
            executor.cancelRequest(self)
            self.loopBoundState.value.failRequestSpan(error: error)
        case .none:
            break
        }
    }

    private func requestHeadSent0() {
        self.delegate.didSendRequestHead(task: self.task, self.requestHead)

        if self.loopBoundState.value.request.body == nil {
            self.delegate.didSendRequest(task: self.task)
        }
    }

    private func resumeRequestBodyStream0() {
        let produceAction = self.loopBoundState.value.state.resumeRequestBodyStream()

        switch produceAction {
        case .startWriter:
            guard let body = self.loopBoundState.value.request.body else {
                preconditionFailure("Expected to have a body, if the `HTTPRequestStateMachine` resume a request stream")
            }
            self.loopBoundState.value.request.body = nil

            let writer = HTTPClient.Body.StreamWriter {
                self.writeNextRequestPart($0)
            }

            body.stream(writer).hop(to: self.eventLoop).whenComplete {
                self.finishRequestBodyStream($0)
            }

        case .succeedBackpressurePromise(let promise):
            promise?.succeed(())

        case .none:
            break
        }
    }

    private func pauseRequestBodyStream0() {
        self.loopBoundState.value.state.pauseRequestBodyStream()
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
        let action = self.loopBoundState.value.state.writeNextRequestPart(part, taskEventLoop: self.task.eventLoop)

        switch action {
        case .failTask(let error):
            self.delegate.didReceiveError(task: self.task, error)
            self.task.failInternal(with: error)
            return self.task.eventLoop.makeFailedFuture(error)

        case .failFuture(let error):
            return self.task.eventLoop.makeFailedFuture(error)

        case .write(let part, let writer, let future):
            let promise = self.task.eventLoop.makePromise(of: Void.self)
            promise.futureResult.whenSuccess {
                self.delegate.didSendRequestPart(task: self.task, part)
            }
            writer.writeRequestBodyPart(part, request: self, promise: promise)
            return future
        }
    }

    private func finishRequestBodyStream(_ result: Result<Void, Error>) {
        let action = self.loopBoundState.value.state.finishRequestBodyStream(result)

        switch action {
        case .none:
            break
        case .forwardStreamFinished(let writer, let writerPromise):
            let promise = writerPromise ?? self.task.eventLoop.makePromise(of: Void.self)
            promise.futureResult.whenSuccess {
                self.delegate.didSendRequest(task: self.task)
            }
            writer.finishRequestBodyStream(self, promise: promise)

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
        self.delegate.didVisitURL(task: self.task, self.loopBoundState.value.request, head)
        self.loopBoundState.value.endRequestSpan(response: head)

        // runs most likely on channel eventLoop
        switch self.loopBoundState.value.state.receiveResponseHead(head) {
        case .none:
            break

        case .signalBodyDemand(let executor):
            executor.demandResponseBodyStream(self)

        case .redirect(let executor, let handler, let head, let newURL):
            self.loopBoundState.value.redirectTask = handler.redirect(
                status: head.status,
                to: newURL,
                promise: self.task.promise
            )
            executor.cancelRequest(self)

        case .forwardResponseHead(let head):
            self.delegate.didReceiveHead(task: self.task, head)
                .hop(to: self.task.eventLoop)
                .whenComplete { result in
                    // After the head received, let's start to consume body data
                    self.consumeMoreBodyData0(resultOfPreviousConsume: result)
                }
        }
    }

    private func receiveResponseBodyParts0(_ buffer: CircularBuffer<ByteBuffer>) {
        switch self.loopBoundState.value.state.receiveResponseBodyParts(buffer) {
        case .none:
            break

        case .signalBodyDemand(let executor):
            executor.demandResponseBodyStream(self)

        case .redirect(let executor, let handler, let head, let newURL):
            self.loopBoundState.value.redirectTask = handler.redirect(
                status: head.status,
                to: newURL,
                promise: self.task.promise
            )
            executor.cancelRequest(self)

        case .forwardResponsePart(let part):
            self.delegate.didReceiveBodyPart(task: self.task, part)
                .hop(to: self.task.eventLoop)
                .whenComplete { result in
                    // on task el
                    self.consumeMoreBodyData0(resultOfPreviousConsume: result)
                }
        }
    }

    private func receiveResponseEnd0(_ buffer: CircularBuffer<ByteBuffer>?) {
        let action = self.loopBoundState.value.state.receiveResponseEnd(buffer)

        switch action {
        case .none:
            break
        case .consume(let buffer):
            self.delegate.didReceiveBodyPart(task: self.task, buffer)
                .hop(to: self.task.eventLoop)
                .whenComplete {
                    self.consumeMoreBodyData0(resultOfPreviousConsume: $0)
                }

        case .succeedRequest:
            do {
                let response = try self.delegate.didFinishRequest(task: self.task)
                self.task.promise.succeed(response)
            } catch {
                self.task.promise.fail(error)
            }

        case .redirect(let handler, let head, let newURL):
            self.loopBoundState.value.redirectTask = handler.redirect(
                status: head.status,
                to: newURL,
                promise: self.task.promise
            )
        }
    }

    private func consumeMoreBodyData0(resultOfPreviousConsume result: Result<Void, Error>) {
        // We get defensive here about the maximum stack depth. It's possible for the `didReceiveBodyPart`
        // future to be returned to us completed. If it is, we will recurse back into this method. To
        // break that recursion we have a max stack depth which we increment and decrement in this method:
        // if it gets too large, instead of recurring we'll insert an `eventLoop.execute`, which will
        // manually break the recursion and unwind the stack.
        //
        // Note that we don't bother starting this at the various other call sites that _begin_ stacks
        // that risk ending up in this loop. That's because we don't need an accurate count: our limit is
        // a best-effort target anyway, one stack frame here or there does not put us at risk. We're just
        // trying to prevent ourselves looping out of control.
        self.loopBoundState.value.consumeBodyPartStackDepth += 1
        defer {
            self.loopBoundState.value.consumeBodyPartStackDepth -= 1
            assert(self.loopBoundState.value.consumeBodyPartStackDepth >= 0)
        }

        let consumptionAction = self.loopBoundState.value.state.consumeMoreBodyData(
            resultOfPreviousConsume: result
        )

        switch consumptionAction {
        case .consume(let byteBuffer):
            self.delegate.didReceiveBodyPart(task: self.task, byteBuffer)
                .hop(to: self.task.eventLoop)
                .assumeIsolated()
                .whenComplete { result in
                    if self.loopBoundState.value.consumeBodyPartStackDepth < Self.maxConsumeBodyPartStackDepth {
                        self.consumeMoreBodyData0(resultOfPreviousConsume: result)
                    } else {
                        // We need to unwind the stack, let's take a break.
                        self.task.eventLoop.assumeIsolated().execute {
                            self.consumeMoreBodyData0(resultOfPreviousConsume: result)
                        }
                    }
                }

        case .doNothing:
            break
        case .finishStream:
            do {
                let response = try self.delegate.didFinishRequest(task: self.task)
                self.task.promise.assumeIsolated().succeed(response)
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
        let action = self.loopBoundState.value.state.fail(error)

        self.executeFailAction0(action)

        self.loopBoundState.value.redirectTask?.fail(reason: error)
    }

    private func executeFailAction0(_ action: RequestBag<Delegate>.StateMachine.FailAction) {
        switch action {
        case .failTask(let error, let scheduler, let executor):
            scheduler?.cancelRequest(self)
            executor?.cancelRequest(self)
            self.failTask0(error)
        case .cancelExecutor(let executor):
            executor.cancelRequest(self)
        case .none:
            break
        }
    }

    func deadlineExceeded0() {
        let action = self.loopBoundState.value.state.deadlineExceeded()

        switch action {
        case .cancelScheduler(let scheduler):
            scheduler?.cancelRequest(self)
        case .fail(let failAction):
            self.executeFailAction0(failAction)
        }
    }

    func deadlineExceeded() {
        if self.task.eventLoop.inEventLoop {
            self.deadlineExceeded0()
        } else {
            self.task.eventLoop.execute {
                self.deadlineExceeded0()
            }
        }
    }
}

extension RequestBag: HTTPSchedulableRequest, HTTPClientTaskDelegate {

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
    var requiredEventLoop: EventLoop? {
        switch self.eventLoopPreference.preference {
        case .indifferent, .delegate:
            return nil
        case .delegateAndChannel(on: let eventLoop), .testOnly_exact(channelOn: let eventLoop, delegateOn: _):
            return eventLoop
        }
    }

    var preferredEventLoop: EventLoop {
        switch self.eventLoopPreference.preference {
        case .indifferent:
            return self.task.eventLoop
        case .delegate(let eventLoop),
            .delegateAndChannel(on: let eventLoop),
            .testOnly_exact(channelOn: let eventLoop, delegateOn: _):
            return eventLoop
        }
    }

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

    func receiveResponseEnd(_ buffer: CircularBuffer<ByteBuffer>?, trailers: HTTPHeaders?) {
        if self.task.eventLoop.inEventLoop {
            self.receiveResponseEnd0(buffer)
        } else {
            self.task.eventLoop.execute {
                self.receiveResponseEnd0(buffer)
            }
        }
    }
}
