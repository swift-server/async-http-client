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

    private var state: HTTPRequestStateMachine = .init(isChannelWritable: false, ignoreUncleanSSLShutdown: false) {
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
                self.clearIdleReadTimeoutTimer()
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
        // NOTE: We can bang the request in the following actions, since the `HTTPRequestStateMachine`
        //       ensures, that actions that require a request are only called, if the request is
        //       still present. The request is only nilled as a response to a state machine action
        //       (.failRequest or .succeedRequest).

        switch action {
        case .sendRequestHead(let head, let startBody):
            if startBody {
                context.writeAndFlush(self.wrapOutboundOut(.head(head)), promise: nil)
                self.request!.requestHeadSent()
                self.request!.resumeRequestBodyStream()
            } else {
                context.write(self.wrapOutboundOut(.head(head)), promise: nil)
                context.write(self.wrapOutboundOut(.end(nil)), promise: nil)
                context.flush()

                self.request!.requestHeadSent()

                if let timeoutAction = self.idleReadTimeoutStateMachine?.requestEndSent() {
                    self.runTimeoutAction(timeoutAction, context: context)
                }
            }

        case .pauseRequestBodyStream:
            self.request!.pauseRequestBodyStream()

        case .sendBodyPart(let data):
            context.writeAndFlush(self.wrapOutboundOut(.body(data)), promise: nil)

        case .sendRequestEnd:
            context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)

            if let timeoutAction = self.idleReadTimeoutStateMachine?.requestEndSent() {
                self.runTimeoutAction(timeoutAction, context: context)
            }

        case .read:
            context.read()

        case .wait:
            break

        case .resumeRequestBodyStream:
            self.request!.resumeRequestBodyStream()

        case .forwardResponseHead(let head, pauseRequestBodyStream: let pauseRequestBodyStream):
            self.request!.receiveResponseHead(head)
            if pauseRequestBodyStream {
                self.request!.pauseRequestBodyStream()
            }

        case .forwardResponseBodyParts(let parts):
            self.request!.receiveResponseBodyParts(parts)

        case .failRequest(let error, let finalAction):
            self.request!.fail(error)
            self.request = nil
            self.runFinalAction(finalAction, context: context)

        case .succeedRequest(let finalAction, let finalParts):
            self.request!.succeedRequest(finalParts)
            self.request = nil
            self.runFinalAction(finalAction, context: context)
        }
    }

    private func runFinalAction(_ action: HTTPRequestStateMachine.Action.FinalStreamAction, context: ChannelHandlerContext) {
        switch action {
        case .close:
            context.close(promise: nil)

        case .sendRequestEnd:
            context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)

        case .none:
            break
        }
    }

    private func runTimeoutAction(_ action: IdleReadStateMachine.Action, context: ChannelHandlerContext) {
        switch action {
        case .startIdleReadTimeoutTimer(let timeAmount):
            assert(self.idleReadTimeoutTimer == nil, "Expected there is no timeout timer so far.")

            self.idleReadTimeoutTimer = self.eventLoop.scheduleTask(in: timeAmount) {
                let action = self.state.idleReadTimeoutTriggered()
                self.run(action, context: context)
            }

        case .resetIdleReadTimeoutTimer(let timeAmount):
            if let oldTimer = self.idleReadTimeoutTimer {
                oldTimer.cancel()
            }

            self.idleReadTimeoutTimer = self.eventLoop.scheduleTask(in: timeAmount) {
                let action = self.state.idleReadTimeoutTriggered()
                self.run(action, context: context)
            }

        case .none:
            break
        }
    }

    private func clearIdleReadTimeoutTimer() {
        if let oldTimer = self.idleReadTimeoutTimer {
            self.idleReadTimeoutTimer = nil
            oldTimer.cancel()
        }
    }

    // MARK: Private HTTPRequestExecutor

    private func writeRequestBodyPart0(_ data: IOData, request: HTTPExecutableRequest) {
        guard self.request === request, let context = self.channelContext else {
            // Because the HTTPExecutingRequest may run in a different thread to our eventLoop,
            // calls from the HTTPExecutingRequest to our ChannelHandler may arrive here after
            // the request has been popped by the state machine or the ChannelHandler has been
            // removed from the Channel pipeline. This is a normal threading issue, noone has
            // screwed up.
            return
        }

        let action = self.state.requestStreamPartReceived(data)
        self.run(action, context: context)
    }

    private func finishRequestBodyStream0(_ request: HTTPExecutableRequest) {
        guard self.request === request, let context = self.channelContext else {
            // See code comment in `writeRequestBodyPart0`
            return
        }

        let action = self.state.requestStreamFinished()
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
    func writeRequestBodyPart(_ data: IOData, request: HTTPExecutableRequest) {
        if self.eventLoop.inEventLoop {
            self.writeRequestBodyPart0(data, request: request)
        } else {
            self.eventLoop.execute {
                self.writeRequestBodyPart0(data, request: request)
            }
        }
    }

    func finishRequestBodyStream(_ request: HTTPExecutableRequest) {
        if self.eventLoop.inEventLoop {
            self.finishRequestBodyStream0(request)
        } else {
            self.eventLoop.execute {
                self.finishRequestBodyStream0(request)
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
