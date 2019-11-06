//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the AsyncHTTPClient project authors
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

public extension HTTPClient.Configuration {
    /// Proxy server configuration
    /// Specifies the remote address of an HTTP proxy.
    ///
    /// Adding an `Proxy` to your client's `HTTPClient.Configuration`
    /// will cause requests to be passed through the specified proxy using the
    /// HTTP `CONNECT` method.
    ///
    /// If a `TLSConfiguration` is used in conjunction with `HTTPClient.Configuration.Proxy`,
    /// TLS will be established _after_ successful proxy, between your client
    /// and the destination server.
    struct Proxy {
        /// Specifies Proxy server host.
        public var host: String
        /// Specifies Proxy server port.
        public var port: Int
        /// Specifies Proxy server authorization.
        public var authorization: HTTPClient.Authorization?

        /// Create proxy.
        ///
        /// - parameters:
        ///     - host: proxy server host.
        ///     - port: proxy server port.
        public static func server(host: String, port: Int) -> Proxy {
            return .init(host: host, port: port, authorization: nil)
        }

        /// Create proxy.
        ///
        /// - parameters:
        ///     - host: proxy server host.
        ///     - port: proxy server port.
        ///     - authorization: proxy server authorization.
        public static func server(host: String, port: Int, authorization: HTTPClient.Authorization? = nil) -> Proxy {
            return .init(host: host, port: port, authorization: authorization)
        }
    }
}

internal final class HTTPClientProxyHandler: ChannelDuplexHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundIn = HTTPClientRequestPart
    typealias OutboundOut = HTTPClientRequestPart

    enum WriteItem {
        case write(NIOAny, EventLoopPromise<Void>?)
        case flush
    }

    enum ReadState {
        case awaitingResponse
        case connecting
        case connected
    }

    private let host: String
    private let port: Int
    private let authorization: HTTPClient.Authorization?
    private var onConnect: (Channel) -> EventLoopFuture<Void>
    private var writeBuffer: CircularBuffer<WriteItem>
    private var readBuffer: CircularBuffer<NIOAny>
    private var readState: ReadState

    init(host: String, port: Int, authorization: HTTPClient.Authorization?, onConnect: @escaping (Channel) -> EventLoopFuture<Void>) {
        self.host = host
        self.port = port
        self.authorization = authorization
        self.onConnect = onConnect
        self.writeBuffer = .init()
        self.readBuffer = .init()
        self.readState = .awaitingResponse
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch self.readState {
        case .awaitingResponse:
            let res = self.unwrapInboundIn(data)
            switch res {
            case .head(let head):
                switch head.status.code {
                case 200..<300:
                    // Any 2xx (Successful) response indicates that the sender (and all
                    // inbound proxies) will switch to tunnel mode immediately after the
                    // blank line that concludes the successful response's header section
                    break
                case 407:
                    context.fireErrorCaught(HTTPClientError.proxyAuthenticationRequired)
                default:
                    // Any response other than a successful response
                    // indicates that the tunnel has not yet been formed and that the
                    // connection remains governed by HTTP.
                    context.fireErrorCaught(HTTPClientError.invalidProxyResponse)
                }
            case .end:
                self.readState = .connecting
                _ = self.handleConnect(context: context)
            case .body:
                break
            }
        case .connecting:
            self.readBuffer.append(data)
        case .connected:
            context.fireChannelRead(data)
        }
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        self.writeBuffer.append(.write(data, promise))
    }

    func flush(context: ChannelHandlerContext) {
        self.writeBuffer.append(.flush)
    }

    func channelActive(context: ChannelHandlerContext) {
        self.sendConnect(context: context)
        context.fireChannelActive()
    }

    // MARK: Private

    private func handleConnect(context: ChannelHandlerContext) -> EventLoopFuture<Void> {
        return self.onConnect(context.channel).flatMap {
            self.readState = .connected

            // forward any buffered reads
            while !self.readBuffer.isEmpty {
                context.fireChannelRead(self.readBuffer.removeFirst())
            }

            // calls to context.write may be re-entrant
            while !self.writeBuffer.isEmpty {
                switch self.writeBuffer.removeFirst() {
                case .flush:
                    context.flush()
                case .write(let data, let promise):
                    context.write(data, promise: promise)
                }
            }
            return context.pipeline.removeHandler(self)
        }
    }

    private func sendConnect(context: ChannelHandlerContext) {
        var head = HTTPRequestHead(
            version: .init(major: 1, minor: 1),
            method: .CONNECT,
            uri: "\(self.host):\(self.port)"
        )
        head.headers.add(name: "proxy-connection", value: "keep-alive")
        if let authorization = authorization {
            head.headers.add(name: "proxy-authorization", value: authorization.headerValue)
        }
        context.write(self.wrapOutboundOut(.head(head)), promise: nil)
        context.write(self.wrapOutboundOut(.end(nil)), promise: nil)
        context.flush()
    }
}
