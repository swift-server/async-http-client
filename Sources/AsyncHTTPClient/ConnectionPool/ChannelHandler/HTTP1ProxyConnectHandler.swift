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

    private let targetHost: String
    private let targetPort: Int
    private let proxyAuthorization: HTTPClient.Authorization?
    private let deadline: NIODeadline

    private var proxyEstablishedPromise: EventLoopPromise<Void>?
    var proxyEstablishedFuture: EventLoopFuture<Void>? {
        self.proxyEstablishedPromise?.futureResult
    }

    convenience init(
        target: ConnectionTarget,
        proxyAuthorization: HTTPClient.Authorization?,
        deadline: NIODeadline
    ) {
        let targetHost: String
        let targetPort: Int
        switch target {
        case .ipAddress(let serialization, let address):
            targetHost = serialization
            targetPort = address.port!
        case .domain(name: let domain, let port):
            targetHost = domain
            targetPort = port
        case .unixSocket:
            fatalError("Unix Domain Sockets do not support proxies")
        }
        self.init(
            targetHost: targetHost,
            targetPort: targetPort,
            proxyAuthorization: proxyAuthorization,
            deadline: deadline
        )
    }

    init(
        targetHost: String,
        targetPort: Int,
        proxyAuthorization: HTTPClient.Authorization?,
        deadline: NIODeadline
    ) {
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.proxyAuthorization = proxyAuthorization
        self.deadline = deadline
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.proxyEstablishedPromise = context.eventLoop.makePromise(of: Void.self)

        self.sendConnect(context: context)
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
            self.failWithError(HTTPClientError.remoteConnectionClosed, context: context, closeConnection: false)

        case .failed, .completed:
            break
        }
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        preconditionFailure("We don't support outgoing traffic during HTTP Proxy update.")
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch self.unwrapInboundIn(data) {
        case .head(let head):
            self.handleHTTPHeadReceived(head, context: context)
        case .body:
            self.handleHTTPBodyReceived(context: context)
        case .end:
            self.handleHTTPEndReceived(context: context)
        }
    }

    private func sendConnect(context: ChannelHandlerContext) {
        guard case .initialized = self.state else {
            // we might run into this handler twice, once in handlerAdded and once in channelActive.
            return
        }

        let timeout = context.eventLoop.assumeIsolated().scheduleTask(deadline: self.deadline) {
            switch self.state {
            case .initialized:
                preconditionFailure("How can we have a scheduled timeout, if the connection is not even up?")

            case .connectSent, .headReceived:
                self.failWithError(HTTPClientError.httpProxyHandshakeTimeout, context: context)

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
        head.headers.replaceOrAdd(name: "host", value: "\(self.targetHost)")
        if let authorization = self.proxyAuthorization {
            head.headers.replaceOrAdd(name: "proxy-authorization", value: authorization.headerValue)
        }
        context.write(self.wrapOutboundOut(.head(head)), promise: nil)
        context.write(self.wrapOutboundOut(.end(nil)), promise: nil)
        context.flush()
    }

    private func handleHTTPHeadReceived(_ head: HTTPResponseHead, context: ChannelHandlerContext) {
        guard case .connectSent(let scheduled) = self.state else {
            preconditionFailure("HTTPDecoder should throw an error, if we have not send a request")
        }

        switch head.status.code {
        case 200..<300:
            // Any 2xx (Successful) response indicates that the sender (and all
            // inbound proxies) will switch to tunnel mode immediately after the
            // blank line that concludes the successful response's header section
            self.state = .headReceived(scheduled)
        case 407:
            self.failWithError(HTTPClientError.proxyAuthenticationRequired, context: context)

        default:
            // Any response other than a successful response indicates that the tunnel
            // has not yet been formed and that the connection remains governed by HTTP.
            self.failWithError(HTTPClientError.invalidProxyResponse, context: context)
        }
    }

    private func handleHTTPBodyReceived(context: ChannelHandlerContext) {
        switch self.state {
        case .headReceived(let timeout):
            timeout.cancel()
            // we don't expect a body
            self.failWithError(HTTPClientError.invalidProxyResponse, context: context)
        case .failed:
            // ran into an error before... ignore this one
            break
        case .completed, .connectSent, .initialized:
            preconditionFailure("Invalid state: \(self.state)")
        }
    }

    private func handleHTTPEndReceived(context: ChannelHandlerContext) {
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

    private func failWithError(_ error: Error, context: ChannelHandlerContext, closeConnection: Bool = true) {
        self.state = .failed(error)
        self.proxyEstablishedPromise?.fail(error)
        context.fireErrorCaught(error)
        if closeConnection {
            context.close(mode: .all, promise: nil)
        }
    }
}
