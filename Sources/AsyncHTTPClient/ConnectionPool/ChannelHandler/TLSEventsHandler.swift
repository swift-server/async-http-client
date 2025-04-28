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

import NIOCore
import NIOTLS

final class TLSEventsHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = NIOAny

    enum State {
        // transitions to channelActive or failed
        case initialized
        // transitions to tlsEstablished or failed
        case channelActive(Scheduled<Void>?)
        // final success state
        case tlsEstablished
        // final success state
        case failed(Error)
    }

    private var tlsEstablishedPromise: EventLoopPromise<String?>?
    var tlsEstablishedFuture: EventLoopFuture<String?>? {
        self.tlsEstablishedPromise?.futureResult
    }

    private let deadline: NIODeadline?
    private var state: State = .initialized

    init(deadline: NIODeadline?) {
        self.deadline = deadline
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.tlsEstablishedPromise = context.eventLoop.makePromise(of: String?.self)

        if context.channel.isActive {
            self.connectionStarted(context: context)
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        struct NoResult: Error {}
        self.tlsEstablishedPromise!.fail(NoResult())
    }

    func channelActive(context: ChannelHandlerContext) {
        self.connectionStarted(context: context)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        guard let tlsEvent = event as? TLSUserEvent else {
            return context.fireUserInboundEventTriggered(event)
        }

        switch tlsEvent {
        case .handshakeCompleted(negotiatedProtocol: let negotiated):
            switch self.state {
            case .initialized:
                preconditionFailure("How can we establish a TLS connection, if we are not connected?")
            case .channelActive(let scheduled):
                self.state = .tlsEstablished
                scheduled?.cancel()
                self.tlsEstablishedPromise?.succeed(negotiated)
                context.fireUserInboundEventTriggered(event)
            case .tlsEstablished, .failed:
                // potentially a race with the timeout...
                break
            }
        case .shutdownCompleted:
            break
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        switch self.state {
        case .initialized:
            self.state = .failed(error)
            self.tlsEstablishedPromise?.fail(error)
        case .channelActive(let scheduled):
            scheduled?.cancel()
            self.state = .failed(error)
            self.tlsEstablishedPromise?.fail(error)
        case .tlsEstablished, .failed:
            break
        }
        context.fireErrorCaught(error)
    }

    private func connectionStarted(context: ChannelHandlerContext) {
        guard case .initialized = self.state else {
            return
        }

        var scheduled: Scheduled<Void>?
        if let deadline = deadline {
            scheduled = context.eventLoop.assumeIsolated().scheduleTask(deadline: deadline) {
                switch self.state {
                case .initialized, .channelActive:
                    // close the connection, if the handshake timed out
                    context.close(mode: .all, promise: nil)
                    let error = HTTPClientError.tlsHandshakeTimeout
                    self.state = .failed(error)
                    self.tlsEstablishedPromise?.fail(error)
                case .failed, .tlsEstablished:
                    break
                }
            }
        }

        self.state = .channelActive(scheduled)
    }
}
