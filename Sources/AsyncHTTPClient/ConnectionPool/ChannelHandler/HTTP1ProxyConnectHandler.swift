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
import NIOHTTP1

final class HTTP1ProxyConnectHandler: ChannelDuplexHandler, RemovableChannelHandler {
    typealias OutboundIn = Never
    typealias OutboundOut = HTTPClientRequestPart
    typealias InboundIn = HTTPClientResponsePart

    enum State {
        // transitions to `.connectSent` or `.failed`
        case initialized
        // transitions to `.headReceived` or `.failed`
        case connectSent(Scheduled<Void>)
        // transitions to `.completed` or `.failed`
        case headReceived(Scheduled<Void>)
        // final error state
        case failed(Error)
        // final success state
        case completed
    }

    private var state: State = .initialized

    let targetHost: String
    let targetPort: Int
    let proxyAuthorization: HTTPClient.Authorization?
    let deadline: NIODeadline

    private var proxyEstablishedPromise: EventLoopPromise<Void>?
    var proxyEstablishedFuture: EventLoopFuture<Void>? {
        return self.proxyEstablishedPromise?.futureResult
    }

    init(targetHost: String,
         targetPort: Int,
         proxyAuthorization: HTTPClient.Authorization?,
         deadline: NIODeadline) {
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.proxyAuthorization = proxyAuthorization
        self.deadline = deadline
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.proxyEstablishedPromise = context.eventLoop.makePromise(of: Void.self)

        if context.channel.isActive {
            self.sendConnect(context: context)
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        switch self.state {
        case .failed, .completed:
            break
        case .initialized, .connectSent, .headReceived:
            struct NoResult: Error {}
            self.state = .failed(NoResult())
            self.proxyEstablishedPromise?.fail(NoResult())
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        self.sendConnect(context: context)
    }

    func channelInactive(context: ChannelHandlerContext) {
        switch self.state {
        case .initialized:
            preconditionFailure("How can we receive a channelInactive before a channelActive?")
        case .connectSent(let timeout), .headReceived(let timeout):
            timeout.cancel()
            let error = HTTPClientError.remoteConnectionClosed
            self.state = .failed(error)
            self.proxyEstablishedPromise?.fail(error)
            context.fireErrorCaught(error)
        case .failed:
            break
        case .completed:
            break
        }
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        preconditionFailure("We don't support outgoing traffic during HTTP Proxy update.")
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch self.unwrapInboundIn(data) {
        case .head(let head):
            guard case .connectSent(let promise) = self.state else {
                preconditionFailure("HTTPDecoder should throw an error, if we have not send a request")
            }

            switch head.status.code {
            case 200..<300:
                // Any 2xx (Successful) response indicates that the sender (and all
                // inbound proxies) will switch to tunnel mode immediately after the
                // blank line that concludes the successful response's header section
                self.state = .headReceived(promise)
            case 407:
                let error = HTTPClientError.proxyAuthenticationRequired
                self.state = .failed(error)
                self.proxyEstablishedPromise?.fail(error)
                context.fireErrorCaught(error)
                context.close(mode: .all, promise: nil)

            default:
                // Any response other than a successful response
                // indicates that the tunnel has not yet been formed and that the
                // connection remains governed by HTTP.
                let error = HTTPClientError.invalidProxyResponse
                self.state = .failed(error)
                self.proxyEstablishedPromise?.fail(error)
                context.fireErrorCaught(error)
                context.close(mode: .all, promise: nil)
            }
        case .body:
            switch self.state {
            case .headReceived(let timeout):
                timeout.cancel()
                // we don't expect a body
                let error = HTTPClientError.invalidProxyResponse
                self.state = .failed(error)
                self.proxyEstablishedPromise?.fail(error)
                context.fireErrorCaught(error)
                context.close(mode: .all, promise: nil)

            case .failed:
                // ran into an error before... ignore this one
                break
            case .completed, .connectSent, .initialized:
                preconditionFailure("Invalid state: \(self.state)")
            }

        case .end:
            switch self.state {
            case .headReceived(let timeout):
                timeout.cancel()
                self.state = .completed
                self.proxyEstablishedPromise?.succeed(())

            case .failed:
                // ran into an error before... ignore this one
                break
            case .initialized, .connectSent, .completed:
                preconditionFailure("Invalid state: \(self.state)")
            }
        }
    }

    func sendConnect(context: ChannelHandlerContext) {
        guard case .initialized = self.state else {
            // we might run into this handler twice, once in handlerAdded and once in channelActive.
            return
        }

        let timeout = context.eventLoop.scheduleTask(deadline: self.deadline) {
            switch self.state {
            case .initialized:
                preconditionFailure("How can we have a scheduled timeout, if the connection is not even up?")

            case .connectSent(let scheduled), .headReceived(let scheduled):
                scheduled.cancel()
                let error = HTTPClientError.httpProxyHandshakeTimeout
                self.state = .failed(error)
                self.proxyEstablishedPromise?.fail(error)
                context.fireErrorCaught(error)
                context.close(mode: .all, promise: nil)

            case .failed, .completed:
                break
            }
        }

        self.state = .connectSent(timeout)

        var head = HTTPRequestHead(
            version: .init(major: 1, minor: 1),
            method: .CONNECT,
            uri: "\(self.targetHost):\(self.targetPort)"
        )
        if let authorization = self.proxyAuthorization {
            head.headers.replaceOrAdd(name: "proxy-authorization", value: authorization.headerValue)
        }
        context.write(self.wrapOutboundOut(.head(head)), promise: nil)
        context.write(self.wrapOutboundOut(.end(nil)), promise: nil)
        context.flush()
    }
}
