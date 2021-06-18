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
@_implementationOnly import NIOHTTP2

class HTTP2ClientRequestHandler: ChannelDuplexHandler {
    typealias OutboundIn = HTTPRequestTask
    typealias OutboundOut = HTTPClientRequestPart
    typealias InboundIn = HTTPClientResponsePart

    var channelContext: ChannelHandlerContext!

    var state: HTTP1ConnectionStateMachine = .init() {
        didSet {
            self.logger.trace("Connection state did change", metadata: [
                "state": "\(String(describing: self.state))",
            ])
        }
    }

    var task: HTTPRequestTask!

    let logger: Logger

    init(logger: Logger) {
        self.logger = logger
    }

    func channelActive(context: ChannelHandlerContext) {
        let action = self.state.channelActive(isWritable: context.channel.isWritable)
        self.run(action, context: context)
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.channelContext = context

        let action = self.state.channelActive(isWritable: context.channel.isWritable)
        self.run(action, context: context)
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.channelContext = nil
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        self.logger.trace("Channel writability changed", metadata: [
            "writable": "\(context.channel.isWritable)",
        ])

        let action = self.state.writabilityChanged(writable: context.channel.isWritable)
        self.run(action, context: context)
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        self.logger.trace("Write")

        #warning("fixme: We need to have good idle state handling here!")
        self.task = self.unwrapOutboundIn(data)

        let action = self.state.runNewRequest(idleReadTimeout: self.task!.idleReadTimeout)
        self.run(action, context: context)
    }

    func read(context: ChannelHandlerContext) {
        self.logger.trace("Read")

        let action = self.state.readEventCaught()
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

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        self.logger.trace("Error caught", metadata: [
            "error": "\(error)",
        ])
    }

    func produceMoreResponseBodyParts(for task: HTTPRequestTask) {
        // ensure the message is received on correct eventLoop
        guard self.channelContext.eventLoop.inEventLoop else {
            return self.channelContext.eventLoop.execute {
                self.produceMoreResponseBodyParts(for: task)
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

    // MARK: - Run Actions

    func run(_ action: HTTP1ConnectionStateMachine.Action, context: ChannelHandlerContext) {
//        switch action {
//        case .verifyRequest:
//            do {
//                let head = try self.verifyRequest(request: self.task.request)
//                let action = self.state.requestVerified(head)
//                self.run(action, context: context)
//            } catch {
//                preconditionFailure("Create error here")
//                //self.state.failed
//            }
//        case .sendRequestHead(let head, let andEnd):
//            self.sendRequestHead(head, context: context)
//
//        case .produceMoreRequestBodyData:
//            self.produceNextRequestBodyPart(context: context)
//
//        case .sendBodyPart(let part, produceMoreRequestBodyData: let produceMore):
//            self.sendRequestBodyPart(part, context: context)
//
//            if produceMore {
//                self.produceNextRequestBodyPart(context: context)
//            }
//
//        case .sendRequestEnd:
//            self.sendRequestEnd(context: context)
//
//        case .read:
//            context.read()
//
//        case .wait:
//            break
//
//        case .fireChannelActive:
//            break
//
//        case .fireChannelInactive:
//            break
//
//        case .forwardResponseHead(let head):
//            self.task.receiveResponseHead(head, source: self)
//
//        case .forwardResponseBodyPart(let buffer):
//            self.task.receiveResponseBodyPart(buffer)
//
//        case .forwardResponseEndAndCloseConnection:
//            self.task.receiveResponseEnd()
//            self.task = nil
//            context.close(mode: .all, promise: nil)
//
//        case .forwardResponseEndAndFireTaskCompleted(let read):
//            self.task.receiveResponseEnd()
//            self.task = nil
//
//            if read {
//                context.read()
//            }
//
//        case .forwardError(let error, closeConnection: let closeConnection):
//            self.task.fail(error)
//            self.task = nil
//            if closeConnection {
//                context.close(promise: nil)
//            }
//        }
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

        do {
            try headers.validate(method: request.method, body: request.body)
        } catch {
            preconditionFailure("Unimplemented: We should go for an early exit here!")
        }

        let head = HTTPRequestHead(
            version: .http1_1,
            method: request.method,
            uri: request.uri,
            headers: headers
        )

        // 3. preparing to send body

        if head.headers[canonicalForm: "connection"].map({ $0.lowercased() }).contains("close") {
//            self.closing = true
        }
        // This assert can go away when (if ever!) the above `if` correctly handles other HTTP versions. For example
        // in HTTP/1.0, we need to treat the absence of a 'connection: keep-alive' as a close too.
        assert(head.version == HTTPVersion(major: 1, minor: 1),
               "Sending a request in HTTP version \(head.version) which is unsupported by the above `if`")

        return head
    }

    private func sendRequestHead(_ head: HTTPRequestHead, context: ChannelHandlerContext) {
//        context.writeAndFlush(wrapOutboundOut(.head(head)), promise: nil)
//
//        let action = self.state.requestHeadSent()
//        self.run(action, context: context)
    }

    private func sendRequestBodyPart(_ part: IOData, context: ChannelHandlerContext) {
        context.writeAndFlush(self.wrapOutboundOut(.body(part)), promise: nil)
    }

    private func sendRequestEnd(context: ChannelHandlerContext) {
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    private func produceNextRequestBodyPart(context: ChannelHandlerContext) {
//        self.task.nextRequestBodyPart(channelEL: context.eventLoop)
//            .hop(to: context.eventLoop)
//            .whenComplete() { result in
//                let action: HTTP1ConnectionStateMachine.Action
//                switch result {
//                case .success(.some(let part)):
//                    action = self.state.requestStreamPartReceived(part)
//                case .success(.none):
//                    action = self.state.requestStreamFinished()
//                case .failure(let error):
//                     action = self.state.requestStreamFailed(error)
//                }
//                self.run(action, context: context)
//            }
    }
}
