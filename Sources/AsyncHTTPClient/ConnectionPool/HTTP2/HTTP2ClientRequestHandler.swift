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
            if let newRequest = self.request, let idleReadTimeout = newRequest.requestOptions.idleReadTimeout {
                self.idleReadTimeoutStateMachine = .init(timeAmount: idleReadTimeout)
            } else {
                self.idleReadTimeoutStateMachine = nil
            }
        }
    }

    private var idleReadTimeoutStateMachine: IdleReadStateMachine?
    private var idleReadTimeoutTimer: Scheduled<Void>?

    init(eventLoop: EventLoop) {
        self.eventLoop = eventLoop
    }

    func handlerAdded(context: ChannelHandlerContext) {
        assert(context.eventLoop === self.eventLoop,
               "The handler must be added to a channel that runs on the eventLoop it was initialized with.")
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

        request.willExecuteRequest(self)

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
        case .sendRequestHead(let head, let startBody):
            self.sendRequestHead(head, startBody: startBody, context: context)

        case .pauseRequestBodyStream:
            // We can force unwrap the request here, as we have just validated in the state machine,
            // that the request is neither failed nor finished yet
            self.request!.pauseRequestBodyStream()

        case .sendBodyPart(let data, let writePromise):
            context.writeAndFlush(self.wrapOutboundOut(.body(data)), promise: writePromise)

        case .sendRequestEnd(let writePromise):
            context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: writePromise)

            if let timeoutAction = self.idleReadTimeoutStateMachine?.requestEndSent() {
                self.runTimeoutAction(timeoutAction, context: context)
            }

        case .read:
            context.read()

        case .wait:
            break

        case .resumeRequestBodyStream:
            // We can force unwrap the request here, as we have just validated in the state machine,
            // that the request is neither failed nor finished yet
            self.request!.resumeRequestBodyStream()

        case .forwardResponseHead(let head, pauseRequestBodyStream: let pauseRequestBodyStream):
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
            // No matter the error reason, we must always make sure the h2 stream is closed. Only
            // once the h2 stream is closed, it is released from the h2 multiplexer. The
            // HTTPRequestStateMachine may signal finalAction: .none in the error case (as this is
            // the right result for HTTP/1). In the h2 case we MUST always close.
            self.runFailedFinalAction(finalAction, context: context, error: error)

        case .succeedRequest(let finalAction, let finalParts):
            // We can force unwrap the request here, as we have just validated in the state machine,
            // that the request object is still present.
            self.request!.succeedRequest(finalParts)
            self.request = nil
            self.runTimeoutAction(.clearIdleReadTimeoutTimer, context: context)
            self.runSuccessfulFinalAction(finalAction, context: context)

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

    private func runSuccessfulFinalAction(_ action: HTTPRequestStateMachine.Action.FinalSuccessfulRequestAction, context: ChannelHandlerContext) {
        switch action {
        case .close:
            context.close(promise: nil)

        case .sendRequestEnd(let writePromise):
            context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: writePromise)

        case .none:
            break
        }
    }

    private func runFailedFinalAction(_ action: HTTPRequestStateMachine.Action.FinalFailedRequestAction, context: ChannelHandlerContext, error: Error) {
        switch action {
        case .close(let writePromise):
            context.close(promise: nil)
            writePromise?.fail(error)

        case .none:
            break
        }
    }

    private func runTimeoutAction(_ action: IdleReadStateMachine.Action, context: ChannelHandlerContext) {
        switch action {
        case .startIdleReadTimeoutTimer(let timeAmount):
            assert(self.idleReadTimeoutTimer == nil, "Expected there is no timeout timer so far.")

            self.idleReadTimeoutTimer = self.eventLoop.scheduleTask(in: timeAmount) {
                guard self.idleReadTimeoutTimer != nil else { return }
                let action = self.state.idleReadTimeoutTriggered()
                self.run(action, context: context)
            }

        case .resetIdleReadTimeoutTimer(let timeAmount):
            if let oldTimer = self.idleReadTimeoutTimer {
                oldTimer.cancel()
            }

            self.idleReadTimeoutTimer = self.eventLoop.scheduleTask(in: timeAmount) {
                guard self.idleReadTimeoutTimer != nil else { return }
                let action = self.state.idleReadTimeoutTriggered()
                self.run(action, context: context)
            }
        case .clearIdleReadTimeoutTimer:
            if let oldTimer = self.idleReadTimeoutTimer {
                self.idleReadTimeoutTimer = nil
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

        let action = self.state.requestCancelled()
        self.run(action, context: context)
    }
}

extension HTTP2ClientRequestHandler: HTTPRequestExecutor {
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
