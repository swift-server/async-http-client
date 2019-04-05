import Foundation
import NIO
import NIOHTTP1

/// Specifies the remote address of an HTTP proxy.
///
/// Adding an `HTTPClientProxy` to your client's `HTTPClientConfiguration`
/// will cause requests to be passed through the specified proxy using the
/// HTTP `CONNECT` method.
///
/// If a `TLSConfiguration` is used in conjunction with `HTTPClientProxy`,
/// TLS will be established _after_ successful proxy, between your client
/// and the destination server.
public struct HTTPClientProxy {
    internal let host: String
    internal let port: Int

    public static func server(host: String, port: Int) -> HTTPClientProxy {
        return .init(host: host, port: port)
    }
}

internal final class HTTPClientProxyHandler: ChannelDuplexHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundIn = HTTPClientRequestPart
    typealias OutboundOut = HTTPClientRequestPart

    enum BufferItem {
        case write(NIOAny, EventLoopPromise<Void>?)
        case flush
    }

    private let host: String
    private let port: Int
    private var onConnect: (Channel) -> EventLoopFuture<Void>
    private var buffer: [BufferItem]

    init(host: String, port: Int, onConnect: @escaping (Channel) -> EventLoopFuture<Void>) {
        self.host = host
        self.port = port
        self.onConnect = onConnect
        self.buffer = []
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let res = self.unwrapInboundIn(data)
        switch res {
        case .head(let head):
            switch head.status.code {
            case 200..<300:
                // Any 2xx (Successful) response indicates that the sender (and all
                // inbound proxies) will switch to tunnel mode immediately after the
                // blank line that concludes the successful response's header section
                break
            default:
                // Any response other than a successful response
                // indicates that the tunnel has not yet been formed and that the
                // connection remains governed by HTTP.
                context.fireErrorCaught(HTTPClientErrors.InvalidProxyResponseError())
            }
        case .end:
            _ = self.handleConnect(context: context)
        case .body:
            break
        }
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        self.buffer.append(.write(data, promise))
    }

    func flush(context: ChannelHandlerContext) {
        self.buffer.append(.flush)
    }

    func channelActive(context: ChannelHandlerContext) {
        self.sendConnect(context: context)
        context.fireChannelActive()
    }

    // MARK: Private

    private func handleConnect(context: ChannelHandlerContext) -> EventLoopFuture<Void> {
        return self.onConnect(context.channel).flatMap {
            while self.buffer.count > 0 {
                // make a copy of the current buffer and clear it in case any
                // calls to context.write cause more requests to be buffered
                let buffer = self.buffer
                self.buffer = []
                buffer.forEach { item in
                    switch item {
                    case .flush:
                        context.flush()
                    case .write(let data, let promise):
                        context.write(data, promise: promise)
                    }
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
        context.write(self.wrapOutboundOut(.head(head)), promise: nil)
        context.write(self.wrapOutboundOut(.end(nil)), promise: nil)
        context.flush()
    }
}
