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
    typealias OutboundIn = HTTPRequestTask
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

    private var task: HTTPRequestTask?
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

        let action: HTTP1ConnectionStateMachine.Action
        switch httpPart {
        case .head(let head):
            action = self.state.receivedHTTPResponseHead(head)
        case .body(let buffer):
            action = self.state.receivedHTTPResponseBodyPart(buffer)
        case .end:
            action = self.state.receivedHTTPResponseEnd()
        }

        self.run(action, context: context)
    }

    func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        context.close(mode: mode, promise: promise)
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        self.logger.trace("Write")

        let task = self.unwrapOutboundIn(data)
        self.task = task

        let action = self.state.runNewRequest(idleReadTimeout: task.idleReadTimeout)
        self.run(action, context: context)
    }

    func read(context: ChannelHandlerContext) {
        self.logger.trace("Read")

        let action = self.state.readEventCaught()
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
            let action = self.state.cancelRequestForClose()
            self.run(action, context: context)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    // MARK: - Run Actions

    func run(_ action: HTTP1ConnectionStateMachine.Action, context: ChannelHandlerContext) {
        switch action {
        case .verifyRequest:
            do {
                guard self.task!.willExecuteRequest(self) else {
                    throw HTTPClientError.cancelled
                }

                let head = try self.verifyRequest(request: self.task!.request)
                let action = self.state.requestVerified(head)
                self.run(action, context: context)
            } catch {
                let action = self.state.requestVerificationFailed(error)
                self.run(action, context: context)
            }

        case .sendRequestHead(let head, startBody: let startBody, let idleReadTimeout):
            if startBody {
                context.write(wrapOutboundOut(.head(head)), promise: nil)
                context.flush()

                self.task!.requestHeadSent(head)
                self.task!.startRequestBodyStream()
            } else {
                context.write(wrapOutboundOut(.head(head)), promise: nil)
                context.write(wrapOutboundOut(.end(nil)), promise: nil)
                context.flush()

                self.task!.requestHeadSent(head)
            }

            if let idleReadTimeout = idleReadTimeout {
                self.resetIdleReadTimeoutTimer(idleReadTimeout, context: context)
            }

        case .sendBodyPart(let part):
            context.writeAndFlush(wrapOutboundOut(.body(part)), promise: nil)

        case .sendRequestEnd:
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)

        case .pauseRequestBodyStream:
            self.task!.pauseRequestBodyStream()

        case .resumeRequestBodyStream:
            self.task!.resumeRequestBodyStream()

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

        case .forwardResponseHead(let head):
            self.task!.receiveResponseHead(head)

        case .forwardResponseBodyPart(let buffer, let resetReadTimeout):
            self.task!.receiveResponseBodyPart(buffer)

            if let resetReadTimeout = resetReadTimeout {
                self.resetIdleReadTimeoutTimer(resetReadTimeout, context: context)
            }

        case .forwardResponseEnd(let readPending, let clearReadTimeoutTimer, let closeConnection):
            // The order here is very important...
            // We first nil our own task property! `taskCompleted` will potentially lead to
            // situations in which we get a new request right away. We should finish the task
            // after the connection was notified, that we finished. A
            // `HTTPClient.shutdown(requiresCleanShutdown: true)` will fail if we do it the
            // other way around.

            let task = self.task!
            self.task = nil

            if clearReadTimeoutTimer {
                self.clearIdleReadTimeoutTimer()
            }

            if closeConnection {
                context.close(promise: nil)
                task.receiveResponseEnd()
            } else {
                if readPending {
                    context.read()
                }

                self.connection.taskCompleted()
                task.receiveResponseEnd()
            }

        case .forwardError(let error, closeConnection: let close, fireChannelError: let fire):
            let task = self.task!
            self.task = nil
            if close {
                context.close(promise: nil)
            } else {
                self.connection.taskCompleted()
            }

            if fire {
                context.fireErrorCaught(error)
            }

            task.fail(error)
        }
    }

    // MARK: - Private Methods -

    private func verifyRequest(request: HTTPClient.Request) throws -> HTTPRequestHead {
        var headers = request.headers

        if !headers.contains(name: "host") {
            let port = request.port
            var host = request.host
            if !(port == 80 && request.scheme == "http"), !(port == 443 && request.scheme == "https") {
                host += ":\(port)"
            }
            headers.add(name: "host", value: host)
        }

        try headers.validate(method: request.method, body: request.body)

        let head = HTTPRequestHead(
            version: .http1_1,
            method: request.method,
            uri: request.uri,
            headers: headers
        )

        // 3. preparing to send body

        // This assert can go away when (if ever!) the above `if` correctly handles other HTTP versions. For example
        // in HTTP/1.0, we need to treat the absence of a 'connection: keep-alive' as a close too.
        assert(head.version == HTTPVersion(major: 1, minor: 1),
               "Sending a request in HTTP version \(head.version) which is unsupported by the above `if`")

        return head
    }

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
}

extension HTTP1ClientChannelHandler: HTTP1RequestExecutor {
    func writeRequestBodyPart(_ data: IOData, task: HTTPRequestTask) {
        guard self.channelContext.eventLoop.inEventLoop else {
            return self.channelContext.eventLoop.execute {
                self.writeRequestBodyPart(data, task: task)
            }
        }

        guard self.task === task else {
            // very likely we got threading issues here...
            return
        }

        let action = self.state.requestStreamPartReceived(data)
        self.run(action, context: self.channelContext)
    }

    func finishRequestBodyStream(task: HTTPRequestTask) {
        // ensure the message is received on correct eventLoop
        guard self.channelContext.eventLoop.inEventLoop else {
            return self.channelContext.eventLoop.execute {
                self.finishRequestBodyStream(task: task)
            }
        }

        guard self.task === task else {
            // very likely we got threading issues here...
            return
        }

        let action = self.state.requestStreamFinished()
        self.run(action, context: self.channelContext)
    }

    func demandResponseBodyStream(task: HTTPRequestTask) {
        // ensure the message is received on correct eventLoop
        guard self.channelContext.eventLoop.inEventLoop else {
            return self.channelContext.eventLoop.execute {
                self.demandResponseBodyStream(task: task)
            }
        }

        guard self.task === task else {
            // very likely we got threading issues here...
            return
        }

        self.logger.trace("Downstream requests more response body data")

        let action = self.state.forwardMoreBodyParts()
        self.run(action, context: self.channelContext)
    }

    func cancelRequest(task: HTTPRequestTask) {
        // ensure the message is received on correct eventLoop
        guard self.channelContext.eventLoop.inEventLoop else {
            return self.channelContext.eventLoop.execute {
                self.cancelRequest(task: task)
            }
        }

        guard self.task === task else {
            // very likely we got threading issues here...
            return
        }

        let action = self.state.requestCancelled()
        self.run(action, context: self.channelContext)
    }
}
