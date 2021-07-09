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
import NIO
import NIOHTTP1

final class HTTP1ClientChannelHandler: ChannelDuplexHandler {
    typealias OutboundIn = HTTPExecutableRequest
    typealias OutboundOut = HTTPClientRequestPart
    typealias InboundIn = HTTPClientResponsePart

    private var state: HTTP1ConnectionStateMachine = .init() {
        didSet {
            self.eventLoop.assertInEventLoop()

            self.logger.trace("Connection state did change", metadata: [
                "state": "\(String(describing: self.state))",
            ])
        }
    }

    /// while we are in a channel pipeline, this context can be used.
    private var channelContext: ChannelHandlerContext?

    /// the currently executing request
    private var request: HTTPExecutableRequest?
    private var idleReadTimeoutTimer: Scheduled<Void>?

    let connection: HTTP1Connection
    let logger: Logger
    let eventLoop: EventLoop

    init(connection: HTTP1Connection, eventLoop: EventLoop, logger: Logger) {
        self.connection = connection
        self.eventLoop = eventLoop
        self.logger = logger
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
        let action = self.state.channelActive(isWritable: context.channel.isWritable)
        self.run(action, context: context)
    }

    func channelInactive(context: ChannelHandlerContext) {
        let action = self.state.channelInactive()
        self.run(action, context: context)
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        self.logger.trace("Channel writability changed", metadata: [
            "writable": "\(context.channel.isWritable)",
        ])

        let action = self.state.writabilityChanged(writable: context.channel.isWritable)
        self.run(action, context: context)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let httpPart = unwrapInboundIn(data)

        self.logger.trace("Message received", metadata: [
            "message": "\(httpPart)",
        ])

        let action = self.state.channelRead(httpPart)
        self.run(action, context: context)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        let action = self.state.channelReadComplete()
        self.run(action, context: context)
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        self.logger.trace("New request to execute")

        assert(self.request == nil, "Only write to the ChannelHandler if you are sure, it is idle!")
        let req = self.unwrapOutboundIn(data)
        self.request = req

        req.willExecuteRequest(self)

        let action = self.state.runNewRequest(head: req.requestHead, metadata: req.requestFramingMetadata)
        self.run(action, context: context)
    }

    func read(context: ChannelHandlerContext) {
        self.logger.trace("Read")

        let action = self.state.read()
        self.run(action, context: context)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        self.logger.trace("Error caught", metadata: [
            "error": "\(error)",
        ])

        let action = self.state.errorHappened(error)
        self.run(action, context: context)
    }

    func triggerUserOutboundEvent(context: ChannelHandlerContext, event: Any, promise: EventLoopPromise<Void>?) {
        switch event {
        case HTTPConnectionEvent.cancelRequest:
            let action = self.state.requestCancelled(closeConnection: true)
            self.run(action, context: context)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    // MARK: - Run Actions

    private func run(_ action: HTTP1ConnectionStateMachine.Action, context: ChannelHandlerContext) {
        switch action {
        case .sendRequestHead(let head, startBody: let startBody):
            if startBody {
                context.write(self.wrapOutboundOut(.head(head)), promise: nil)
                context.flush()

                self.request!.requestHeadSent()
                self.request!.resumeRequestBodyStream()
            } else {
                context.write(self.wrapOutboundOut(.head(head)), promise: nil)
                context.write(self.wrapOutboundOut(.end(nil)), promise: nil)
                context.flush()

                self.request!.requestHeadSent()
            }

        case .sendBodyPart(let part):
            context.writeAndFlush(self.wrapOutboundOut(.body(part)), promise: nil)

        case .sendRequestEnd:
            context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)

        case .pauseRequestBodyStream:
            self.request!.pauseRequestBodyStream()

        case .resumeRequestBodyStream:
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
            self.request!.receiveResponseHead(head)
            if pauseRequestBodyStream {
                self.request!.pauseRequestBodyStream()
            }

        case .forwardResponseBodyParts(let buffer):
            self.request!.receiveResponseBodyParts(buffer)

        case .succeedRequest(let finalAction, let buffer):
            // The order here is very important...
            // We first nil our own task property! `taskCompleted` will potentially lead to
            // situations in which we get a new request right away. We should finish the task
            // after the connection was notified, that we finished. A
            // `HTTPClient.shutdown(requiresCleanShutdown: true)` will fail if we do it the
            // other way around.

            let oldRequest = self.request!
            self.request = nil

            switch finalAction {
            case .close:
                context.close(promise: nil)
            case .sendRequestEnd:
                context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            case .informConnectionIsIdle:
                self.connection.taskCompleted()
            case .none:
                break
            }

            oldRequest.succeedRequest(buffer)

        case .failRequest(let error, let finalAction):
            // see comment in the `succeedRequest` case.
            let oldRequest = self.request!
            self.request = nil

            switch finalAction {
            case .close:
                context.close(promise: nil)
            case .sendRequestEnd:
                context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            case .informConnectionIsIdle:
                self.connection.taskCompleted()
            case .none:
                break
            }

            oldRequest.fail(error)
        }
    }

    // MARK: - Private Methods -

    private func resetIdleReadTimeoutTimer(_ idleReadTimeout: TimeAmount, context: ChannelHandlerContext) {
        if let oldTimer = self.idleReadTimeoutTimer {
            oldTimer.cancel()
        }

        self.idleReadTimeoutTimer = context.channel.eventLoop.scheduleTask(in: idleReadTimeout) {
            let action = self.state.idleReadTimeoutTriggered()
            self.run(action, context: context)
        }
    }

    private func clearIdleReadTimeoutTimer() {
        guard let oldTimer = self.idleReadTimeoutTimer else {
            preconditionFailure("Expected an idleReadTimeoutTimer to exist.")
        }

        self.idleReadTimeoutTimer = nil
        oldTimer.cancel()
    }

    // MARK: Private HTTPRequestExecutor

    private func writeRequestBodyPart0(_ data: IOData, request: HTTPExecutableRequest) {
        guard self.request === request, let context = self.channelContext else {
            // Because the HTTPExecutableRequest may run in a different thread to our eventLoop,
            // calls from the HTTPExecutableRequest to our ChannelHandler may arrive here after
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

        self.logger.trace("Downstream requests more response body data")

        let action = self.state.demandMoreResponseBodyParts()
        self.run(action, context: context)
    }

    private func cancelRequest0(_ request: HTTPExecutableRequest) {
        guard self.request === request, let context = self.channelContext else {
            // See code comment in `writeRequestBodyPart0`
            return
        }

        let action = self.state.requestCancelled(closeConnection: true)
        self.run(action, context: context)
    }
}

extension HTTP1ClientChannelHandler: HTTPRequestExecutor {
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
