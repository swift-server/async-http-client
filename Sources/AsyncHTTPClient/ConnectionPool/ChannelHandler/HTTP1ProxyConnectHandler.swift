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
        case initialized(EventLoopPromise<Void>)
        // transitions to `.headReceived` or `.failed`
        case connectSent(EventLoopPromise<Void>)
        // transitions to `.completed` or `.failed`
        case headReceived(EventLoopPromise<Void>)
        // final error state
        case failed(Error)
        // final success state
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
        if context.channel.isActive {
            self.sendConnect(context: context)
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        switch self.state {
        case .failed, .completed:
            break
        case .initialized, .connectSent, .headReceived:
            preconditionFailure("Removing the handler, while connecting seems wrong")
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        self.sendConnect(context: context)
    }

    func channelInactive(context: ChannelHandlerContext) {
        switch self.state {
        case .initialized(let promise), .connectSent(let promise), .headReceived(let promise):
            let error = HTTPClientError.remoteConnectionClosed
            self.state = .failed(error)
            promise.fail(error)
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
                preconditionFailure("Invalid state: \(self.state)")
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
                preconditionFailure("Invalid state: \(self.state)")
            }
        }
    }

    func sendConnect(context: ChannelHandlerContext) {
        guard case .initialized(let promise) = self.state else {
            // we might run into this handler twice, once in handlerAdded and once in channelActive.
            return
        }

        self.state = .connectSent(promise)

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