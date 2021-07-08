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
    typealias OutboundIn = HTTPExecutingRequest
    typealias OutboundOut = HTTPClientRequestPart
    typealias InboundIn = HTTPClientResponsePart

    var channelContext: ChannelHandlerContext!

    var state: HTTP1ConnectionStateMachine = .init() {
        didSet {
            self.channelContext.eventLoop.assertInEventLoop()

            self.logger.trace("Connection state did change", metadata: [
                "state": "\(String(describing: self.state))",
            ])
        }
    }

    /// the currently executing request
    private var request: HTTPExecutingRequest?
    private var idleReadTimeoutTimer: Scheduled<Void>?

    let connection: HTTP1Connection
    let logger: Logger

    init(connection: HTTP1Connection, logger: Logger) {
        self.connection = connection
        self.logger = logger
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.channelContext = context

        if context.channel.isActive {
            let action = self.state.channelActive(isWritable: context.channel.isWritable)
            self.run(action, context: context)
        }
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

    func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        context.close(mode: mode, promise: promise)
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        self.logger.trace("New request to execute")

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

    func run(_ action: HTTP1ConnectionStateMachine.Action, context: ChannelHandlerContext) {
        switch action {
        case .sendRequestHead(let head, startBody: let startBody):
            if startBody {
                context.write(wrapOutboundOut(.head(head)), promise: nil)
                context.flush()

                self.request!.requestHeadSent()
                self.request!.resumeRequestBodyStream()
            } else {
                context.write(wrapOutboundOut(.head(head)), promise: nil)
                context.write(wrapOutboundOut(.end(nil)), promise: nil)
                context.flush()

                self.request!.requestHeadSent()
            }

        case .sendBodyPart(let part):
            context.writeAndFlush(wrapOutboundOut(.body(part)), promise: nil)

        case .sendRequestEnd:
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)

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

    private func writeRequestBodyPart0(_ data: IOData, request: HTTPExecutingRequest) {
        guard self.request === request else {
            // very likely we got threading issues here...
            return
        }

        let action = self.state.requestStreamPartReceived(data)
        self.run(action, context: self.channelContext)
    }

    private func finishRequestBodyStream0(_ request: HTTPExecutingRequest) {
        guard self.request === request else {
            // very likely we got threading issues here...
            return
        }

        let action = self.state.requestStreamFinished()
        self.run(action, context: self.channelContext)
    }

    private func demandResponseBodyStream0(_ request: HTTPExecutingRequest) {
        guard self.request === request else {
            // very likely we got threading issues here...
            return
        }

        self.logger.trace("Downstream requests more response body data")

        let action = self.state.demandMoreResponseBodyParts()
        self.run(action, context: self.channelContext)
    }

    func cancelRequest0(_ request: HTTPExecutingRequest) {
        guard self.request === request else {
            // very likely we got threading issues here...
            return
        }

        let action = self.state.requestCancelled(closeConnection: true)
        self.run(action, context: self.channelContext)
    }
}

extension HTTP1ClientChannelHandler: HTTPRequestExecutor {
    func writeRequestBodyPart(_ data: IOData, request: HTTPExecutingRequest) {
        if self.channelContext.eventLoop.inEventLoop {
            self.writeRequestBodyPart0(data, request: request)
        } else {
            self.channelContext.eventLoop.execute {
                self.writeRequestBodyPart0(data, request: request)
            }
        }
    }

    func finishRequestBodyStream(_ request: HTTPExecutingRequest) {
        if self.channelContext.eventLoop.inEventLoop {
            self.finishRequestBodyStream0(request)
        } else {
            self.channelContext.eventLoop.execute {
                self.finishRequestBodyStream0(request)
            }
        }
    }

    func demandResponseBodyStream(_ request: HTTPExecutingRequest) {
        if self.channelContext.eventLoop.inEventLoop {
            self.demandResponseBodyStream0(request)
        } else {
            self.channelContext.eventLoop.execute {
                self.demandResponseBodyStream0(request)
            }
        }
    }

    func cancelRequest(_ request: HTTPExecutingRequest) {
        if self.channelContext.eventLoop.inEventLoop {
            self.cancelRequest0(request)
        } else {
            self.channelContext.eventLoop.execute {
                self.cancelRequest0(request)
            }
        }
    }
}
