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

final class HTTP1ClientChannelHandler: ChannelDuplexHandler {
    typealias OutboundIn = HTTPExecutableRequest
    typealias OutboundOut = HTTPClientRequestPart
    typealias InboundIn = HTTPClientResponsePart

    private var state: HTTP1ConnectionStateMachine = .init() {
        didSet {
            self.eventLoop.assertInEventLoop()
        }
    }

    /// while we are in a channel pipeline, this context can be used.
    private var channelContext: ChannelHandlerContext?

    /// the currently executing request
    private var request: HTTPExecutableRequest? {
        didSet {
            if let newRequest = self.request {
                var requestLogger = newRequest.logger
                requestLogger[metadataKey: "ahc-connection-id"] = "\(self.connection.id)"
                requestLogger[metadataKey: "ahc-el"] = "\(self.connection.channel.eventLoop)"
                self.logger = requestLogger

                if let idleReadTimeout = newRequest.requestOptions.idleReadTimeout {
                    self.idleReadTimeoutStateMachine = .init(timeAmount: idleReadTimeout)
                }
            } else {
                self.logger = self.backgroundLogger
                self.idleReadTimeoutStateMachine = nil
            }
        }
    }

    private var idleReadTimeoutStateMachine: IdleReadStateMachine?
    private var idleReadTimeoutTimer: Scheduled<Void>?

    /// Cancelling a task in NIO does *not* guarantee that the task will not execute under certain race conditions.
    /// We therefore give each timer an ID and increase the ID every time we reset or cancel it.
    /// We check in the task if the timer ID has changed in the meantime and do not execute any action if has changed.
    private var currentIdleReadTimeoutTimerID: Int = 0

    private let backgroundLogger: Logger
    private var logger: Logger

    let connection: HTTP1Connection
    let eventLoop: EventLoop

    init(connection: HTTP1Connection, eventLoop: EventLoop, logger: Logger) {
        self.connection = connection
        self.eventLoop = eventLoop
        self.backgroundLogger = logger
        self.logger = self.backgroundLogger
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.channelContext = context

        if context.channel.isActive {
            let action = self.state.channelActive(isWritable: context.channel.isWritable)
            self.run(action, context: context)
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.channelContext = nil
    }

    // MARK: Channel Inbound Handler

    func channelActive(context: ChannelHandlerContext) {
        self.logger.trace("Channel active", metadata: [
            "ahc-channel-writable": "\(context.channel.isWritable)",
        ])

        let action = self.state.channelActive(isWritable: context.channel.isWritable)
        self.run(action, context: context)
    }

    func channelInactive(context: ChannelHandlerContext) {
        self.logger.trace("Channel inactive")

        let action = self.state.channelInactive()
        self.run(action, context: context)
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        self.logger.trace("Channel writability changed", metadata: [
            "ahc-channel-writable": "\(context.channel.isWritable)",
        ])

        let action = self.state.writabilityChanged(writable: context.channel.isWritable)
        self.run(action, context: context)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let httpPart = self.unwrapInboundIn(data)

        self.logger.trace("HTTP response part received", metadata: [
            "ahc-http-part": "\(httpPart)",
        ])

        if let timeoutAction = self.idleReadTimeoutStateMachine?.channelRead(httpPart) {
            self.runTimeoutAction(timeoutAction, context: context)
        }

        let action = self.state.channelRead(httpPart)
        self.run(action, context: context)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        self.logger.trace("Channel read complete caught")

        let action = self.state.channelReadComplete()
        self.run(action, context: context)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        self.logger.trace("Channel error caught", metadata: [
            "ahc-error": "\(error)",
        ])

        let action = self.state.errorHappened(error)
        self.run(action, context: context)
    }

    // MARK: Channel Outbound Handler

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        assert(self.request == nil, "Only write to the ChannelHandler if you are sure, it is idle!")
        let req = self.unwrapOutboundIn(data)
        self.request = req

        self.logger.debug("Request was scheduled on connection")
        req.willExecuteRequest(self)

        let action = self.state.runNewRequest(
            head: req.requestHead,
            metadata: req.requestFramingMetadata
        )
        self.run(action, context: context)
    }

    func read(context: ChannelHandlerContext) {
        self.logger.trace("Read event caught")

        let action = self.state.read()
        self.run(action, context: context)
    }

    func triggerUserOutboundEvent(context: ChannelHandlerContext, event: Any, promise: EventLoopPromise<Void>?) {
        switch event {
        case HTTPConnectionEvent.shutdownRequested:
            self.logger.trace("User outbound event triggered: Cancel request for connection close")
            let action = self.state.requestCancelled(closeConnection: true)
            self.run(action, context: context)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    // MARK: - Private Methods -

    // MARK: Run Actions

    private func run(_ action: HTTP1ConnectionStateMachine.Action, context: ChannelHandlerContext) {
        switch action {
        case .sendRequestHead(let head, startBody: let startBody):
            self.sendRequestHead(head, startBody: startBody, context: context)

        case .sendBodyPart(let part, let writePromise):
            context.writeAndFlush(self.wrapOutboundOut(.body(part)), promise: writePromise)

        case .sendRequestEnd(let writePromise):
            context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: writePromise)

            if let timeoutAction = self.idleReadTimeoutStateMachine?.requestEndSent() {
                self.runTimeoutAction(timeoutAction, context: context)
            }

        case .pauseRequestBodyStream:
            // We can force unwrap the request here, as we have just validated in the state machine,
            // that the request is neither failed nor finished yet
            self.request!.pauseRequestBodyStream()

        case .resumeRequestBodyStream:
            // We can force unwrap the request here, as we have just validated in the state machine,
            // that the request is neither failed nor finished yet
            self.request!.resumeRequestBodyStream()

        case .fireChannelActive:
            context.fireChannelActive()

        case .fireChannelInactive:
            context.fireChannelInactive()

        case .fireChannelError(let error, let close):
            context.fireErrorCaught(error)
            if close {
                context.close(promise: nil)
            }

        case .read:
            context.read()

        case .close:
            context.close(promise: nil)

        case .wait:
            break

        case .forwardResponseHead(let head, let pauseRequestBodyStream):
            // We can force unwrap the request here, as we have just validated in the state machine,
            // that the request is neither failed nor finished yet
            self.request!.receiveResponseHead(head)
            if pauseRequestBodyStream, let request = self.request {
                // The above response head forward might lead the request to mark itself as
                // cancelled, which in turn might pop the request of the handler. For this reason we
                // must check if the request is still present here.
                request.pauseRequestBodyStream()
            }

        case .forwardResponseBodyParts(let buffer):
            // We can force unwrap the request here, as we have just validated in the state machine,
            // that the request is neither failed nor finished yet
            self.request!.receiveResponseBodyParts(buffer)

        case .succeedRequest(let finalAction, let buffer):
            // We can force unwrap the request here, as we have just validated in the state machine,
            // that the request is neither failed nor finished yet

            // The order here is very important...
            // We first nil our own task property! `taskCompleted` will potentially lead to
            // situations in which we get a new request right away. We should finish the task
            // after the connection was notified, that we finished. A
            // `HTTPClient.shutdown(requiresCleanShutdown: true)` will fail if we do it the
            // other way around.

            let oldRequest = self.request!
            self.request = nil
            self.runTimeoutAction(.clearIdleReadTimeoutTimer, context: context)

            switch finalAction {
            case .close:
                context.close(promise: nil)
                oldRequest.succeedRequest(buffer)
            case .sendRequestEnd(let writePromise, let shouldClose):
                let writePromise = writePromise ?? context.eventLoop.makePromise(of: Void.self)
                // We need to defer succeeding the old request to avoid ordering issues
                writePromise.futureResult.hop(to: context.eventLoop).whenComplete { result in
                    switch result {
                    case .success:
                        // If our final action was `sendRequestEnd`, that means we've already received
                        // the complete response. As a result, once we've uploaded all the body parts
                        // we need to tell the pool that the connection is idle or, if we were asked to
                        // close when we're done, send the close. Either way, we then succeed the request
                        if shouldClose {
                            context.close(promise: nil)
                        } else {
                            self.connection.taskCompleted()
                        }

                        oldRequest.succeedRequest(buffer)
                    case .failure(let error):
                        context.close(promise: nil)
                        oldRequest.fail(error)
                    }
                }

                context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: writePromise)
            case .informConnectionIsIdle:
                self.connection.taskCompleted()
                oldRequest.succeedRequest(buffer)
            }

        case .failRequest(let error, let finalAction):
            // see comment in the `succeedRequest` case.
            let oldRequest = self.request!
            self.request = nil
            self.runTimeoutAction(.clearIdleReadTimeoutTimer, context: context)

            switch finalAction {
            case .close(let writePromise):
                context.close(promise: nil)
                writePromise?.fail(error)
                oldRequest.fail(error)

            case .informConnectionIsIdle:
                self.connection.taskCompleted()
                oldRequest.fail(error)

            case .failWritePromise(let writePromise):
                writePromise?.fail(error)
                oldRequest.fail(error)

            case .none:
                oldRequest.fail(error)
            }

        case .failSendBodyPart(let error, let writePromise), .failSendStreamFinished(let error, let writePromise):
            writePromise?.fail(error)
        }
    }

    private func sendRequestHead(_ head: HTTPRequestHead, startBody: Bool, context: ChannelHandlerContext) {
        if startBody {
            context.writeAndFlush(self.wrapOutboundOut(.head(head)), promise: nil)

            // The above write might trigger an error, which may lead to a call to `errorCaught`,
            // which in turn, may fail the request and pop it from the handler. For this reason
            // we must check if the request is still present here.
            guard let request = self.request else { return }
            request.requestHeadSent()
            request.resumeRequestBodyStream()
        } else {
            context.write(self.wrapOutboundOut(.head(head)), promise: nil)
            context.write(self.wrapOutboundOut(.end(nil)), promise: nil)
            context.flush()

            // The above write might trigger an error, which may lead to a call to `errorCaught`,
            // which in turn, may fail the request and pop it from the handler. For this reason
            // we must check if the request is still present here.
            guard let request = self.request else { return }
            request.requestHeadSent()

            if let timeoutAction = self.idleReadTimeoutStateMachine?.requestEndSent() {
                self.runTimeoutAction(timeoutAction, context: context)
            }
        }
    }

    private func runTimeoutAction(_ action: IdleReadStateMachine.Action, context: ChannelHandlerContext) {
        switch action {
        case .startIdleReadTimeoutTimer(let timeAmount):
            assert(self.idleReadTimeoutTimer == nil, "Expected there is no timeout timer so far.")

            let timerID = self.currentIdleReadTimeoutTimerID
            self.idleReadTimeoutTimer = self.eventLoop.scheduleTask(in: timeAmount) {
                guard self.currentIdleReadTimeoutTimerID == timerID else { return }
                let action = self.state.idleReadTimeoutTriggered()
                self.run(action, context: context)
            }

        case .resetIdleReadTimeoutTimer(let timeAmount):
            if let oldTimer = self.idleReadTimeoutTimer {
                oldTimer.cancel()
            }

            self.currentIdleReadTimeoutTimerID &+= 1
            let timerID = self.currentIdleReadTimeoutTimerID
            self.idleReadTimeoutTimer = self.eventLoop.scheduleTask(in: timeAmount) {
                guard self.currentIdleReadTimeoutTimerID == timerID else { return }
                let action = self.state.idleReadTimeoutTriggered()
                self.run(action, context: context)
            }
        case .clearIdleReadTimeoutTimer:
            if let oldTimer = self.idleReadTimeoutTimer {
                self.idleReadTimeoutTimer = nil
                self.currentIdleReadTimeoutTimerID &+= 1
                oldTimer.cancel()
            }
        case .none:
            break
        }
    }

    // MARK: Private HTTPRequestExecutor

    private func writeRequestBodyPart0(_ data: IOData, request: HTTPExecutableRequest, promise: EventLoopPromise<Void>?) {
        guard self.request === request, let context = self.channelContext else {
            // Because the HTTPExecutableRequest may run in a different thread to our eventLoop,
            // calls from the HTTPExecutableRequest to our ChannelHandler may arrive here after
            // the request has been popped by the state machine or the ChannelHandler has been
            // removed from the Channel pipeline. This is a normal threading issue, noone has
            // screwed up.
            promise?.fail(HTTPClientError.requestStreamCancelled)
            return
        }

        let action = self.state.requestStreamPartReceived(data, promise: promise)
        self.run(action, context: context)
    }

    private func finishRequestBodyStream0(_ request: HTTPExecutableRequest, promise: EventLoopPromise<Void>?) {
        guard self.request === request, let context = self.channelContext else {
            // See code comment in `writeRequestBodyPart0`
            promise?.fail(HTTPClientError.requestStreamCancelled)
            return
        }

        let action = self.state.requestStreamFinished(promise: promise)
        self.run(action, context: context)
    }

    private func demandResponseBodyStream0(_ request: HTTPExecutableRequest) {
        guard self.request === request, let context = self.channelContext else {
            // See code comment in `writeRequestBodyPart0`
            return
        }

        self.logger.trace("Downstream requests more response body data")

        let action = self.state.demandMoreResponseBodyParts()
        self.run(action, context: context)
    }

    private func cancelRequest0(_ request: HTTPExecutableRequest) {
        guard self.request === request, let context = self.channelContext else {
            // See code comment in `writeRequestBodyPart0`
            return
        }

        self.logger.trace("Request was cancelled")

        let action = self.state.requestCancelled(closeConnection: true)
        self.run(action, context: context)
    }
}

extension HTTP1ClientChannelHandler: HTTPRequestExecutor {
    func writeRequestBodyPart(_ data: IOData, request: HTTPExecutableRequest, promise: EventLoopPromise<Void>?) {
        if self.eventLoop.inEventLoop {
            self.writeRequestBodyPart0(data, request: request, promise: promise)
        } else {
            self.eventLoop.execute {
                self.writeRequestBodyPart0(data, request: request, promise: promise)
            }
        }
    }

    func finishRequestBodyStream(_ request: HTTPExecutableRequest, promise: EventLoopPromise<Void>?) {
        if self.eventLoop.inEventLoop {
            self.finishRequestBodyStream0(request, promise: promise)
        } else {
            self.eventLoop.execute {
                self.finishRequestBodyStream0(request, promise: promise)
            }
        }
    }

    func demandResponseBodyStream(_ request: HTTPExecutableRequest) {
        if self.eventLoop.inEventLoop {
            self.demandResponseBodyStream0(request)
        } else {
            self.eventLoop.execute {
                self.demandResponseBodyStream0(request)
            }
        }
    }

    func cancelRequest(_ request: HTTPExecutableRequest) {
        if self.eventLoop.inEventLoop {
            self.cancelRequest0(request)
        } else {
            self.eventLoop.execute {
                self.cancelRequest0(request)
            }
        }
    }
}

struct IdleReadStateMachine {
    enum Action {
        case startIdleReadTimeoutTimer(TimeAmount)
        case resetIdleReadTimeoutTimer(TimeAmount)
        case clearIdleReadTimeoutTimer
        case none
    }

    enum State {
        case waitingForRequestEnd
        case waitingForMoreResponseData
        case responseEndReceived
    }

    private var state: State = .waitingForRequestEnd
    private let timeAmount: TimeAmount

    init(timeAmount: TimeAmount) {
        self.timeAmount = timeAmount
    }

    mutating func requestEndSent() -> Action {
        switch self.state {
        case .waitingForRequestEnd:
            self.state = .waitingForMoreResponseData
            return .startIdleReadTimeoutTimer(self.timeAmount)

        case .waitingForMoreResponseData:
            preconditionFailure("Invalid state. Waiting for response data must start after request head was sent")

        case .responseEndReceived:
            // the response end was received, before we send the request head. Idle timeout timer
            // must never be started.
            return .none
        }
    }

    mutating func channelRead(_ part: HTTPClientResponsePart) -> Action {
        switch self.state {
        case .waitingForRequestEnd:
            switch part {
            case .head, .body:
                return .none
            case .end:
                self.state = .responseEndReceived
                return .none
            }

        case .waitingForMoreResponseData:
            switch part {
            case .head, .body:
                return .resetIdleReadTimeoutTimer(self.timeAmount)
            case .end:
                self.state = .responseEndReceived
                return .none
            }

        case .responseEndReceived:
            preconditionFailure("How can we receive more data, if we already received the response end?")
        }
    }
}
