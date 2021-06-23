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

import NIO
import NIOTLS

final class TLSEventsHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = NIOAny

    private var tlsEstablishedPromise: EventLoopPromise<String?>?
    var tlsEstablishedFuture: EventLoopFuture<String?>! {
        return self.tlsEstablishedPromise?.futureResult
    }

    init() {}

    func handlerAdded(context: ChannelHandlerContext) {
        self.tlsEstablishedPromise = context.eventLoop.makePromise(of: String?.self)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let tlsEvent = event as? TLSUserEvent {
            switch tlsEvent {
            case .handshakeCompleted(negotiatedProtocol: let negotiated):
                self.tlsEstablishedPromise!.succeed(negotiated)
            case .shutdownCompleted:
                break
            }
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        self.tlsEstablishedPromise!.fail(error)
        context.fireErrorCaught(error)
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        struct NoResult: Error {}
        self.tlsEstablishedPromise!.fail(NoResult())
    }
}
