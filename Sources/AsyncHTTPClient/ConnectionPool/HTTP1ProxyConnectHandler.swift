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
        case initialized(EventLoopPromise<Void>)
        case connectSent(EventLoopPromise<Void>)
        case headReceived(EventLoopPromise<Void>)
        case failed(Error)
        case completed
    }

    private var state: State

    let targetHost: String
    let targetPort: Int
    let proxyAuthorization: HTTPClient.Authorization?

    init(targetHost: String,
         targetPort: Int,
         proxyAuthorization: HTTPClient.Authorization?,
         connectPromise: EventLoopPromise<Void>) {
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.proxyAuthorization = proxyAuthorization

        self.state = .initialized(connectPromise)
    }

    func handlerAdded(context: ChannelHandlerContext) {
        precondition(context.channel.isActive, "Expected to be added to an active channel")

        self.sendConnect(context: context)
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        switch self.state {
        case .failed, .completed:
            break
        case .initialized, .connectSent, .headReceived:
            preconditionFailure("Removing the handler, while connecting seems wrong")
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
                context.close(promise: nil)
                promise.fail(error)
            default:
                // Any response other than a successful response
                // indicates that the tunnel has not yet been formed and that the
                // connection remains governed by HTTP.
                let error = HTTPClientError.invalidProxyResponse
                self.state = .failed(error)
                context.close(promise: nil)
                promise.fail(error)
            }
        case .body:
            switch self.state {
            case .headReceived(let promise):
                // we don't expect a body
                let error = HTTPClientError.invalidProxyResponse
                self.state = .failed(error)
                context.close(promise: nil)
                promise.fail(error)
            case .failed:
                // ran into an error before... ignore this one
                break
            case .completed, .connectSent, .initialized:
                preconditionFailure("Invalid state")
            }

        case .end:
            switch self.state {
            case .headReceived(let promise):
                self.state = .completed
                promise.succeed(())
            case .failed:
                // ran into an error before... ignore this one
                break
            case .initialized, .connectSent, .completed:
                preconditionFailure("Invalid state")
            }
        }
    }

    func sendConnect(context: ChannelHandlerContext) {
        guard case .initialized(let promise) = self.state else {
            preconditionFailure("Invalid state")
        }

        self.state = .connectSent(promise)

        var head = HTTPRequestHead(
            version: .init(major: 1, minor: 1),
            method: .CONNECT,
            uri: "\(self.targetHost):\(self.targetPort)"
        )
        head.headers.add(name: "proxy-connection", value: "keep-alive")
        if let authorization = self.proxyAuthorization {
            head.headers.add(name: "proxy-authorization", value: authorization.headerValue)
        }
        context.write(self.wrapOutboundOut(.head(head)), promise: nil)
        context.write(self.wrapOutboundOut(.end(nil)), promise: nil)
        context.flush()
    }
}
