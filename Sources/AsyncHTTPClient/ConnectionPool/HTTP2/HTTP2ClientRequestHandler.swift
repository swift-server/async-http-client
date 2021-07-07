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
import NIOHTTP2

class HTTP2ClientRequestHandler: ChannelDuplexHandler {
    typealias OutboundIn = HTTPExecutingRequest
    typealias OutboundOut = HTTPClientRequestPart
    typealias InboundIn = HTTPClientResponsePart

    private let eventLoop: EventLoop

    private(set) var channelContext: ChannelHandlerContext?
    private(set) var state: HTTPRequestStateMachine = .init(isChannelWritable: false)
    private(set) var request: HTTPExecutingRequest?

    init(eventLoop: EventLoop) {
        self.eventLoop = eventLoop
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.channelContext = context

        let isWritable = context.channel.isActive && context.channel.isWritable
        let action = self.state.writabilityChanged(writable: isWritable)
        self.run(action, context: context)
    }

    func handlerRemoved() {
        self.channelContext = nil
    }

    func channelActive(context: ChannelHandlerContext) {
        let action = self.state.writabilityChanged(writable: context.channel.isWritable)
        self.run(action, context: context)
    }

    func channelInactive(context: ChannelHandlerContext) {
        let action = self.state.channelInactive()
        self.run(action, context: context)
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.channelContext = nil
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        let action = self.state.writabilityChanged(writable: context.channel.isWritable)
        self.run(action, context: context)
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let request = self.unwrapOutboundIn(data)
        self.request = request

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

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let action = self.state.channelRead(self.unwrapInboundIn(data))
        self.run(action, context: context)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        let action = self.state.errorHappened(error)
        self.run(action, context: context)
    }

    // MARK: - Run Actions

    func run(_ action: HTTPRequestStateMachine.Action, context: ChannelHandlerContext) {
        switch action {
        case .sendRequestHead(let head, let startBody):
            if startBody {
                context.writeAndFlush(self.wrapOutboundOut(.head(head)), promise: nil)
                self.request!.resumeRequestBodyStream()
            } else {
                context.writeAndFlush(self.wrapOutboundOut(.head(head)), promise: nil)
                context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            }

        case .pauseRequestBodyStream:
            self.request!.pauseRequestBodyStream()

        case .sendBodyPart(let data):
            context.writeAndFlush(self.wrapOutboundOut(.body(data)), promise: nil)

        case .sendRequestEnd:
            context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)

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

    // MARK: - Private Methods -

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

    private func writeRequestBodyPart0(_ data: IOData, request: HTTPExecutingRequest) {
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

    private func finishRequestBodyStream0(_ request: HTTPExecutingRequest) {
        guard self.request === request, let context = self.channelContext else {
            // See code comment in `writeRequestBodyPart0`
            return
        }

        let action = self.state.requestStreamFinished()
        self.run(action, context: context)
    }

    private func demandResponseBodyStream0(_ request: HTTPExecutingRequest) {
        guard self.request === request, let context = self.channelContext else {
            // See code comment in `writeRequestBodyPart0`
            return
        }

        let action = self.state.demandMoreResponseBodyParts()
        self.run(action, context: context)
    }

    private func cancelRequest0(_ request: HTTPExecutingRequest) {
        guard self.request === request, let context = self.channelContext else {
            // See code comment in `writeRequestBodyPart0`
            return
        }

        let action = self.state.requestCancelled()
        self.run(action, context: context)
    }
}

extension HTTP2ClientRequestHandler: HTTPRequestExecutor {
    func writeRequestBodyPart(_ data: IOData, request: HTTPExecutingRequest) {
        if self.eventLoop.inEventLoop {
            self.writeRequestBodyPart0(data, request: request)
        } else {
            self.eventLoop.execute {
                self.writeRequestBodyPart0(data, request: request)
            }
        }
    }

    func finishRequestBodyStream(_ request: HTTPExecutingRequest) {
        if self.eventLoop.inEventLoop {
            self.finishRequestBodyStream0(request)
        } else {
            self.eventLoop.execute {
                self.finishRequestBodyStream0(request)
            }
        }
    }

    func demandResponseBodyStream(_ request: HTTPExecutingRequest) {
        if self.eventLoop.inEventLoop {
            self.demandResponseBodyStream0(request)
        } else {
            self.eventLoop.execute {
                self.demandResponseBodyStream0(request)
            }
        }
    }

    func cancelRequest(_ request: HTTPExecutingRequest) {
        if self.eventLoop.inEventLoop {
            self.cancelRequest0(request)
        } else {
            self.eventLoop.execute {
                self.cancelRequest0(request)
            }
        }
    }
}
