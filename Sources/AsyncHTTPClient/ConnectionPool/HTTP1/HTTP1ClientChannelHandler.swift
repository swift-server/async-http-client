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
                requestLogger[metadataKey: "ahc-connection-id"] = self.connectionIdLoggerMetadata
                requestLogger[metadataKey: "ahc-el"] = self.eventLoopDescription
                self.logger = requestLogger

                if let idleReadTimeout = newRequest.requestOptions.idleReadTimeout {
                    self.idleReadTimeoutStateMachine = .init(timeAmount: idleReadTimeout)
                }

                if let idleWriteTimeout = newRequest.requestOptions.idleWriteTimeout {
                    self.idleWriteTimeoutStateMachine = .init(
                        timeAmount: idleWriteTimeout,
                        isWritabilityEnabled: self.channelContext?.channel.isWritable ?? false
                    )
                }
            } else {
                self.logger = self.backgroundLogger
                self.idleReadTimeoutStateMachine = nil
                self.idleWriteTimeoutStateMachine = nil
            }
        }
    }

    private var idleReadTimeoutStateMachine: IdleReadStateMachine?
    private var idleReadTimeoutTimer: Scheduled<Void>?

    private var idleWriteTimeoutStateMachine: IdleWriteStateMachine?
    private var idleWriteTimeoutTimer: Scheduled<Void>?

    /// Cancelling a task in NIO does *not* guarantee that the task will not execute under certain race conditions.
    /// We therefore give each timer an ID and increase the ID every time we reset or cancel it.
    /// We check in the task if the timer ID has changed in the meantime and do not execute any action if has changed.
    private var currentIdleReadTimeoutTimerID: Int = 0
    private var currentIdleWriteTimeoutTimerID: Int = 0

    private let backgroundLogger: Logger
    private var logger: Logger
    private let eventLoop: EventLoop
    private let eventLoopDescription: Logger.MetadataValue
    private let connectionIdLoggerMetadata: Logger.MetadataValue

    var onConnectionIdle: () -> Void = {}
    init(eventLoop: EventLoop, backgroundLogger: Logger, connectionIdLoggerMetadata: Logger.MetadataValue) {
        self.eventLoop = eventLoop
        self.eventLoopDescription = "\(eventLoop.description)"
        self.backgroundLogger = backgroundLogger
        self.logger = backgroundLogger
        self.connectionIdLoggerMetadata = connectionIdLoggerMetadata
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
        self.logger.trace(
            "Channel active",
            metadata: [
                "ahc-channel-writable": "\(context.channel.isWritable)"
            ]
        )

        let action = self.state.channelActive(isWritable: context.channel.isWritable)
        self.run(action, context: context)
    }

    func channelInactive(context: ChannelHandlerContext) {
        self.logger.trace("Channel inactive")

        let action = self.state.channelInactive()
        self.run(action, context: context)
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        self.logger.trace(
            "Channel writability changed",
            metadata: [
                "ahc-channel-writable": "\(context.channel.isWritable)"
            ]
        )

        if let timeoutAction = self.idleWriteTimeoutStateMachine?.channelWritabilityChanged(context: context) {
            self.runTimeoutAction(timeoutAction, context: context)
        }

        let action = self.state.writabilityChanged(writable: context.channel.isWritable)
        self.run(action, context: context)
        context.fireChannelWritabilityChanged()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let httpPart = self.unwrapInboundIn(data)

        self.logger.trace(
            "HTTP response part received",
            metadata: [
                "ahc-http-part": "\(httpPart)"
            ]
        )

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
        self.logger.trace(
            "Channel error caught",
            metadata: [
                "ahc-error": "\(error)"
            ]
        )

        let action = self.state.errorHappened(error)
        self.run(action, context: context)
    }

    // MARK: Channel Outbound Handler

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        assert(self.request == nil, "Only write to the ChannelHandler if you are sure, it is idle!")
        let req = self.unwrapOutboundIn(data)
        self.request = req

        self.logger.debug("Request was scheduled on connection")

        if let timeoutAction = self.idleWriteTimeoutStateMachine?.write() {
            self.runTimeoutAction(timeoutAction, context: context)
        }

        req.willExecuteRequest(self.requestExecutor)

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
        case .sendRequestHead(let head, let sendEnd):
            self.sendRequestHead(head, sendEnd: sendEnd, context: context)
        case .notifyRequestHeadSendSuccessfully(let resumeRequestBodyStream, let startIdleTimer):
            // We can force unwrap the request here, as we have just validated in the state machine,
            // that the request is neither failed nor finished yet
            self.request!.requestHeadSent()
            if resumeRequestBodyStream, let request = self.request {
                // The above request head send notification might lead the request to mark itself as
                // cancelled, which in turn might pop the request of the handler. For this reason we
                // must check if the request is still present here.
                request.resumeRequestBodyStream()
            }
            if startIdleTimer {
                if let readTimeoutAction = self.idleReadTimeoutStateMachine?.requestEndSent() {
                    self.runTimeoutAction(readTimeoutAction, context: context)
                }

                if let writeTimeoutAction = self.idleWriteTimeoutStateMachine?.requestEndSent() {
                    self.runTimeoutAction(writeTimeoutAction, context: context)
                }
            }
        case .sendBodyPart(let part, let writePromise):
            context.writeAndFlush(self.wrapOutboundOut(.body(part)), promise: writePromise)

        case .sendRequestEnd(let writePromise):
            context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: writePromise)

            if let readTimeoutAction = self.idleReadTimeoutStateMachine?.requestEndSent() {
                self.runTimeoutAction(readTimeoutAction, context: context)
            }

            if let writeTimeoutAction = self.idleWriteTimeoutStateMachine?.requestEndSent() {
                self.runTimeoutAction(writeTimeoutAction, context: context)
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
            self.runTimeoutAction(.clearIdleWriteTimeoutTimer, context: context)

            switch finalAction {
            case .close:
                context.close(promise: nil)
                oldRequest.receiveResponseEnd(buffer, trailers: nil)
            case .sendRequestEnd(let writePromise, let shouldClose):
                let writePromise = writePromise ?? context.eventLoop.makePromise(of: Void.self)
                // We need to defer succeeding the old request to avoid ordering issues
                writePromise.futureResult.hop(to: context.eventLoop).assumeIsolated().whenComplete { result in
                    switch result {
                    case .success:
                        // If our final action was `sendRequestEnd`, that means we've already received
                        // the complete response. As a result, once we've uploaded all the body parts
                        // we need to tell the pool that the connection is idle or, if we were asked to
                        // close when we're done, send the close. Either way, we then succeed the request
                        if shouldClose {
                            context.close(promise: nil)
                        } else {
                            self.onConnectionIdle()
                        }

                        oldRequest.receiveResponseEnd(buffer, trailers: nil)
                    case .failure(let error):
                        context.close(promise: nil)
                        oldRequest.fail(error)
                    }
                }

                context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: writePromise)
            case .informConnectionIsIdle:
                self.onConnectionIdle()
                oldRequest.receiveResponseEnd(buffer, trailers: nil)
            }

        case .failRequest(let error, let finalAction):
            // see comment in the `succeedRequest` case.
            let oldRequest = self.request!
            self.request = nil
            self.runTimeoutAction(.clearIdleReadTimeoutTimer, context: context)
            self.runTimeoutAction(.clearIdleWriteTimeoutTimer, context: context)

            switch finalAction {
            case .close(let writePromise):
                context.close(promise: nil)
                writePromise?.fail(error)
                oldRequest.fail(error)

            case .informConnectionIsIdle:
                self.onConnectionIdle()
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

    private func sendRequestHead(_ head: HTTPRequestHead, sendEnd: Bool, context: ChannelHandlerContext) {
        if sendEnd {
            context.write(self.wrapOutboundOut(.head(head)), promise: nil)
            context.write(self.wrapOutboundOut(.end(nil)), promise: nil)
            context.flush()
        } else {
            context.writeAndFlush(self.wrapOutboundOut(.head(head)), promise: nil)
        }
        self.run(self.state.headSent(), context: context)
    }

    private func runTimeoutAction(_ action: IdleReadStateMachine.Action, context: ChannelHandlerContext) {
        switch action {
        case .startIdleReadTimeoutTimer(let timeAmount):
            assert(self.idleReadTimeoutTimer == nil, "Expected there is no timeout timer so far.")

            let timerID = self.currentIdleReadTimeoutTimerID
            self.idleReadTimeoutTimer = self.eventLoop.assumeIsolated().scheduleTask(in: timeAmount) {
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
            self.idleReadTimeoutTimer = self.eventLoop.assumeIsolated().scheduleTask(in: timeAmount) {
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

    private func runTimeoutAction(_ action: IdleWriteStateMachine.Action, context: ChannelHandlerContext) {
        switch action {
        case .startIdleWriteTimeoutTimer(let timeAmount):
            assert(self.idleWriteTimeoutTimer == nil, "Expected there is no timeout timer so far.")

            let timerID = self.currentIdleWriteTimeoutTimerID
            self.idleWriteTimeoutTimer = self.eventLoop.assumeIsolated().scheduleTask(in: timeAmount) {
                guard self.currentIdleWriteTimeoutTimerID == timerID else { return }
                let action = self.state.idleWriteTimeoutTriggered()
                self.run(action, context: context)
            }
        case .resetIdleWriteTimeoutTimer(let timeAmount):
            if let oldTimer = self.idleWriteTimeoutTimer {
                oldTimer.cancel()
            }

            self.currentIdleWriteTimeoutTimerID &+= 1
            let timerID = self.currentIdleWriteTimeoutTimerID
            self.idleWriteTimeoutTimer = self.eventLoop.assumeIsolated().scheduleTask(in: timeAmount) {
                guard self.currentIdleWriteTimeoutTimerID == timerID else { return }
                let action = self.state.idleWriteTimeoutTriggered()
                self.run(action, context: context)
            }
        case .clearIdleWriteTimeoutTimer:
            if let oldTimer = self.idleWriteTimeoutTimer {
                self.idleWriteTimeoutTimer = nil
                self.currentIdleWriteTimeoutTimerID &+= 1
                oldTimer.cancel()
            }
        case .none:
            break
        }
    }

    // MARK: Private HTTPRequestExecutor

    fileprivate func writeRequestBodyPart0(
        _ data: IOData,
        request: HTTPExecutableRequest,
        promise: EventLoopPromise<Void>?
    ) {
        guard self.request === request, let context = self.channelContext else {
            // Because the HTTPExecutableRequest may run in a different thread to our eventLoop,
            // calls from the HTTPExecutableRequest to our ChannelHandler may arrive here after
            // the request has been popped by the state machine or the ChannelHandler has been
            // removed from the Channel pipeline. This is a normal threading issue, noone has
            // screwed up.
            promise?.fail(HTTPClientError.requestStreamCancelled)
            return
        }

        if let timeoutAction = self.idleWriteTimeoutStateMachine?.write() {
            self.runTimeoutAction(timeoutAction, context: context)
        }

        let action = self.state.requestStreamPartReceived(data, promise: promise)
        self.run(action, context: context)
    }

    fileprivate func finishRequestBodyStream0(_ request: HTTPExecutableRequest, promise: EventLoopPromise<Void>?) {
        guard self.request === request, let context = self.channelContext else {
            // See code comment in `writeRequestBodyPart0`
            promise?.fail(HTTPClientError.requestStreamCancelled)
            return
        }

        let action = self.state.requestStreamFinished(promise: promise)
        self.run(action, context: context)
    }

    fileprivate func demandResponseBodyStream0(_ request: HTTPExecutableRequest) {
        guard self.request === request, let context = self.channelContext else {
            // See code comment in `writeRequestBodyPart0`
            return
        }

        self.logger.trace("Downstream requests more response body data")

        let action = self.state.demandMoreResponseBodyParts()
        self.run(action, context: context)
    }

    fileprivate func cancelRequest0(_ request: HTTPExecutableRequest) {
        guard self.request === request, let context = self.channelContext else {
            // See code comment in `writeRequestBodyPart0`
            return
        }

        self.logger.trace("Request was cancelled")

        if let timeoutAction = self.idleWriteTimeoutStateMachine?.cancelRequest() {
            self.runTimeoutAction(timeoutAction, context: context)
        }

        let action = self.state.requestCancelled(closeConnection: true)
        self.run(action, context: context)
    }
}

@available(*, unavailable)
extension HTTP1ClientChannelHandler: Sendable {}

extension HTTP1ClientChannelHandler {
    var requestExecutor: RequestExecutor {
        RequestExecutor(self)
    }

    struct RequestExecutor: HTTPRequestExecutor, Sendable {
        private let loopBound: NIOLoopBound<HTTP1ClientChannelHandler>

        init(_ handler: HTTP1ClientChannelHandler) {
            self.loopBound = NIOLoopBound(handler, eventLoop: handler.eventLoop)
        }

        func writeRequestBodyPart(_ data: IOData, request: HTTPExecutableRequest, promise: EventLoopPromise<Void>?) {
            self.loopBound.execute {
                $0.writeRequestBodyPart0(data, request: request, promise: promise)
            }
        }

        func finishRequestBodyStream(_ request: HTTPExecutableRequest, promise: EventLoopPromise<Void>?) {
            self.loopBound.execute {
                $0.finishRequestBodyStream0(request, promise: promise)
            }
        }

        func demandResponseBodyStream(_ request: HTTPExecutableRequest) {
            self.loopBound.execute {
                $0.demandResponseBodyStream0(request)
            }
        }

        func cancelRequest(_ request: HTTPExecutableRequest) {
            self.loopBound.execute {
                $0.cancelRequest0(request)
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

struct IdleWriteStateMachine {
    enum Action {
        case startIdleWriteTimeoutTimer(TimeAmount)
        case resetIdleWriteTimeoutTimer(TimeAmount)
        case clearIdleWriteTimeoutTimer
        case none
    }

    enum State {
        case waitingForRequestEnd
        case waitingForWritabilityEnabled
        case requestEndSent
    }

    private var state: State
    private let timeAmount: TimeAmount

    init(timeAmount: TimeAmount, isWritabilityEnabled: Bool) {
        self.timeAmount = timeAmount
        if isWritabilityEnabled {
            self.state = .waitingForRequestEnd
        } else {
            self.state = .waitingForWritabilityEnabled
        }
    }

    mutating func cancelRequest() -> Action {
        switch self.state {
        case .waitingForRequestEnd, .waitingForWritabilityEnabled:
            self.state = .requestEndSent
            return .clearIdleWriteTimeoutTimer
        case .requestEndSent:
            return .none
        }
    }

    mutating func write() -> Action {
        switch self.state {
        case .waitingForRequestEnd:
            return .resetIdleWriteTimeoutTimer(self.timeAmount)
        case .waitingForWritabilityEnabled:
            return .none
        case .requestEndSent:
            preconditionFailure("If the request end has been sent, we can't write more data.")
        }
    }

    mutating func requestEndSent() -> Action {
        switch self.state {
        case .waitingForRequestEnd:
            self.state = .requestEndSent
            return .clearIdleWriteTimeoutTimer
        case .waitingForWritabilityEnabled:
            self.state = .requestEndSent
            return .none
        case .requestEndSent:
            return .none
        }
    }

    mutating func channelWritabilityChanged(context: ChannelHandlerContext) -> Action {
        if context.channel.isWritable {
            switch self.state {
            case .waitingForRequestEnd:
                preconditionFailure("If waiting for more data, the channel was already writable.")
            case .waitingForWritabilityEnabled:
                self.state = .waitingForRequestEnd
                return .startIdleWriteTimeoutTimer(self.timeAmount)
            case .requestEndSent:
                return .none
            }
        } else {
            switch self.state {
            case .waitingForRequestEnd:
                self.state = .waitingForWritabilityEnabled
                return .clearIdleWriteTimeoutTimer
            case .waitingForWritabilityEnabled:
                preconditionFailure(
                    "If the channel was writable before, then we should have been waiting for more data."
                )
            case .requestEndSent:
                return .none
            }
        }
    }
}
