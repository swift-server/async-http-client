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
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import NIOHPACK
import NIOHTTP1
import NIOHTTP2
import NIOHTTPCompression
import NIOPosix
import NIOSSL
import NIOTLS
import NIOTransportServices
import XCTest
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Are we testing NIO Transport services
func isTestingNIOTS() -> Bool {
    #if canImport(Network)
    return ProcessInfo.processInfo.environment["DISABLE_TS_TESTS"] != "true"
    #else
    return false
    #endif
}

func getDefaultEventLoopGroup(numberOfThreads: Int) -> EventLoopGroup {
    #if canImport(Network)
    if #available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *),
       isTestingNIOTS() {
        return NIOTSEventLoopGroup(loopCount: numberOfThreads, defaultQoS: .default)
    }
    #endif
    return MultiThreadedEventLoopGroup(numberOfThreads: numberOfThreads)
}

let canBindIPv6Loopback: Bool = {
    let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer { try! elg.syncShutdownGracefully() }
    let serverChannel = try? ServerBootstrap(group: elg)
        .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
        .bind(host: "::1", port: 0)
        .wait()
    let didBind = (serverChannel != nil)
    try! serverChannel?.close().wait()
    return didBind
}()

/// Runs the given block in the context of a non-English C locale (in this case, German).
/// Throws an XCTSkip error if the locale is not supported by the system.
func withCLocaleSetToGerman(_ body: () throws -> Void) throws {
    guard let germanLocale = newlocale(LC_TIME_MASK | LC_NUMERIC_MASK, "de_DE", nil) else {
        if errno == ENOENT {
            throw XCTSkip("System does not support locale de_DE")
        } else {
            XCTFail("Failed to create locale de_DE")
            return
        }
    }
    defer { freelocale(germanLocale) }

    let oldLocale = uselocale(germanLocale)
    defer { _ = uselocale(oldLocale) }
    try body()
}

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

class DelayOnHeadDelegate: HTTPClientResponseDelegate {
    typealias Response = ByteBuffer

    let eventLoop: EventLoop
    let didReceiveHead: (HTTPResponseHead, EventLoopPromise<Void>) -> Void

    private var data: ByteBuffer

    private var mayReceiveData = false

    private var expectError = false

    init(eventLoop: EventLoop, didReceiveHead: @escaping (HTTPResponseHead, EventLoopPromise<Void>) -> Void) {
        self.eventLoop = eventLoop
        self.didReceiveHead = didReceiveHead
        self.data = ByteBuffer()
    }

    func didReceiveHead(task: HTTPClient.Task<Response>, _ head: HTTPResponseHead) -> EventLoopFuture<Void> {
        XCTAssertFalse(self.mayReceiveData)
        XCTAssertFalse(self.expectError)

        let promise = self.eventLoop.makePromise(of: Void.self)
        promise.futureResult.whenComplete {
            switch $0 {
            case .success:
                self.mayReceiveData = true
            case .failure:
                self.expectError = true
            }
        }

        self.didReceiveHead(head, promise)
        return promise.futureResult
    }

    func didReceiveBodyPart(task: HTTPClient.Task<Response>, _ buffer: ByteBuffer) -> EventLoopFuture<Void> {
        XCTAssertTrue(self.mayReceiveData)
        XCTAssertFalse(self.expectError)
        self.data.writeImmutableBuffer(buffer)
        return self.eventLoop.makeSucceededFuture(())
    }

    func didFinishRequest(task: HTTPClient.Task<Response>) throws -> Response {
        XCTAssertTrue(self.mayReceiveData)
        XCTAssertFalse(self.expectError)
        return self.data
    }

    func didReceiveError(task: HTTPClient.Task<ByteBuffer>, _ error: Error) {
        XCTAssertTrue(self.expectError)
    }
}

enum TemporaryFileHelpers {
    private static var temporaryDirectory: String {
        #if targetEnvironment(simulator)
        // Simulator temp directories are so long (and contain the user name) that they're not usable
        // for UNIX Domain Socket paths (which are limited to 103 bytes).
        return "/tmp"
        #else
        #if os(Android)
        return "/data/local/tmp"
        #elseif os(Linux)
        return "/tmp"
        #else
        if #available(macOS 10.12, iOS 10, tvOS 10, watchOS 3, *) {
            return FileManager.default.temporaryDirectory.path
        } else {
            return "/tmp"
        }
        #endif // os
        #endif // targetEnvironment
    }

    private static func openTemporaryFile() -> (CInt, String) {
        let template = "\(temporaryDirectory)/ahc_XXXXXX"
        var templateBytes = template.utf8 + [0]
        let templateBytesCount = templateBytes.count
        let fd = templateBytes.withUnsafeMutableBufferPointer { ptr in
            ptr.baseAddress!.withMemoryRebound(to: Int8.self, capacity: templateBytesCount) { ptr in
                mkstemp(ptr)
            }
        }
        templateBytes.removeLast()
        return (fd, String(decoding: templateBytes, as: Unicode.UTF8.self))
    }

    /// This function creates a filename that can be used for a temporary UNIX domain socket path.
    ///
    /// If the temporary directory is too long to store a UNIX domain socket path, it will `chdir` into the temporary
    /// directory and return a short-enough path. The iOS simulator is known to have too long paths.
    internal static func withTemporaryUnixDomainSocketPathName<T>(directory: String = temporaryDirectory,
                                                                  _ body: (String) throws -> T) throws -> T {
        // this is racy but we're trying to create the shortest possible path so we can't add a directory...
        let (fd, path) = self.openTemporaryFile()
        close(fd)
        try! FileManager.default.removeItem(atPath: path)

        let saveCurrentDirectory = FileManager.default.currentDirectoryPath
        let restoreSavedCWD: Bool
        let shortEnoughPath: String
        do {
            _ = try SocketAddress(unixDomainSocketPath: path)
            // this seems to be short enough for a UDS
            shortEnoughPath = path
            restoreSavedCWD = false
        } catch SocketAddressError.unixDomainSocketPathTooLong {
            FileManager.default.changeCurrentDirectoryPath(URL(fileURLWithPath: path).deletingLastPathComponent().absoluteString)
            shortEnoughPath = URL(fileURLWithPath: path).lastPathComponent
            restoreSavedCWD = true
            print("WARNING: Path '\(path)' could not be used as UNIX domain socket path, using chdir & '\(shortEnoughPath)'")
        }
        defer {
            if FileManager.default.fileExists(atPath: path) {
                try? FileManager.default.removeItem(atPath: path)
            }
            if restoreSavedCWD {
                FileManager.default.changeCurrentDirectoryPath(saveCurrentDirectory)
            }
        }
        return try body(shortEnoughPath)
    }

    /// This function creates a filename that can be used as a temporary file.
    internal static func withTemporaryFilePath<T>(
        directory: String = temporaryDirectory,
        _ body: (String) throws -> T
    ) throws -> T {
        let (fd, path) = self.openTemporaryFile()
        close(fd)
        try! FileManager.default.removeItem(atPath: path)

        defer {
            if FileManager.default.fileExists(atPath: path) {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        return try body(path)
    }

    internal static func fileSize(path: String) throws -> Int? {
        return try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int
    }

    internal static func fileExists(path: String) -> Bool {
        return FileManager.default.fileExists(atPath: path)
    }
}

enum TestTLS {
    static let certificate = try! NIOSSLCertificate(bytes: Array(cert.utf8), format: .pem)
    static let privateKey = try! NIOSSLPrivateKey(bytes: Array(key.utf8), format: .pem)
}

internal final class HTTPBin<RequestHandler: ChannelInboundHandler> where
    RequestHandler.InboundIn == HTTPServerRequestPart,
    RequestHandler.OutboundOut == HTTPServerResponsePart {
    enum BindTarget {
        case unixDomainSocket(String)
        case localhostIPv4RandomPort
        case localhostIPv6RandomPort
    }

    enum Mode {
        // refuses all connections
        case refuse
        // supports http1.1 connections only, which can be either plain text or encrypted
        case http1_1(ssl: Bool = false, compress: Bool = false)
        // supports http1.1 and http2 connections which must be always encrypted
        case http2(compress: Bool)

        // supports request decompression and http response compression
        var compress: Bool {
            switch self {
            case .refuse:
                return false
            case .http1_1(ssl: _, compress: let compress), .http2(compress: let compress):
                return compress
            }
        }
    }

    enum Proxy {
        case none
        case simulate(authorization: String?)
    }

    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    private let activeConnCounterHandler: ConnectionsCountHandler
    var activeConnections: Int {
        return self.activeConnCounterHandler.currentlyActiveConnections
    }

    var createdConnections: Int {
        return self.activeConnCounterHandler.createdConnections
    }

    var port: Int {
        return Int(self.serverChannel.localAddress!.port!)
    }

    var socketAddress: SocketAddress {
        return self.serverChannel.localAddress!
    }

    private let mode: Mode
    private let sslContext: NIOSSLContext?
    private var serverChannel: Channel!
    private let isShutdown: NIOAtomic<Bool> = .makeAtomic(value: false)
    private let handlerFactory: (Int) -> (RequestHandler)

    init(
        _ mode: Mode = .http1_1(ssl: false, compress: false),
        proxy: Proxy = .none,
        bindTarget: BindTarget = .localhostIPv4RandomPort,
        handlerFactory: @escaping (Int) -> (RequestHandler)
    ) {
        self.mode = mode
        self.sslContext = HTTPBin.sslContext(for: mode)
        self.handlerFactory = handlerFactory

        let socketAddress: SocketAddress
        switch bindTarget {
        case .localhostIPv4RandomPort:
            socketAddress = try! SocketAddress(ipAddress: "127.0.0.1", port: 0)
        case .localhostIPv6RandomPort:
            socketAddress = try! SocketAddress(ipAddress: "::1", port: 0)
        case .unixDomainSocket(let path):
            socketAddress = try! SocketAddress(unixDomainSocketPath: path)
        }

        self.activeConnCounterHandler = ConnectionsCountHandler()

        let connectionIDAtomic = NIOAtomic<Int>.makeAtomic(value: 0)

        self.serverChannel = try! ServerBootstrap(group: self.group)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .serverChannelInitializer { channel in
                channel.pipeline.addHandler(self.activeConnCounterHandler)
            }.childChannelInitializer { channel in
                do {
                    let connectionID = connectionIDAtomic.add(1)

                    if case .refuse = mode {
                        throw HTTPBinError.refusedConnection
                    }

                    // if we need to simulate a proxy, we need to add those handlers first
                    if case .simulate(authorization: let expectedAuthorization) = proxy {
                        try self.syncAddHTTPProxyHandlers(
                            to: channel,
                            connectionID: connectionID,
                            expectedAuthorization: expectedAuthorization
                        )
                        return channel.eventLoop.makeSucceededVoidFuture()
                    }

                    // if a connection has been established, we need to negotiate TLS before
                    // anything else. Depending on the negotiation, the HTTPHandlers will be added.
                    if let sslContext = self.sslContext {
                        try self.addTLSHandlerAndUpgrader(
                            to: channel,
                            sslContext: sslContext,
                            connectionID: connectionID
                        )
                        return channel.eventLoop.makeSucceededVoidFuture()
                    }

                    // if neither HTTP Proxy nor TLS are wanted, we can add HTTP1 handlers directly
                    try self.syncAddHTTP1Handlers(to: channel, connectionID: connectionID)
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }.bind(to: socketAddress).wait()
    }

    private func syncAddHTTPProxyHandlers(
        to channel: Channel,
        connectionID: Int,
        expectedAuthorization: String?
    ) throws {
        let sync = channel.pipeline.syncOperations
        let promise = channel.eventLoop.makePromise(of: Void.self)

        let responseEncoder = HTTPResponseEncoder()
        let requestDecoder = ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes))
        let proxySimulator = HTTPProxySimulator(promise: promise, expectedAuhorization: expectedAuthorization)

        try sync.addHandler(responseEncoder)
        try sync.addHandler(requestDecoder)
        try sync.addHandler(proxySimulator)

        promise.futureResult.flatMap { _ in
            channel.pipeline.removeHandler(proxySimulator)
        }.flatMap { _ in
            channel.pipeline.removeHandler(responseEncoder)
        }.flatMap { _ in
            channel.pipeline.removeHandler(requestDecoder)
        }.whenComplete { result in
            switch result {
            case .failure:
                channel.close(mode: .all, promise: nil)
            case .success:
                self.httpProxyEstablished(channel, connectionID: connectionID)
            }
        }
    }

    func syncAddHTTP1Handlers(to channel: Channel, connectionID: Int) throws {
        let sync = channel.pipeline.syncOperations
        try sync.configureHTTPServerPipeline(withPipeliningAssistance: true, withErrorHandling: true)

        if self.mode.compress {
            try sync.addHandler(HTTPResponseCompressor())
        }

        try sync.addHandler(self.handlerFactory(connectionID))
    }

    private func httpProxyEstablished(_ channel: Channel, connectionID: Int) {
        do {
            // if a connection has been established, we need to negotiate TLS before
            // anything else. Depending on the negotiation, the HTTPHandlers will be added.
            if let sslContext = self.sslContext {
                try self.addTLSHandlerAndUpgrader(
                    to: channel,
                    sslContext: sslContext,
                    connectionID: connectionID
                )
                return
            }

            // if neither HTTP Proxy nor TLS are wanted, we can add HTTP1 handlers directly
            try self.syncAddHTTP1Handlers(to: channel, connectionID: connectionID)
        } catch {
            // in case of an while modifying the pipeline we should close the connection
            channel.close(mode: .all, promise: nil)
        }
    }

    private static func tlsConfiguration(for mode: Mode) -> TLSConfiguration? {
        var configuration: TLSConfiguration?

        switch mode {
        case .refuse, .http1_1(ssl: false, compress: _):
            break
        case .http2:
            configuration = .makeServerConfiguration(
                certificateChain: [.certificate(TestTLS.certificate)],
                privateKey: .privateKey(TestTLS.privateKey)
            )
            configuration!.applicationProtocols = NIOHTTP2SupportedALPNProtocols
        case .http1_1(ssl: true, compress: _):
            configuration = .makeServerConfiguration(
                certificateChain: [.certificate(TestTLS.certificate)],
                privateKey: .privateKey(TestTLS.privateKey)
            )
        }

        return configuration
    }

    private static func sslContext(for mode: Mode) -> NIOSSLContext? {
        if let tlsConfiguration = self.tlsConfiguration(for: mode) {
            return try! NIOSSLContext(configuration: tlsConfiguration)
        }
        return nil
    }

    private func addTLSHandlerAndUpgrader(to channel: Channel, sslContext: NIOSSLContext, connectionID: Int) throws {
        let sslHandler = NIOSSLServerHandler(context: sslContext)

        // copy pasted from NIOHTTP2
        let alpnHandler = ApplicationProtocolNegotiationHandler { result in
            do {
                switch result {
                case .negotiated("h2"):
                    // Successful upgrade to HTTP/2. Let the user configure the pipeline.
                    let http2Handler = NIOHTTP2Handler(
                        mode: .server,
                        initialSettings: [
                            // TODO: make max concurrent streams configurable
                            HTTP2Setting(parameter: .maxConcurrentStreams, value: 10),
                            HTTP2Setting(parameter: .maxHeaderListSize, value: HPACKDecoder.defaultMaxHeaderListSize),
                        ]
                    )
                    let multiplexer = HTTP2StreamMultiplexer(
                        mode: .server,
                        channel: channel,
                        inboundStreamInitializer: { channel in
                            do {
                                let sync = channel.pipeline.syncOperations

                                try sync.addHandler(HTTP2FramePayloadToHTTP1ServerCodec())
                                try sync.addHandler(self.handlerFactory(connectionID))

                                return channel.eventLoop.makeSucceededVoidFuture()
                            } catch {
                                return channel.eventLoop.makeFailedFuture(error)
                            }
                        }
                    )

                    let sync = channel.pipeline.syncOperations

                    try sync.addHandler(http2Handler)
                    try sync.addHandler(multiplexer)
                case .negotiated("http/1.1"), .fallback:
                    // Explicit or implicit HTTP/1.1 choice.
                    try self.syncAddHTTP1Handlers(to: channel, connectionID: connectionID)
                case .negotiated:
                    // We negotiated something that isn't HTTP/1.1. This is a bad scene, and is a good indication
                    // of a user configuration error. We're going to close the connection directly.
                    channel.close(mode: .all, promise: nil)
                    throw NIOHTTP2Errors.invalidALPNToken()
                }

                return channel.eventLoop.makeSucceededVoidFuture()
            } catch {
                return channel.eventLoop.makeFailedFuture(error)
            }
        }

        try channel.pipeline.syncOperations.addHandler(alpnHandler)
        try channel.pipeline.syncOperations.addHandler(sslHandler, position: .before(alpnHandler))
    }

    func shutdown() throws {
        self.isShutdown.store(true)
        try self.group.syncShutdownGracefully()
    }

    deinit {
        assert(self.isShutdown.load(), "HTTPBin not shutdown before deinit")
    }
}

extension HTTPBin where RequestHandler == HTTPBinHandler {
    convenience init(
        _ mode: Mode = .http1_1(ssl: false, compress: false),
        proxy: Proxy = .none,
        bindTarget: BindTarget = .localhostIPv4RandomPort
    ) {
        self.init(mode, proxy: proxy, bindTarget: bindTarget) { HTTPBinHandler(connectionID: $0) }
    }
}

enum HTTPBinError: Error {
    case refusedConnection
    case invalidProxyRequest
}

final class HTTPProxySimulator: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias InboundOut = HTTPServerResponsePart
    typealias OutboundOut = HTTPServerResponsePart

    // the promise to succeed, once the proxy connection is setup
    let promise: EventLoopPromise<Void>
    let expectedAuhorization: String?

    var head: HTTPResponseHead

    init(promise: EventLoopPromise<Void>, expectedAuhorization: String?) {
        self.promise = promise
        self.expectedAuhorization = expectedAuhorization
        self.head = HTTPResponseHead(version: .init(major: 1, minor: 1), status: .ok, headers: .init([("Content-Length", "0")]))
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let request = self.unwrapInboundIn(data)
        switch request {
        case .head(let head):
            guard head.method == .CONNECT else {
                self.head.status = .badRequest
                return
            }

            if let expectedAuhorization = self.expectedAuhorization {
                guard let authorization = head.headers["proxy-authorization"].first,
                      expectedAuhorization == authorization else {
                    self.head.status = .proxyAuthenticationRequired
                    return
                }
            }

        case .body:
            ()
        case .end:
            let okay = self.head.status != .ok
            context.write(self.wrapOutboundOut(.head(self.head)), promise: nil)
            context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            if okay {
                self.promise.fail(HTTPBinError.invalidProxyRequest)
            } else {
                self.promise.succeed(())
            }
        }
    }
}

internal struct HTTPResponseBuilder {
    var head: HTTPResponseHead
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

internal struct RequestInfo: Codable, Equatable {
    var data: String
    var requestNumber: Int
    var connectionNumber: Int
}

internal final class HTTPBinHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    var resps = CircularBuffer<HTTPResponseBuilder>()
    var responseHeaders = HTTPHeaders()
    var delay: TimeAmount = .seconds(0)
    let creationDate = Date()
    var shouldClose = false
    var isServingRequest = false
    let connectionID: Int
    var requestId: Int = 0

    init(connectionID: Int) {
        self.connectionID = connectionID
    }

    func parseAndSetOptions(from head: HTTPRequestHead) {
        if let delay = head.headers["X-internal-delay"].first {
            if let milliseconds = Int64(delay) {
                self.delay = TimeAmount.milliseconds(milliseconds)
            } else {
                assertionFailure("Invalid interval format")
            }
        } else {
            self.delay = .nanoseconds(0)
        }

        for header in head.headers {
            let needle = "x-send-back-header-"
            if header.name.lowercased().starts(with: needle) {
                self.responseHeaders.add(name: String(header.name.dropFirst(needle.count)),
                                         value: header.value)
            }
        }
    }

    func writeEvents(context: ChannelHandlerContext, isContentLengthRequired: Bool = false) {
        let headers: HTTPHeaders
        if isContentLengthRequired {
            headers = HTTPHeaders([("Content-Length", "50")])
        } else {
            headers = HTTPHeaders()
        }

        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: HTTPVersion(major: 1, minor: 1), status: .ok, headers: headers))), promise: nil)
        for i in 0..<10 {
            let msg = "id: \(i)"
            var buf = context.channel.allocator.buffer(capacity: msg.count)
            buf.writeString(msg)
            context.writeAndFlush(wrapOutboundOut(.body(.byteBuffer(buf))), promise: nil)
            Thread.sleep(forTimeInterval: 0.05)
        }
        context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
    }

    func writeChunked(context: ChannelHandlerContext) {
        // This tests receiving chunks very fast: please do not insert delays here!
        let headers = HTTPHeaders([("Transfer-Encoding", "chunked")])

        context.write(self.wrapOutboundOut(.head(HTTPResponseHead(version: HTTPVersion(major: 1, minor: 1), status: .ok, headers: headers))), promise: nil)
        for i in 0..<10 {
            let msg = "id: \(i)"
            var buf = context.channel.allocator.buffer(capacity: msg.count)
            buf.writeString(msg)
            context.write(wrapOutboundOut(.body(.byteBuffer(buf))), promise: nil)
        }

        context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        self.isServingRequest = true
        switch self.unwrapInboundIn(data) {
        case .head(let req):
            self.responseHeaders = HTTPHeaders()
            self.requestId += 1
            self.parseAndSetOptions(from: req)
            let urlComponents = URLComponents(string: req.uri)!
            switch urlComponents.percentEncodedPath {
            case "/":
                var headers = self.responseHeaders
                headers.add(name: "X-Is-This-Slash", value: "Yes")
                self.resps.append(HTTPResponseBuilder(status: .ok, headers: headers))
                return
            case "/echo-uri":
                var headers = self.responseHeaders
                headers.add(name: "X-Calling-URI", value: req.uri)
                self.resps.append(HTTPResponseBuilder(status: .ok, headers: headers))
                return
            case "/echo-method":
                var headers = self.responseHeaders
                headers.add(name: "X-Method-Used", value: req.method.rawValue)
                self.resps.append(HTTPResponseBuilder(status: .ok, headers: headers))
                return
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
            case "/stats":
                var body = context.channel.allocator.buffer(capacity: 1)
                body.writeString("Just some stats mate.")
                var builder = HTTPResponseBuilder(status: .ok)
                builder.add(body)

                self.resps.append(builder)
            case "/post":
                if req.method != .POST {
                    self.resps.append(HTTPResponseBuilder(status: .methodNotAllowed))
                    return
                }
                self.resps.append(HTTPResponseBuilder(status: .ok))
                return
            case "/redirect/302":
                var headers = self.responseHeaders
                headers.add(name: "location", value: "/ok")
                self.resps.append(HTTPResponseBuilder(status: .found, headers: headers))
                return
            case "/redirect/https":
                let port = self.value(for: "port", from: urlComponents.query!)
                var headers = self.responseHeaders
                headers.add(name: "Location", value: "https://localhost:\(port)/ok")
                self.resps.append(HTTPResponseBuilder(status: .found, headers: headers))
                return
            case "/redirect/loopback":
                let port = self.value(for: "port", from: urlComponents.query!)
                var headers = self.responseHeaders
                headers.add(name: "Location", value: "http://127.0.0.1:\(port)/echohostheader")
                self.resps.append(HTTPResponseBuilder(status: .found, headers: headers))
                return
            case "/redirect/infinite1":
                var headers = self.responseHeaders
                headers.add(name: "Location", value: "/redirect/infinite2")
                self.resps.append(HTTPResponseBuilder(status: .found, headers: headers))
                return
            case "/redirect/infinite2":
                var headers = self.responseHeaders
                headers.add(name: "Location", value: "/redirect/infinite1")
                self.resps.append(HTTPResponseBuilder(status: .found, headers: headers))
                return
            case "/redirect/target":
                var headers = self.responseHeaders
                let targetURL = req.headers["X-Target-Redirect-URL"].first ?? ""
                headers.add(name: "Location", value: targetURL)
                self.resps.append(HTTPResponseBuilder(status: .found, headers: headers))
                return
            case "/percent%20encoded":
                if req.method != .GET {
                    self.resps.append(HTTPResponseBuilder(status: .methodNotAllowed))
                    return
                }
                self.resps.append(HTTPResponseBuilder(status: .ok))
                return
            case "/percent%2Fencoded/hello":
                if req.method != .GET {
                    self.resps.append(HTTPResponseBuilder(status: .methodNotAllowed))
                    return
                }
                self.resps.append(HTTPResponseBuilder(status: .ok))
                return
            case "/echohostheader":
                var builder = HTTPResponseBuilder(status: .ok)
                let hostValue = req.headers["Host"].first ?? ""
                let buff = context.channel.allocator.buffer(string: hostValue)
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
                self.writeEvents(context: context)
                return
            case "/events/10/content-length":
                self.writeEvents(context: context, isContentLengthRequired: true)
            case "/chunked":
                self.writeChunked(context: context)
                return
            case "/close-on-response":
                var headers = self.responseHeaders
                headers.replaceOrAdd(name: "connection", value: "close")

                var builder = HTTPResponseBuilder(.http1_1, status: .ok, headers: headers)
                builder.body = ByteBuffer(string: "some body content")

                // We're forcing this closed now.
                self.shouldClose = true
                self.resps.append(builder)
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
            if self.resps.isEmpty {
                return
            }
            var response = self.resps.removeFirst()
            response.head.headers.add(contentsOf: self.responseHeaders)
            context.write(wrapOutboundOut(.head(response.head)), promise: nil)
            if let body = response.body {
                let requestInfo = RequestInfo(data: String(buffer: body),
                                              requestNumber: self.requestId,
                                              connectionNumber: self.connectionID)
                let responseBody = try! JSONEncoder().encodeAsByteBuffer(requestInfo,
                                                                         allocator: context.channel.allocator)
                context.write(wrapOutboundOut(.body(.byteBuffer(responseBody))), promise: nil)
            } else {
                let requestInfo = RequestInfo(data: "",
                                              requestNumber: self.requestId,
                                              connectionNumber: self.connectionID)
                let responseBody = try! JSONEncoder().encodeAsByteBuffer(requestInfo,
                                                                         allocator: context.channel.allocator)
                context.write(wrapOutboundOut(.body(.byteBuffer(responseBody))), promise: nil)
            }
            context.eventLoop.scheduleTask(in: self.delay) {
                guard context.channel.isActive else {
                    context.close(promise: nil)
                    return
                }

                context.writeAndFlush(self.wrapOutboundOut(.end(nil))).whenComplete { result in
                    self.isServingRequest = false
                    switch result {
                    case .success:
                        if self.responseHeaders[canonicalForm: "X-Close-Connection"].contains("true") ||
                            self.shouldClose {
                            context.close(promise: nil)
                        }
                    case .failure(let error):
                        assertionFailure("\(error)")
                    }
                }
            }
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

final class ConnectionsCountHandler: ChannelInboundHandler {
    typealias InboundIn = Channel

    private let activeConns = NIOAtomic<Int>.makeAtomic(value: 0)
    private let createdConns = NIOAtomic<Int>.makeAtomic(value: 0)

    var createdConnections: Int {
        self.createdConns.load()
    }

    var currentlyActiveConnections: Int {
        self.activeConns.load()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channel = self.unwrapInboundIn(data)

        _ = self.activeConns.add(1)
        _ = self.createdConns.add(1)
        channel.closeFuture.whenComplete { _ in
            _ = self.activeConns.sub(1)
        }

        context.fireChannelRead(data)
    }
}

internal final class CloseWithoutClosingServerHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private var callback: (() -> Void)?
    private var onClosePromise: EventLoopPromise<Void>?

    init(_ callback: @escaping () -> Void) {
        self.callback = callback
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.onClosePromise = context.eventLoop.makePromise()
        self.onClosePromise!.futureResult.whenSuccess(self.callback!)
        self.callback = nil
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        assert(self.onClosePromise == nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if let onClosePromise = self.onClosePromise {
            self.onClosePromise = nil
            onClosePromise.succeed(())
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .end = self.unwrapInboundIn(data) else {
            return
        }

        // We're gonna send a response back here, with Connection: close, but we will
        // not close the connection. This reproduces #324.
        let headers = HTTPHeaders([
            ("Host", "CloseWithoutClosingServerHandler"),
            ("Content-Length", "0"),
            ("Connection", "close"),
        ])
        let head = HTTPResponseHead(version: .init(major: 1, minor: 1), status: .ok, headers: headers)

        context.write(self.wrapOutboundOut(.head(head)), promise: nil)
        context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
    }
}

struct EventLoopFutureTimeoutError: Error {}

extension EventLoopFuture {
    func timeout(after failDelay: TimeAmount) -> EventLoopFuture<Value> {
        let promise = self.eventLoop.makePromise(of: Value.self)

        self.whenComplete { result in
            switch result {
            case .success(let value):
                promise.succeed(value)
            case .failure(let error):
                promise.fail(error)
            }
        }

        self.eventLoop.scheduleTask(in: failDelay) {
            promise.fail(EventLoopFutureTimeoutError())
        }

        return promise.futureResult
    }
}

struct CollectEverythingLogHandler: LogHandler {
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .info
    let logStore: LogStore

    class LogStore {
        struct Entry {
            var level: Logger.Level
            var message: String
            var metadata: [String: String]
        }

        var lock = Lock()
        var logs: [Entry] = []

        var allEntries: [Entry] {
            get {
                return self.lock.withLock { self.logs }
            }
            set {
                self.lock.withLock { self.logs = newValue }
            }
        }

        func append(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?) {
            self.lock.withLock {
                self.logs.append(Entry(level: level,
                                       message: message.description,
                                       metadata: metadata?.mapValues { $0.description } ?? [:]))
            }
        }
    }

    init(logStore: LogStore) {
        self.logStore = logStore
    }

    func log(level: Logger.Level,
             message: Logger.Message,
             metadata: Logger.Metadata?,
             file: String, function: String, line: UInt) {
        self.logStore.append(level: level, message: message, metadata: self.metadata.merging(metadata ?? [:]) { $1 })
    }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get {
            return self.metadata[key]
        }
        set {
            self.metadata[key] = newValue
        }
    }
}

/// A ``HTTPClientResponseDelegate`` that buffers the incoming response parts for the consumer. The consumer can
/// consume the bytes by calling ``next()`` on the delegate.
///
/// The sole purpose of this class is to enable straight-line stream tests.
class ResponseStreamDelegate: HTTPClientResponseDelegate {
    typealias Response = Void

    enum State {
        /// The delegate is in the idle state. There are no http response parts to be buffered
        /// and the consumer did not signal a demand. Transitions to all other states are allowed.
        case idle
        /// The consumer has signaled a demand for more bytes, but none where available. Can
        /// transition to `.idle` (when new bytes arrive), `.finished` (when the stream finishes or fails)
        case waitingForBytes(EventLoopPromise<ByteBuffer?>)
        /// The consumer has signaled no further demand but bytes keep arriving. Valid transitions
        /// to `.idle` (when bytes are consumed), `.finished` (when bytes are consumed, and the
        /// stream has ended), `.failed` (if an error is forwarded)
        case buffering(ByteBuffer, done: Bool)
        /// Stores an error for consumption. Valid transitions are: `.finished`, when the error was consumed.
        case failed(Error)
        /// The stream has finished and all bytes or errors where consumed.
        case finished
    }

    let eventLoop: EventLoop
    private var state: State = .idle

    init(eventLoop: EventLoop) {
        self.eventLoop = eventLoop
    }

    func next() -> EventLoopFuture<ByteBuffer?> {
        if self.eventLoop.inEventLoop {
            return self.next0()
        } else {
            return self.eventLoop.flatSubmit {
                self.next0()
            }
        }
    }

    private func next0() -> EventLoopFuture<ByteBuffer?> {
        switch self.state {
        case .idle:
            let promise = self.eventLoop.makePromise(of: ByteBuffer?.self)
            self.state = .waitingForBytes(promise)
            return promise.futureResult

        case .buffering(let byteBuffer, done: false):
            self.state = .idle
            return self.eventLoop.makeSucceededFuture(byteBuffer)

        case .buffering(let byteBuffer, done: true):
            self.state = .finished
            return self.eventLoop.makeSucceededFuture(byteBuffer)

        case .waitingForBytes:
            preconditionFailure("Don't call `.next` twice")

        case .failed(let error):
            self.state = .finished
            return self.eventLoop.makeFailedFuture(error)

        case .finished:
            return self.eventLoop.makeSucceededFuture(nil)
        }
    }

    // MARK: HTTPClientResponseDelegate

    func didSendRequestHead(task: HTTPClient.Task<Response>, _ head: HTTPRequestHead) {
        self.eventLoop.preconditionInEventLoop()
    }

    func didSendRequestPart(task: HTTPClient.Task<Response>, _ part: IOData) {
        self.eventLoop.preconditionInEventLoop()
    }

    func didSendRequest(task: HTTPClient.Task<Response>) {
        self.eventLoop.preconditionInEventLoop()
    }

    func didReceiveHead(task: HTTPClient.Task<Response>, _ head: HTTPResponseHead) -> EventLoopFuture<Void> {
        self.eventLoop.preconditionInEventLoop()
        return task.eventLoop.makeSucceededVoidFuture()
    }

    func didReceiveBodyPart(task: HTTPClient.Task<Response>, _ buffer: ByteBuffer) -> EventLoopFuture<Void> {
        self.eventLoop.preconditionInEventLoop()

        switch self.state {
        case .idle:
            self.state = .buffering(buffer, done: false)
        case .waitingForBytes(let promise):
            self.state = .idle
            promise.succeed(buffer)
        case .buffering(var byteBuffer, done: false):
            var buffer = buffer
            byteBuffer.writeBuffer(&buffer)
            self.state = .buffering(byteBuffer, done: false)
        case .buffering(_, done: true), .finished, .failed:
            preconditionFailure("Invalid state: \(self.state)")
        }

        return task.eventLoop.makeSucceededVoidFuture()
    }

    func didReceiveError(task: HTTPClient.Task<Response>, _ error: Error) {
        self.eventLoop.preconditionInEventLoop()

        switch self.state {
        case .idle:
            self.state = .failed(error)
        case .waitingForBytes(let promise):
            self.state = .finished
            promise.fail(error)
        case .buffering(_, done: false):
            self.state = .failed(error)
        case .buffering(_, done: true), .finished, .failed:
            preconditionFailure("Invalid state: \(self.state)")
        }
    }

    func didFinishRequest(task: HTTPClient.Task<Response>) throws {
        self.eventLoop.preconditionInEventLoop()

        switch self.state {
        case .idle:
            self.state = .finished
        case .waitingForBytes(let promise):
            self.state = .finished
            promise.succeed(nil)
        case .buffering(let byteBuffer, done: false):
            self.state = .buffering(byteBuffer, done: true)
        case .buffering(_, done: true), .finished, .failed:
            preconditionFailure("Invalid state: \(self.state)")
        }
    }
}

class HTTPEchoHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let request = self.unwrapInboundIn(data)
        switch request {
        case .head(let requestHead):
            context.writeAndFlush(self.wrapOutboundOut(.head(.init(version: .http1_1, status: .ok, headers: requestHead.headers))), promise: nil)
        case .body(let bytes):
            context.writeAndFlush(self.wrapOutboundOut(.body(.byteBuffer(bytes))), promise: nil)
        case .end:
            context.writeAndFlush(self.wrapOutboundOut(.end(nil))).whenSuccess {
                context.close(promise: nil)
            }
        }
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
