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

import AsyncHTTPClient
import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOHTTP1
import NIOHTTPCompression
import NIOSSL

class TestHTTPDelegate: HTTPClientResponseDelegate {
    typealias Response = Void

    init(backpressureEventLoop: EventLoop? = nil) {
        self.backpressureEventLoop = backpressureEventLoop
    }

    var backpressureEventLoop: EventLoop?

    enum State {
        case idle
        case head(HTTPResponseHead)
        case body(HTTPResponseHead, ByteBuffer)
        case end
        case error(Error)
    }

    var state = State.idle

    func didReceiveHead(task: HTTPClient.Task<Response>, _ head: HTTPResponseHead) -> EventLoopFuture<Void> {
        self.state = .head(head)
        return (self.backpressureEventLoop ?? task.eventLoop).makeSucceededFuture(())
    }

    func didReceiveBodyPart(task: HTTPClient.Task<Response>, _ buffer: ByteBuffer) -> EventLoopFuture<Void> {
        switch self.state {
        case .head(let head):
            self.state = .body(head, buffer)
        case .body(let head, var body):
            var buffer = buffer
            body.writeBuffer(&buffer)
            self.state = .body(head, body)
        default:
            preconditionFailure("expecting head or body")
        }
        return (self.backpressureEventLoop ?? task.eventLoop).makeSucceededFuture(())
    }

    func didFinishRequest(task: HTTPClient.Task<Response>) throws {}
}

class CountingDelegate: HTTPClientResponseDelegate {
    typealias Response = Int

    var count = 0

    func didReceiveBodyPart(task: HTTPClient.Task<Response>, _ buffer: ByteBuffer) -> EventLoopFuture<Void> {
        let str = buffer.getString(at: 0, length: buffer.readableBytes)
        if str?.starts(with: "id:") ?? false {
            self.count += 1
        }
        return task.eventLoop.makeSucceededFuture(())
    }

    func didFinishRequest(task: HTTPClient.Task<Response>) throws -> Int {
        return self.count
    }
}

internal final class RecordingHandler<Input, Output>: ChannelDuplexHandler {
    typealias InboundIn = Input
    typealias OutboundIn = Output

    public var writes: [Output] = []

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let object = unwrapOutboundIn(data)
        self.writes.append(object)
        context.write(NIOAny(IOData.byteBuffer(context.channel.allocator.buffer(capacity: 0))), promise: promise)
    }
}

internal final class HTTPBin {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let serverChannel: Channel
    let isShutdown: Atomic<Bool> = .init(value: false)

    var port: Int {
        return Int(self.serverChannel.localAddress!.port!)
    }

    var socketAddress: SocketAddress {
        return self.serverChannel.localAddress!
    }

    static func configureTLS(channel: Channel) -> EventLoopFuture<Void> {
        let configuration = TLSConfiguration.forServer(certificateChain: [.certificate(try! NIOSSLCertificate(bytes: Array(cert.utf8), format: .pem))],
                                                       privateKey: .privateKey(try! NIOSSLPrivateKey(bytes: Array(key.utf8), format: .pem)))
        let context = try! NIOSSLContext(configuration: configuration)
        return channel.pipeline.addHandler(try! NIOSSLServerHandler(context: context), position: .first)
    }

    init(ssl: Bool = false, compress: Bool = false, simulateProxy: HTTPProxySimulator.Option? = nil, channelPromise: EventLoopPromise<Channel>? = nil) {
        self.serverChannel = try! ServerBootstrap(group: self.group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: true, withErrorHandling: true)
                    .flatMap {
                        if compress {
                            return channel.pipeline.addHandler(HTTPResponseCompressor())
                        } else {
                            return channel.eventLoop.makeSucceededFuture(())
                        }
                    }
                    .flatMap {
                        if let simulateProxy = simulateProxy {
                            let responseEncoder = HTTPResponseEncoder()
                            let requestDecoder = ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes))

                            return channel.pipeline.addHandlers([responseEncoder, requestDecoder, HTTPProxySimulator(option: simulateProxy, encoder: responseEncoder, decoder: requestDecoder)], position: .first)
                        } else {
                            return channel.eventLoop.makeSucceededFuture(())
                        }
                    }
                    .flatMap {
                        if ssl {
                            return HTTPBin.configureTLS(channel: channel).flatMap {
                                channel.pipeline.addHandler(HttpBinHandler(channelPromise: channelPromise))
                            }
                        } else {
                            return channel.pipeline.addHandler(HttpBinHandler(channelPromise: channelPromise))
                        }
                    }
            }
            .bind(host: "127.0.0.1", port: 0).wait()
    }

    func shutdown() throws {
        self.isShutdown.store(true)
        try self.group.syncShutdownGracefully()
    }

    deinit {
        assert(self.isShutdown.load(), "HTTPBin not shutdown before deinit")
    }
}

final class HTTPProxySimulator: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias InboundOut = HTTPServerResponsePart
    typealias OutboundOut = HTTPServerResponsePart

    enum Option {
        case plaintext
        case tls
    }

    let option: Option
    let encoder: HTTPResponseEncoder
    let decoder: ByteToMessageHandler<HTTPRequestDecoder>
    var head: HTTPResponseHead

    init(option: Option, encoder: HTTPResponseEncoder, decoder: ByteToMessageHandler<HTTPRequestDecoder>) {
        self.option = option
        self.encoder = encoder
        self.decoder = decoder
        self.head = HTTPResponseHead(version: .init(major: 1, minor: 1), status: .ok, headers: .init([("Content-Length", "0"), ("Connection", "close")]))
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let request = self.unwrapInboundIn(data)
        switch request {
        case .head(let head):
            guard head.method == .CONNECT else {
                fatalError("Expected a CONNECT request")
            }
            if head.headers.contains(name: "proxy-authorization") {
                if head.headers["proxy-authorization"].first != "Basic YWxhZGRpbjpvcGVuc2VzYW1l" {
                    self.head.status = .proxyAuthenticationRequired
                }
            }
        case .body:
            ()
        case .end:
            context.write(self.wrapOutboundOut(.head(self.head)), promise: nil)
            context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)

            context.channel.pipeline.removeHandler(self, promise: nil)
            context.channel.pipeline.removeHandler(self.decoder, promise: nil)
            context.channel.pipeline.removeHandler(self.encoder, promise: nil)

            switch self.option {
            case .tls:
                _ = HTTPBin.configureTLS(channel: context.channel)
            case .plaintext: break
            }
        }
    }
}

internal struct HTTPResponseBuilder {
    let head: HTTPResponseHead
    var body: ByteBuffer?

    init(_ version: HTTPVersion = HTTPVersion(major: 1, minor: 1), status: HTTPResponseStatus, headers: HTTPHeaders = HTTPHeaders()) {
        self.head = HTTPResponseHead(version: version, status: status, headers: headers)
    }

    mutating func add(_ part: ByteBuffer) {
        if var body = body {
            var part = part
            body.writeBuffer(&part)
            self.body = body
        } else {
            self.body = part
        }
    }
}

internal struct RequestInfo: Codable {
    let data: String
}

internal final class HttpBinHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    let channelPromise: EventLoopPromise<Channel>?
    var resps = CircularBuffer<HTTPResponseBuilder>()

    init(channelPromise: EventLoopPromise<Channel>? = nil) {
        self.channelPromise = channelPromise
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch self.unwrapInboundIn(data) {
        case .head(let req):
            let url = URL(string: req.uri)!
            switch url.path {
            case "/ok":
                self.resps.append(HTTPResponseBuilder(status: .ok))
                return
            case "/get":
                if req.method != .GET {
                    self.resps.append(HTTPResponseBuilder(status: .methodNotAllowed))
                    return
                }
                self.resps.append(HTTPResponseBuilder(status: .ok))
                return
            case "/post":
                if req.method != .POST {
                    self.resps.append(HTTPResponseBuilder(status: .methodNotAllowed))
                    return
                }
                self.resps.append(HTTPResponseBuilder(status: .ok))
                return
            case "/redirect/302":
                var headers = HTTPHeaders()
                headers.add(name: "Location", value: "/ok")
                self.resps.append(HTTPResponseBuilder(status: .found, headers: headers))
                return
            case "/redirect/https":
                let port = self.value(for: "port", from: url.query!)
                var headers = HTTPHeaders()
                headers.add(name: "Location", value: "https://localhost:\(port)/ok")
                self.resps.append(HTTPResponseBuilder(status: .found, headers: headers))
                return
            case "/redirect/loopback":
                let port = self.value(for: "port", from: url.query!)
                var headers = HTTPHeaders()
                headers.add(name: "Location", value: "http://127.0.0.1:\(port)/echohostheader")
                self.resps.append(HTTPResponseBuilder(status: .found, headers: headers))
                return
            case "/redirect/infinite1":
                var headers = HTTPHeaders()
                headers.add(name: "Location", value: "/redirect/infinite2")
                self.resps.append(HTTPResponseBuilder(status: .found, headers: headers))
                return
            case "/redirect/infinite2":
                var headers = HTTPHeaders()
                headers.add(name: "Location", value: "/redirect/infinite1")
                self.resps.append(HTTPResponseBuilder(status: .found, headers: headers))
                return
            // Since this String is taken from URL.path, the percent encoding has been removed
            case "/percent encoded":
                if req.method != .GET {
                    self.resps.append(HTTPResponseBuilder(status: .methodNotAllowed))
                    return
                }
                self.resps.append(HTTPResponseBuilder(status: .ok))
                return
            case "/echohostheader":
                var builder = HTTPResponseBuilder(status: .ok)
                let hostValue = req.headers["Host"].first ?? ""
                var buff = context.channel.allocator.buffer(capacity: hostValue.utf8.count)
                buff.writeString(hostValue)
                builder.add(buff)
                self.resps.append(builder)
                return
            case "/wait":
                return
            case "/close":
                context.close(promise: nil)
                return
            case "/custom":
                context.writeAndFlush(wrapOutboundOut(.head(HTTPResponseHead(version: HTTPVersion(major: 1, minor: 1), status: .ok))), promise: nil)
                return
            case "/events/10/1": // TODO: parse path
                context.write(wrapOutboundOut(.head(HTTPResponseHead(version: HTTPVersion(major: 1, minor: 1), status: .ok))), promise: nil)
                for i in 0..<10 {
                    let msg = "id: \(i)"
                    var buf = context.channel.allocator.buffer(capacity: msg.count)
                    buf.writeString(msg)
                    context.writeAndFlush(wrapOutboundOut(.body(.byteBuffer(buf))), promise: nil)
                    Thread.sleep(forTimeInterval: 0.05)
                }
                context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
                return
            default:
                context.write(wrapOutboundOut(.head(HTTPResponseHead(version: HTTPVersion(major: 1, minor: 1), status: .notFound))), promise: nil)
                context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
                return
            }
        case .body(let body):
            if self.resps.isEmpty {
                return
            }
            var response = self.resps.removeFirst()
            response.add(body)
            self.resps.prepend(response)
        case .end:
            self.channelPromise?.succeed(context.channel)
            if self.resps.isEmpty {
                return
            }
            let response = self.resps.removeFirst()
            context.write(wrapOutboundOut(.head(response.head)), promise: nil)
            if var body = response.body {
                let data = body.readData(length: body.readableBytes)!
                let serialized = try! JSONEncoder().encode(RequestInfo(data: String(decoding: data,
                                                                                    as: Unicode.UTF8.self)))

                var responseBody = context.channel.allocator.buffer(capacity: serialized.count)
                responseBody.writeBytes(serialized)
                context.write(wrapOutboundOut(.body(.byteBuffer(responseBody))), promise: nil)
            }
            context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
        }
    }

    func value(for key: String, from query: String) -> String {
        let components = query.components(separatedBy: "&").map {
            $0.trimmingCharacters(in: .whitespaces)
        }

        for component in components {
            let nameAndValue = component.components(separatedBy: "=").map {
                $0.trimmingCharacters(in: .whitespaces)
            }

            if nameAndValue[0] == key {
                return nameAndValue[1]
            }
        }
        fatalError("parameter \(key) is missing from query: \(query)")
    }
}

internal class HttpBinForSSLUncleanShutdown {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let serverChannel: Channel

    var port: Int {
        return Int(self.serverChannel.localAddress!.port!)
    }

    init(channelPromise: EventLoopPromise<Channel>? = nil) {
        self.serverChannel = try! ServerBootstrap(group: self.group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
            .childChannelInitializer { channel in
                let requestDecoder = HTTPRequestDecoder()
                return channel.pipeline.addHandler(ByteToMessageHandler(requestDecoder)).flatMap {
                    let configuration = TLSConfiguration.forServer(certificateChain: [.certificate(try! NIOSSLCertificate(bytes: Array(cert.utf8), format: .pem))],
                                                                   privateKey: .privateKey(try! NIOSSLPrivateKey(bytes: Array(key.utf8), format: .pem)))
                    let context = try! NIOSSLContext(configuration: configuration)
                    return channel.pipeline.addHandler(try! NIOSSLServerHandler(context: context), name: "NIOSSLServerHandler", position: .first).flatMap {
                        channel.pipeline.addHandler(HttpBinForSSLUncleanShutdownHandler(channelPromise: channelPromise))
                    }
                }
            }.bind(host: "127.0.0.1", port: 0).wait()
    }

    func shutdown() {
        try! self.group.syncShutdownGracefully()
    }
}

internal final class HttpBinForSSLUncleanShutdownHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = ByteBuffer

    let channelPromise: EventLoopPromise<Channel>?

    init(channelPromise: EventLoopPromise<Channel>? = nil) {
        self.channelPromise = channelPromise
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch self.unwrapInboundIn(data) {
        case .head(let req):
            self.channelPromise?.succeed(context.channel)

            let response: String?
            switch req.uri {
            case "/nocontentlength":
                response = """
                HTTP/1.1 200 OK\r\n\
                Connection: close\r\n\
                \r\n\
                foo
                """
            case "/nocontent":
                response = """
                HTTP/1.1 204 OK\r\n\
                Connection: close\r\n\
                \r\n
                """
            case "/noresponse":
                response = nil
            case "/wrongcontentlength":
                response = """
                HTTP/1.1 200 OK\r\n\
                Connection: close\r\n\
                Content-Length: 6\r\n\
                \r\n\
                foo
                """
            default:
                response = """
                HTTP/1.1 404 OK\r\n\
                Connection: close\r\n\
                Content-Length: 9\r\n\
                \r\n\
                Not Found
                """
            }

            if let response = response {
                var buffer = context.channel.allocator.buffer(capacity: response.count)
                buffer.writeString(response)
                context.writeAndFlush(self.wrapOutboundOut(buffer), promise: nil)
            }

            context.channel.pipeline.removeHandler(name: "NIOSSLServerHandler").whenSuccess {
                context.close(promise: nil)
            }
        case .body:
            ()
        case .end:
            ()
        }
    }
}

extension ByteBuffer {
    public static func of(string: String) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: string.count)
        buffer.writeString(string)
        return buffer
    }

    public static func of(bytes: [UInt8]) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        return buffer
    }
}

private let cert = """
-----BEGIN CERTIFICATE-----
MIICmDCCAYACCQCPC8JDqMh1zzANBgkqhkiG9w0BAQsFADANMQswCQYDVQQGEwJ1
czAgFw0xODEwMzExNTU1MjJaGA8yMTE4MTAwNzE1NTUyMlowDTELMAkGA1UEBhMC
dXMwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQDiC+TGmbSP/nWWN1tj
yNfnWCU5ATjtIOfdtP6ycx8JSeqkvyNXG21kNUn14jTTU8BglGL2hfVpCbMisUdb
d3LpP8unSsvlOWwORFOViSy4YljSNM/FNoMtavuITA/sEELYgjWkz2o/uHPZHud9
+JQwGJgqIlMa3mr2IaaUZlWN3D1u88bzJYhpt3YyxRy9+OEoOKy36KdWwhKzV3S8
kXb0Y1GbAo68jJ9RfzeLy290mIs9qG2y1CNXWO6sxf6B//LaalizZiCfzYAVKcNR
9oNYsEJc5KB/+DsAGTzR7mL+oiU4h/vwVb2GTDat5C+PFGi6j1ujxYTRPO538ljg
dslnAgMBAAEwDQYJKoZIhvcNAQELBQADggEBAFYhA7sw8odOsRO8/DUklBOjPnmn
a078oSumgPXXw6AgcoAJv/Qthjo6CCEtrjYfcA9jaBw9/Tii7mDmqDRS5c9ZPL8+
NEPdHjFCFBOEvlL6uHOgw0Z9Wz+5yCXnJ8oNUEgc3H2NbbzJF6sMBXSPtFS2NOK8
OsAI9OodMrDd6+lwljrmFoCCkJHDEfE637IcsbgFKkzhO/oNCRK6OrudG4teDahz
Au4LoEYwT730QKC/VQxxEVZobjn9/sTrq9CZlbPYHxX4fz6e00sX7H9i49vk9zQ5
5qCm9ljhrQPSa42Q62PPE2BEEGSP2KBm0J+H3vlvCD6+SNc/nMZjrRmgjrI=
-----END CERTIFICATE-----
"""

private let key = """
-----BEGIN PRIVATE KEY-----
MIIEvwIBADANBgkqhkiG9w0BAQEFAASCBKkwggSlAgEAAoIBAQDiC+TGmbSP/nWW
N1tjyNfnWCU5ATjtIOfdtP6ycx8JSeqkvyNXG21kNUn14jTTU8BglGL2hfVpCbMi
sUdbd3LpP8unSsvlOWwORFOViSy4YljSNM/FNoMtavuITA/sEELYgjWkz2o/uHPZ
Hud9+JQwGJgqIlMa3mr2IaaUZlWN3D1u88bzJYhpt3YyxRy9+OEoOKy36KdWwhKz
V3S8kXb0Y1GbAo68jJ9RfzeLy290mIs9qG2y1CNXWO6sxf6B//LaalizZiCfzYAV
KcNR9oNYsEJc5KB/+DsAGTzR7mL+oiU4h/vwVb2GTDat5C+PFGi6j1ujxYTRPO53
8ljgdslnAgMBAAECggEBANZNWFNAnYJ2R5xmVuo/GxFk68Ujd4i4TZpPYbhkk+QG
g8I0w5htlEQQkVHfZx2CpTvq8feuAH/YhlA5qeD5WaPwq26q5qsmyV6tQGDgb9lO
w85l6ySZDbwdVOJe2il/MSB6MclSKvTGNm59chJnfHYsmvY3HHq4qsc2F+tRKYMW
pY75LgEbaTUV69J3cbC1wAeVjv0q/krND+YkhYpTxNZhbazK/FHOCvY+zFu9fg0L
zpwbn5fb6wIvqG7tXp7koa3QMn64AXmO/fb5mBd8G2vBGYnxwb7Egwdg/3Dw+BXu
ynQLP7ixWsE2KNfR9Ce1i3YvEo6QDTv2340I3dntxkECgYEA9vdaL4PGyvEbpim4
kqz1vuug8Iq0nTVDo6jmgH1o+XdcIbW3imXtgi5zUJpj4oDD7/4aufiJZjG64i/v
phe11xeUvh5QNNOzeMymVDoJut97F97KKKTv7bG8Rpon/WzH2I0SoAkECCwmdWAJ
H3nvOCnXEkpbCqmIUvHVURPRDn8CgYEA6lCk3EzFQlbXs3Sj5op61R3Mscx7/35A
eGv5axzbENHt1so+s3Zvyyi1bo4VBcwnKVCvQjmTuLiqrc9VfX8XdbiTUNnEr2u3
992Ja6DEJTZ9gy5WiviwYnwU2HpjwOVNBb17T0NLoRHkDZ6iXj7NZgwizOki5p3j
/hS0pObSIRkCgYEAiEdOGNIarHoHy9VR6H5QzR2xHYssx2NRA8p8B4MsnhxjVqaz
tUcxnJiNQXkwjRiJBrGthdnD2ASxH4dcMsb6rMpyZcbMc5ouewZS8j9khx4zCqUB
4RPC4eMmBb+jOZEBZlnSYUUYWHokbrij0B61BsTvzUQCoQuUElEoaSkKP3kCgYEA
mwdqXHvK076jjo9w1drvtEu4IDc8H2oH++TsrEr2QiWzaDZ9z71f8BnqGNCW5jQS
AQrqOjXgIArGmqMgXB0Xh4LsrUS4Fpx9ptiD0JsYy8pGtuGUzvQFt9OC80ve7kSI
dnDMwj+zLUmqCrzXjuWcfpUu/UaPGeiDbZuDfcteYhkCgYBLyL5JY7Qd4gVQIhFX
7Sv3sNJN3KZCQHEzut7IwojaxgpuxiFvgsoXXuYolVCQp32oWbYcE2Yke+hOKsTE
sCMAWZiSGN2Nrfea730IYAXkUm8bpEd3VxDXEEv13nxVeQof+JGMdlkldFGaBRDU
oYQsPj00S3/GA9WDapwe81Wl2A==
-----END PRIVATE KEY-----
"""
