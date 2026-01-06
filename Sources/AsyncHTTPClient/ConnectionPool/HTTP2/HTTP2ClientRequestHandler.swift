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
import NIOHTTP2

final class HTTP2ClientRequestHandler: ChannelDuplexHandler {
    typealias OutboundIn = HTTPExecutableRequest
    typealias OutboundOut = HTTPClientRequestPart
    typealias InboundIn = HTTPClientResponsePart

    private let eventLoop: EventLoop

    private var state: HTTPRequestStateMachine = .init(isChannelWritable: false) {
        willSet {
            self.eventLoop.assertInEventLoop()
        }
    }

    /// while we are in a channel pipeline, this context can be used.
    private var channelContext: ChannelHandlerContext?

    private var request: HTTPExecutableRequest? {
        didSet {
            if let newRequest = self.request {
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
                self.idleReadTimeoutStateMachine = nil
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

    init(eventLoop: EventLoop) {
        self.eventLoop = eventLoop
    }

    func handlerAdded(context: ChannelHandlerContext) {
        assert(
            context.eventLoop === self.eventLoop,
            "The handler must be added to a channel that runs on the eventLoop it was initialized with."
        )
        self.channelContext = context

        let isWritable = context.channel.isActive && context.channel.isWritable
        let action = self.state.writabilityChanged(writable: isWritable)
        self.run(action, context: context)
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.channelContext = nil
    }

    // MARK: Channel Inbound Handler

    func channelActive(context: ChannelHandlerContext) {
        let action = self.state.writabilityChanged(writable: context.channel.isWritable)
        self.run(action, context: context)
    }

    func channelInactive(context: ChannelHandlerContext) {
        let action = self.state.channelInactive()
        self.run(action, context: context)
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if let timeoutAction = self.idleWriteTimeoutStateMachine?.channelWritabilityChanged(context: context) {
            self.runTimeoutAction(timeoutAction, context: context)
        }

        let action = self.state.writabilityChanged(writable: context.channel.isWritable)
        self.run(action, context: context)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let httpPart = self.unwrapInboundIn(data)

        if let timeoutAction = self.idleReadTimeoutStateMachine?.channelRead(httpPart) {
            self.runTimeoutAction(timeoutAction, context: context)
        }

        let action = self.state.channelRead(httpPart)
        self.run(action, context: context)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        let action = self.state.channelReadComplete()
        self.run(action, context: context)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        let action = self.state.errorHappened(error)
        self.run(action, context: context)
    }

    // MARK: Channel Outbound Handler

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let request = self.unwrapOutboundIn(data)
        // The `HTTPRequestStateMachine` ensures that a `HTTP2ClientRequestHandler` only handles
        // a single request.
        self.request = request

        if let timeoutAction = self.idleWriteTimeoutStateMachine?.write() {
            self.runTimeoutAction(timeoutAction, context: context)
        }

        request.willExecuteRequest(self.requestExecutor)

        let action = self.state.startRequest(
            head: request.requestHead,
            metadata: request.requestFramingMetadata
        )
        self.run(action, context: context)
    }

    func read(context: ChannelHandlerContext) {
        let action = self.state.read()
        self.run(action, context: context)
    }

    func triggerUserOutboundEvent(context: ChannelHandlerContext, event: Any, promise: EventLoopPromise<Void>?) {
        switch event {
        case HTTPConnectionEvent.shutdownRequested:
            let action = self.state.requestCancelled()
            self.run(action, context: context)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    // MARK: - Private Methods -

    // MARK: Run Actions

    private func run(_ action: HTTPRequestStateMachine.Action, context: ChannelHandlerContext) {
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
        case .pauseRequestBodyStream:
            // We can force unwrap the request here, as we have just validated in the state machine,
            // that the request is neither failed nor finished yet
            self.request!.pauseRequestBodyStream()

        case .sendBodyPart(let data, let writePromise):
            context.writeAndFlush(self.wrapOutboundOut(.body(data)), promise: writePromise)

        case .sendRequestEnd(let writePromise):
            context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: writePromise)

            if let readTimeoutAction = self.idleReadTimeoutStateMachine?.requestEndSent() {
                self.runTimeoutAction(readTimeoutAction, context: context)
            }

            if let writeTimeoutAction = self.idleWriteTimeoutStateMachine?.requestEndSent() {
                self.runTimeoutAction(writeTimeoutAction, context: context)
            }

        case .read:
            context.read()

        case .wait:
            break

        case .resumeRequestBodyStream:
            // We can force unwrap the request here, as we have just validated in the state machine,
            // that the request is neither failed nor finished yet
            self.request!.resumeRequestBodyStream()

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

        case .forwardResponseBodyParts(let parts):
            // We can force unwrap the request here, as we have just validated in the state machine,
            // that the request is neither failed nor finished yet
            self.request!.receiveResponseBodyParts(parts)

        case .failRequest(let error, let finalAction):
            // We can force unwrap the request here, as we have just validated in the state machine,
            // that the request object is still present.
            self.request!.fail(error)
            self.request = nil
            self.runTimeoutAction(.clearIdleReadTimeoutTimer, context: context)
            self.runTimeoutAction(.clearIdleWriteTimeoutTimer, context: context)
            // No matter the error reason, we must always make sure the h2 stream is closed. Only
            // once the h2 stream is closed, it is released from the h2 multiplexer. The
            // HTTPRequestStateMachine may signal finalAction: .none in the error case (as this is
            // the right result for HTTP/1). In the h2 case we MUST always close.
            self.runFailedFinalAction(finalAction, context: context, error: error)

        case .succeedRequest(let finalAction, let finalParts):
            // We can force unwrap the request here, as we have just validated in the state machine,
            // that the request object is still present.
            self.request!.receiveResponseEnd(finalParts, trailers: nil)
            self.request = nil
            self.runTimeoutAction(.clearIdleReadTimeoutTimer, context: context)
            self.runTimeoutAction(.clearIdleWriteTimeoutTimer, context: context)
            self.runSuccessfulFinalAction(finalAction, context: context)

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

    private func runSuccessfulFinalAction(
        _ action: HTTPRequestStateMachine.Action.FinalSuccessfulRequestAction,
        context: ChannelHandlerContext
    ) {
        switch action {
        case .close, .none:
            // The actions returned here come from an `HTTPRequestStateMachine` that assumes http/1.1
            // semantics. For this reason we can ignore the close here, since an h2 stream is closed
            // after every request anyway.
            break

        case .sendRequestEnd(let writePromise):
            context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: writePromise)
        }
    }

    private func runFailedFinalAction(
        _ action: HTTPRequestStateMachine.Action.FinalFailedRequestAction,
        context: ChannelHandlerContext,
        error: Error
    ) {
        // We must close the http2 stream after the request has finished. Since the request failed,
        // we have no idea what the h2 streams state was. To be on the save side, we explicitly close
        // the h2 stream. This will break a reference cycle in HTTP2Connection.
        context.close(promise: nil)

        switch action {
        case .close(let writePromise):
            writePromise?.fail(error)

        case .none:
            break
        }
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

    private func writeRequestBodyPart0(_ data: IOData, request: HTTPExecutableRequest, promise: EventLoopPromise<Void>?)
    {
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

    private func finishRequestBodyStream0(_ request: HTTPExecutableRequest, promise: EventLoopPromise<Void>?) {
        guard self.request === request, let context = self.channelContext else {
            // See code comment in `writeRequestBodyPart0`
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

        let action = self.state.demandMoreResponseBodyParts()
        self.run(action, context: context)
    }

    private func cancelRequest0(_ request: HTTPExecutableRequest) {
        guard self.request === request, let context = self.channelContext else {
            // See code comment in `writeRequestBodyPart0`
            return
        }

        if let timeoutAction = self.idleWriteTimeoutStateMachine?.cancelRequest() {
            self.runTimeoutAction(timeoutAction, context: context)
        }

        let action = self.state.requestCancelled()
        self.run(action, context: context)
    }
}

@available(*, unavailable)
extension HTTP2ClientRequestHandler: Sendable {}

extension HTTP2ClientRequestHandler {
    var requestExecutor: RequestExecutor {
        RequestExecutor(self)
    }

    struct RequestExecutor: HTTPRequestExecutor, Sendable {
        private let loopBound: NIOLoopBound<HTTP2ClientRequestHandler>

        init(_ handler: HTTP2ClientRequestHandler) {
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
