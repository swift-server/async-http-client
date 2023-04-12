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

@testable import AsyncHTTPClient
import Logging
import NIOCore
import NIOPosix
import NIOSSL
import XCTest

private func makeDefaultHTTPClient(
    eventLoopGroupProvider: HTTPClient.EventLoopGroupProvider = .createNew
) -> HTTPClient {
    var config = HTTPClient.Configuration()
    config.tlsConfiguration = .clientDefault
    config.tlsConfiguration?.certificateVerification = .none
    config.httpVersion = .automatic
    return HTTPClient(
        eventLoopGroupProvider: eventLoopGroupProvider,
        configuration: config,
        backgroundActivityLogger: Logger(label: "HTTPClient", factory: StreamLogHandler.standardOutput(label:))
    )
}

final class AsyncAwaitEndToEndTests: XCTestCase {
    var clientGroup: EventLoopGroup!
    var serverGroup: EventLoopGroup!

    override func setUp() {
        XCTAssertNil(self.clientGroup)
        XCTAssertNil(self.serverGroup)

        self.clientGroup = getDefaultEventLoopGroup(numberOfThreads: 1)
        self.serverGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    override func tearDown() {
        XCTAssertNotNil(self.clientGroup)
        XCTAssertNoThrow(try self.clientGroup.syncShutdownGracefully())
        self.clientGroup = nil

        XCTAssertNotNil(self.serverGroup)
        XCTAssertNoThrow(try self.serverGroup.syncShutdownGracefully())
        self.serverGroup = nil
    }

    func testSimpleGet() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest {
            let bin = HTTPBin(.http2(compress: false))
            defer { XCTAssertNoThrow(try bin.shutdown()) }
            let client = makeDefaultHTTPClient()
            defer { XCTAssertNoThrow(try client.syncShutdown()) }
            let logger = Logger(label: "HTTPClient", factory: StreamLogHandler.standardOutput(label:))
            let request = HTTPClientRequest(url: "https://localhost:\(bin.port)/get")

            guard let response = await XCTAssertNoThrowWithResult(
                try await client.execute(request, deadline: .now() + .seconds(10), logger: logger)
            ) else {
                return
            }

            XCTAssertEqual(response.status, .ok)
            XCTAssertEqual(response.version, .http2)
        }
    }

    func testSimplePost() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest {
            let bin = HTTPBin(.http2(compress: false))
            defer { XCTAssertNoThrow(try bin.shutdown()) }
            let client = makeDefaultHTTPClient()
            defer { XCTAssertNoThrow(try client.syncShutdown()) }
            let logger = Logger(label: "HTTPClient", factory: StreamLogHandler.standardOutput(label:))
            let request = HTTPClientRequest(url: "https://localhost:\(bin.port)/get")

            guard let response = await XCTAssertNoThrowWithResult(
                try await client.execute(request, deadline: .now() + .seconds(10), logger: logger)
            ) else {
                return
            }

            XCTAssertEqual(response.status, .ok)
            XCTAssertEqual(response.version, .http2)
        }
    }

    func testPostWithByteBuffer() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest {
            let bin = HTTPBin(.http2(compress: false)) { _ in HTTPEchoHandler() }
            defer { XCTAssertNoThrow(try bin.shutdown()) }
            let client = makeDefaultHTTPClient()
            defer { XCTAssertNoThrow(try client.syncShutdown()) }
            let logger = Logger(label: "HTTPClient", factory: StreamLogHandler.standardOutput(label:))
            var request = HTTPClientRequest(url: "https://localhost:\(bin.port)/")
            request.method = .POST
            request.body = .bytes(ByteBuffer(string: "1234"))

            guard let response = await XCTAssertNoThrowWithResult(
                try await client.execute(request, deadline: .now() + .seconds(10), logger: logger)
            ) else { return }
            XCTAssertEqual(response.headers["content-length"], ["4"])
            guard let body = await XCTAssertNoThrowWithResult(
                try await response.body.collect(upTo: 1024)
            ) else { return }
            XCTAssertEqual(body, ByteBuffer(string: "1234"))
        }
    }

    func testPostWithSequenceOfUInt8() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest {
            let bin = HTTPBin(.http2(compress: false)) { _ in HTTPEchoHandler() }
            defer { XCTAssertNoThrow(try bin.shutdown()) }
            let client = makeDefaultHTTPClient()
            defer { XCTAssertNoThrow(try client.syncShutdown()) }
            let logger = Logger(label: "HTTPClient", factory: StreamLogHandler.standardOutput(label:))
            var request = HTTPClientRequest(url: "https://localhost:\(bin.port)/")
            request.method = .POST
            request.body = .bytes(AnySendableSequence("1234".utf8), length: .unknown)

            guard let response = await XCTAssertNoThrowWithResult(
                try await client.execute(request, deadline: .now() + .seconds(10), logger: logger)
            ) else { return }
            XCTAssertEqual(response.headers["content-length"], [])
            guard let body = await XCTAssertNoThrowWithResult(
                try await response.body.collect(upTo: 1024)
            ) else { return }
            XCTAssertEqual(body, ByteBuffer(string: "1234"))
        }
    }

    func testPostWithCollectionOfUInt8() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest {
            let bin = HTTPBin(.http2(compress: false)) { _ in HTTPEchoHandler() }
            defer { XCTAssertNoThrow(try bin.shutdown()) }
            let client = makeDefaultHTTPClient()
            defer { XCTAssertNoThrow(try client.syncShutdown()) }
            let logger = Logger(label: "HTTPClient", factory: StreamLogHandler.standardOutput(label:))
            var request = HTTPClientRequest(url: "https://localhost:\(bin.port)/")
            request.method = .POST
            request.body = .bytes(AnySendableCollection("1234".utf8), length: .unknown)

            guard let response = await XCTAssertNoThrowWithResult(
                try await client.execute(request, deadline: .now() + .seconds(10), logger: logger)
            ) else { return }
            XCTAssertEqual(response.headers["content-length"], [])
            guard let body = await XCTAssertNoThrowWithResult(
                try await response.body.collect(upTo: 1024)
            ) else { return }
            XCTAssertEqual(body, ByteBuffer(string: "1234"))
        }
    }

    func testPostWithRandomAccessCollectionOfUInt8() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest {
            let bin = HTTPBin(.http2(compress: false)) { _ in HTTPEchoHandler() }
            defer { XCTAssertNoThrow(try bin.shutdown()) }
            let client = makeDefaultHTTPClient()
            defer { XCTAssertNoThrow(try client.syncShutdown()) }
            let logger = Logger(label: "HTTPClient", factory: StreamLogHandler.standardOutput(label:))
            var request = HTTPClientRequest(url: "https://localhost:\(bin.port)/")
            request.method = .POST
            request.body = .bytes(ByteBuffer(string: "1234").readableBytesView)

            guard let response = await XCTAssertNoThrowWithResult(
                try await client.execute(request, deadline: .now() + .seconds(10), logger: logger)
            ) else { return }
            XCTAssertEqual(response.headers["content-length"], ["4"])
            guard let body = await XCTAssertNoThrowWithResult(
                try await response.body.collect(upTo: 1024)
            ) else { return }
            XCTAssertEqual(body, ByteBuffer(string: "1234"))
        }
    }

    func testPostWithAsyncSequenceOfByteBuffers() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest {
            let bin = HTTPBin(.http2(compress: false)) { _ in HTTPEchoHandler() }
            defer { XCTAssertNoThrow(try bin.shutdown()) }
            let client = makeDefaultHTTPClient()
            defer { XCTAssertNoThrow(try client.syncShutdown()) }
            let logger = Logger(label: "HTTPClient", factory: StreamLogHandler.standardOutput(label:))
            var request = HTTPClientRequest(url: "https://localhost:\(bin.port)/")
            request.method = .POST
            request.body = .stream([
                ByteBuffer(string: "1"),
                ByteBuffer(string: "2"),
                ByteBuffer(string: "34"),
            ].async, length: .unknown)

            guard let response = await XCTAssertNoThrowWithResult(
                try await client.execute(request, deadline: .now() + .seconds(10), logger: logger)
            ) else { return }
            XCTAssertEqual(response.headers["content-length"], [])
            guard let body = await XCTAssertNoThrowWithResult(
                try await response.body.collect(upTo: 1024)
            ) else { return }
            XCTAssertEqual(body, ByteBuffer(string: "1234"))
        }
    }

    func testPostWithAsyncSequenceOfUInt8() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest {
            let bin = HTTPBin(.http2(compress: false)) { _ in HTTPEchoHandler() }
            defer { XCTAssertNoThrow(try bin.shutdown()) }
            let client = makeDefaultHTTPClient()
            defer { XCTAssertNoThrow(try client.syncShutdown()) }
            let logger = Logger(label: "HTTPClient", factory: StreamLogHandler.standardOutput(label:))
            var request = HTTPClientRequest(url: "https://localhost:\(bin.port)/")
            request.method = .POST
            request.body = .stream("1234".utf8.async, length: .unknown)

            guard let response = await XCTAssertNoThrowWithResult(
                try await client.execute(request, deadline: .now() + .seconds(10), logger: logger)
            ) else { return }
            XCTAssertEqual(response.headers["content-length"], [])
            guard let body = await XCTAssertNoThrowWithResult(
                try await response.body.collect(upTo: 1024)
            ) else { return }
            XCTAssertEqual(body, ByteBuffer(string: "1234"))
        }
    }

    func testPostWithFragmentedAsyncSequenceOfByteBuffers() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest {
            let bin = HTTPBin(.http2(compress: false)) { _ in HTTPEchoHandler() }
            defer { XCTAssertNoThrow(try bin.shutdown()) }
            let client = makeDefaultHTTPClient()
            defer { XCTAssertNoThrow(try client.syncShutdown()) }
            let logger = Logger(label: "HTTPClient", factory: StreamLogHandler.standardOutput(label:))
            var request = HTTPClientRequest(url: "https://localhost:\(bin.port)/")
            request.method = .POST
            let streamWriter = AsyncSequenceWriter<ByteBuffer>()
            request.body = .stream(streamWriter, length: .unknown)

            guard let response = await XCTAssertNoThrowWithResult(
                try await client.execute(request, deadline: .now() + .seconds(10), logger: logger)
            ) else { return }
            XCTAssertEqual(response.headers["content-length"], [])

            let fragments = [
                ByteBuffer(string: "1"),
                ByteBuffer(string: "2"),
                ByteBuffer(string: "34"),
            ]
            var bodyIterator = response.body.makeAsyncIterator()
            for expectedFragment in fragments {
                streamWriter.write(expectedFragment)
                guard let actualFragment = await XCTAssertNoThrowWithResult(
                    try await bodyIterator.next()
                ) else { return }
                XCTAssertEqual(expectedFragment, actualFragment)
            }

            streamWriter.end()
            guard let lastResult = await XCTAssertNoThrowWithResult(
                try await bodyIterator.next()
            ) else { return }
            XCTAssertEqual(lastResult, nil)
        }
    }

    func testPostWithFragmentedAsyncSequenceOfLargeByteBuffers() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest {
            let bin = HTTPBin(.http2(compress: false)) { _ in HTTPEchoHandler() }
            defer { XCTAssertNoThrow(try bin.shutdown()) }
            let client = makeDefaultHTTPClient()
            defer { XCTAssertNoThrow(try client.syncShutdown()) }
            let logger = Logger(label: "HTTPClient", factory: StreamLogHandler.standardOutput(label:))
            var request = HTTPClientRequest(url: "https://localhost:\(bin.port)/")
            request.method = .POST
            let streamWriter = AsyncSequenceWriter<ByteBuffer>()
            request.body = .stream(streamWriter, length: .unknown)

            guard let response = await XCTAssertNoThrowWithResult(
                try await client.execute(request, deadline: .now() + .seconds(10), logger: logger)
            ) else { return }
            XCTAssertEqual(response.headers["content-length"], [])

            let fragments = [
                ByteBuffer(string: String(repeating: "a", count: 4000)),
                ByteBuffer(string: String(repeating: "b", count: 4000)),
                ByteBuffer(string: String(repeating: "c", count: 4000)),
                ByteBuffer(string: String(repeating: "d", count: 4000)),
            ]
            var bodyIterator = response.body.makeAsyncIterator()
            for expectedFragment in fragments {
                streamWriter.write(expectedFragment)
                guard let actualFragment = await XCTAssertNoThrowWithResult(
                    try await bodyIterator.next()
                ) else { return }
                XCTAssertEqual(expectedFragment, actualFragment)
            }

            streamWriter.end()
            guard let lastResult = await XCTAssertNoThrowWithResult(
                try await bodyIterator.next()
            ) else { return }
            XCTAssertEqual(lastResult, nil)
        }
    }

    func testCanceling() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest(timeout: 5) {
            let bin = HTTPBin(.http2(compress: false))
            defer { XCTAssertNoThrow(try bin.shutdown()) }
            let client = makeDefaultHTTPClient()
            defer { XCTAssertNoThrow(try client.syncShutdown()) }
            let logger = Logger(label: "HTTPClient", factory: StreamLogHandler.standardOutput(label:))
            var request = HTTPClientRequest(url: "http://localhost:\(bin.port)/offline")
            request.method = .POST
            let streamWriter = AsyncSequenceWriter<ByteBuffer>()
            request.body = .stream(streamWriter, length: .unknown)

            let task = Task<HTTPClientResponse, Error> { [request] in
                try await client.execute(request, deadline: .now() + .seconds(2), logger: logger)
            }
            task.cancel()
            await XCTAssertThrowsError(try await task.value) { error in
                XCTAssertTrue(error is CancellationError, "unexpected error \(error)")
            }
        }
    }

    func testCancelingResponseBody() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest(timeout: 5) {
            let bin = HTTPBin(.http2(compress: false)) { _ in
                HTTPEchoHandler()
            }
            defer { XCTAssertNoThrow(try bin.shutdown()) }
            let client = makeDefaultHTTPClient()
            defer { XCTAssertNoThrow(try client.syncShutdown()) }
            let logger = Logger(label: "HTTPClient", factory: StreamLogHandler.standardOutput(label:))
            var request = HTTPClientRequest(url: "https://localhost:\(bin.port)/handler")
            request.method = .POST
            let streamWriter = AsyncSequenceWriter<ByteBuffer>()
            request.body = .stream(streamWriter, length: .unknown)
            let response = try await client.execute(request, deadline: .now() + .seconds(2), logger: logger)
            streamWriter.write(.init(bytes: [1]))
            let task = Task<ByteBuffer, Error> {
                try await response.body.collect(upTo: 1024 * 1024)
            }
            task.cancel()

            await XCTAssertThrowsError(try await task.value) { error in
                XCTAssertTrue(error is CancellationError, "unexpected error \(error)")
            }

            streamWriter.end()
        }
    }

    func testDeadline() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest(timeout: 5) {
            let bin = HTTPBin(.http2(compress: false))
            defer { XCTAssertNoThrow(try bin.shutdown()) }
            let client = makeDefaultHTTPClient()
            defer { XCTAssertNoThrow(try client.syncShutdown()) }
            let logger = Logger(label: "HTTPClient", factory: StreamLogHandler.standardOutput(label:))
            let request = HTTPClientRequest(url: "https://localhost:\(bin.port)/wait")

            let task = Task<HTTPClientResponse, Error> { [request] in
                try await client.execute(request, deadline: .now() + .milliseconds(100), logger: logger)
            }
            await XCTAssertThrowsError(try await task.value) { error in
                guard let error = error as? HTTPClientError else {
                    return XCTFail("unexpected error \(error)")
                }
                // a race between deadline and connect timer can result in either error
                XCTAssertTrue([.deadlineExceeded, .connectTimeout].contains(error))
            }
        }
    }

    func testImmediateDeadline() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest(timeout: 5) {
            let bin = HTTPBin(.http2(compress: false))
            defer { XCTAssertNoThrow(try bin.shutdown()) }
            let client = makeDefaultHTTPClient()
            defer { XCTAssertNoThrow(try client.syncShutdown()) }
            let logger = Logger(label: "HTTPClient", factory: StreamLogHandler.standardOutput(label:))
            let request = HTTPClientRequest(url: "http://localhost:\(bin.port)/wait")

            let task = Task<HTTPClientResponse, Error> { [request] in
                try await client.execute(request, deadline: .now(), logger: logger)
            }
            await XCTAssertThrowsError(try await task.value) { error in
                guard let error = error as? HTTPClientError else {
                    return XCTFail("unexpected error \(error)")
                }
                // a race between deadline and connect timer can result in either error
                XCTAssertTrue([.deadlineExceeded, .connectTimeout].contains(error), "unexpected error \(error)")
            }
        }
    }

    func testConnectTimeout() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest(timeout: 60) {
            #if os(Linux)
            // 198.51.100.254 is reserved for documentation only and therefore should not accept any TCP connection
            let url = "http://198.51.100.254/get"
            #else
            // on macOS we can use the TCP backlog behaviour when the queue is full to simulate a non reachable server.
            // this makes this test a bit more stable if `198.51.100.254` actually responds to connection attempt.
            // The backlog behaviour on Linux can not be used to simulate a non-reachable server.
            // Linux sends a `SYN/ACK` back even if the `backlog` queue is full as it has two queues.
            // The second queue is not limit by `ChannelOptions.backlog` but by `/proc/sys/net/ipv4/tcp_max_syn_backlog`.

            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            defer {
                XCTAssertNoThrow(try group.syncShutdownGracefully())
            }

            let serverChannel = try await ServerBootstrap(group: self.serverGroup)
                .serverChannelOption(ChannelOptions.backlog, value: 1)
                .serverChannelOption(ChannelOptions.autoRead, value: false)
                .bind(host: "127.0.0.1", port: 0)
                .get()
            defer {
                XCTAssertNoThrow(try serverChannel.close().wait())
            }
            let port = serverChannel.localAddress!.port!
            let firstClientChannel = try await ClientBootstrap(group: self.serverGroup)
                .connect(host: "127.0.0.1", port: port)
                .get()
            defer {
                XCTAssertNoThrow(try firstClientChannel.close().wait())
            }
            let url = "http://localhost:\(port)/get"
            #endif

            let httpClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup),
                                        configuration: .init(timeout: .init(connect: .milliseconds(100), read: .milliseconds(150))))

            defer {
                XCTAssertNoThrow(try httpClient.syncShutdown())
            }

            let request = HTTPClientRequest(url: url)
            let start = NIODeadline.now()
            await XCTAssertThrowsError(try await httpClient.execute(request, deadline: .now() + .seconds(30))) {
                XCTAssertEqualTypeAndValue($0, HTTPClientError.connectTimeout)
                let end = NIODeadline.now()
                let duration = end - start

                // We give ourselves 10x slack in order to be confident that even on slow machines this assertion passes.
                // It's 30x smaller than our other timeout though.
                XCTAssertLessThan(duration, .seconds(1))
            }
        }
    }

    func testSelfSignedCertificateIsRejectedWithCorrectErrorIfRequestDeadlineIsExceeded() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest(timeout: 5) {
            /// key + cert was created with the follwing command:
            /// openssl req -x509 -newkey rsa:4096 -keyout self_signed_key.pem -out self_signed_cert.pem -sha256 -days 99999 -nodes -subj '/CN=localhost'
            let certPath = Bundle.module.path(forResource: "self_signed_cert", ofType: "pem")!
            let keyPath = Bundle.module.path(forResource: "self_signed_key", ofType: "pem")!
            let configuration = TLSConfiguration.makeServerConfiguration(
                certificateChain: try NIOSSLCertificate.fromPEMFile(certPath).map { .certificate($0) },
                privateKey: .file(keyPath)
            )
            let sslContext = try NIOSSLContext(configuration: configuration)
            let serverGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            defer { XCTAssertNoThrow(try serverGroup.syncShutdownGracefully()) }
            let server = ServerBootstrap(group: serverGroup)
                .childChannelInitializer { channel in
                    channel.pipeline.addHandler(NIOSSLServerHandler(context: sslContext))
                }
            let serverChannel = try await server.bind(host: "localhost", port: 0).get()
            defer { XCTAssertNoThrow(try serverChannel.close().wait()) }
            let port = serverChannel.localAddress!.port!

            let config = HTTPClient.Configuration()
                .enableFastFailureModeForTesting()

            let localClient = HTTPClient(eventLoopGroupProvider: .createNew, configuration: config)
            defer { XCTAssertNoThrow(try localClient.syncShutdown()) }
            let request = HTTPClientRequest(url: "https://localhost:\(port)")
            await XCTAssertThrowsError(try await localClient.execute(request, deadline: .now() + .seconds(2))) { error in
                #if canImport(Network)
                guard let nwTLSError = error as? HTTPClient.NWTLSError else {
                    XCTFail("could not cast \(error) of type \(type(of: error)) to \(HTTPClient.NWTLSError.self)")
                    return
                }
                XCTAssertEqual(nwTLSError.status, errSSLBadCert, "unexpected tls error: \(nwTLSError)")
                #else
                guard let sslError = error as? NIOSSLError,
                      case .handshakeFailed(.sslError) = sslError else {
                    XCTFail("unexpected error \(error)")
                    return
                }
                #endif
            }
        }
    }

    func testDnsOverride() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest(timeout: 5) {
            /// key + cert was created with the following code (depends on swift-certificates)
            /// ```
            /// let privateKey = P384.Signing.PrivateKey()
            /// let name = try DistinguishedName {
            ///     OrganizationName("Self Signed")
            ///     CommonName("localhost")
            /// }
            /// let certificate = try Certificate(
            ///     version: .v3,
            ///     serialNumber: .init(),
            ///     publicKey: .init(privateKey.publicKey),
            ///     notValidBefore: Date(),
            ///     notValidAfter: Date() + .days(365),
            ///     issuer: name,
            ///     subject: name,
            ///     signatureAlgorithm: .ecdsaWithSHA384,
            ///     extensions: try .init {
            ///         SubjectAlternativeNames([.dnsName("example.com")])
            ///         ExtendedKeyUsage([.serverAuth])
            ///     },
            ///     issuerPrivateKey: .init(privateKey)
            /// )
            /// ```
            let certPath = Bundle.module.path(forResource: "example.com.cert", ofType: "pem")!
            let keyPath = Bundle.module.path(forResource: "example.com.private-key", ofType: "pem")!
            let localhostCert = try NIOSSLCertificate.fromPEMFile(certPath)
            let configuration = TLSConfiguration.makeServerConfiguration(
                certificateChain: localhostCert.map { .certificate($0) },
                privateKey: .file(keyPath)
            )
            let bin = HTTPBin(.http2(tlsConfiguration: configuration))
            defer { XCTAssertNoThrow(try bin.shutdown()) }

            var config = HTTPClient.Configuration()
                .enableFastFailureModeForTesting()
            var tlsConfig = TLSConfiguration.makeClientConfiguration()

            tlsConfig.trustRoots = .certificates(localhostCert)
            config.tlsConfiguration = tlsConfig
            // this is the actual configuration under test
            config.dnsOverride = ["example.com": "localhost"]

            let localClient = HTTPClient(eventLoopGroupProvider: .createNew, configuration: config)
            defer { XCTAssertNoThrow(try localClient.syncShutdown()) }
            let request = HTTPClientRequest(url: "https://example.com:\(bin.port)/echohostheader")
            let response = await XCTAssertNoThrowWithResult(try await localClient.execute(request, deadline: .now() + .seconds(2)))
            XCTAssertEqual(response?.status, .ok)
            XCTAssertEqual(response?.version, .http2)
            var body = try await response?.body.collect(upTo: 1024)
            let readableBytes = body?.readableBytes ?? 0
            let responseInfo = try body?.readJSONDecodable(RequestInfo.self, length: readableBytes)
            XCTAssertEqual(responseInfo?.data, "example.com\(bin.port == 443 ? "" : ":\(bin.port)")")
        }
    }

    func testInvalidURL() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest(timeout: 5) {
            let client = makeDefaultHTTPClient()
            defer { XCTAssertNoThrow(try client.syncShutdown()) }
            let logger = Logger(label: "HTTPClient", factory: StreamLogHandler.standardOutput(label:))
            let request = HTTPClientRequest(url: "") // invalid URL

            await XCTAssertThrowsError(try await client.execute(request, deadline: .now() + .seconds(2), logger: logger)) {
                XCTAssertEqual($0 as? HTTPClientError, .invalidURL)
            }
        }
    }

    func testRedirectChangesHostHeader() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest {
            let bin = HTTPBin(.http2(compress: false))
            defer { XCTAssertNoThrow(try bin.shutdown()) }
            let client = makeDefaultHTTPClient()
            defer { XCTAssertNoThrow(try client.syncShutdown()) }
            let logger = Logger(label: "HTTPClient", factory: StreamLogHandler.standardOutput(label:))
            var request = HTTPClientRequest(url: "https://127.0.0.1:\(bin.port)/redirect/target")
            request.headers.replaceOrAdd(name: "X-Target-Redirect-URL", value: "https://localhost:\(bin.port)/echohostheader")

            guard let response = await XCTAssertNoThrowWithResult(
                try await client.execute(request, deadline: .now() + .seconds(10), logger: logger)
            ) else {
                return
            }
            guard let body = await XCTAssertNoThrowWithResult(try await response.body.collect(upTo: 1024)) else { return }
            var maybeRequestInfo: RequestInfo?
            XCTAssertNoThrow(maybeRequestInfo = try JSONDecoder().decode(RequestInfo.self, from: body))
            guard let requestInfo = maybeRequestInfo else { return }

            XCTAssertEqual(response.status, .ok)
            XCTAssertEqual(response.version, .http2)
            XCTAssertEqual(requestInfo.data, "localhost:\(bin.port)")
        }
    }

    func testShutdown() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest {
            let client = makeDefaultHTTPClient()
            try await client.shutdown()
            await XCTAssertThrowsError(try await client.shutdown()) { error in
                XCTAssertEqualTypeAndValue(error, HTTPClientError.alreadyShutdown)
            }
        }
    }

    /// Regression test for https://github.com/swift-server/async-http-client/issues/612
    func testCancelingBodyDoesNotCrash() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest {
            let client = makeDefaultHTTPClient()
            defer { XCTAssertNoThrow(try client.syncShutdown()) }
            let bin = HTTPBin(.http2(compress: true))
            defer { XCTAssertNoThrow(try bin.shutdown()) }

            let request = HTTPClientRequest(url: "https://127.0.0.1:\(bin.port)/mega-chunked")
            let response = try await client.execute(request, deadline: .now() + .seconds(10))

            await XCTAssertThrowsError(try await response.body.collect(upTo: 100)) { error in
                XCTAssert(error is NIOTooManyBytesError)
            }
        }
    }

    func testAsyncSequenceReuse() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest {
            let bin = HTTPBin(.http2(compress: false)) { _ in HTTPEchoHandler() }
            defer { XCTAssertNoThrow(try bin.shutdown()) }
            let client = makeDefaultHTTPClient()
            defer { XCTAssertNoThrow(try client.syncShutdown()) }
            let logger = Logger(label: "HTTPClient", factory: StreamLogHandler.standardOutput(label:))
            var request = HTTPClientRequest(url: "https://localhost:\(bin.port)/")
            request.method = .POST
            request.body = .stream([
                ByteBuffer(string: "1"),
                ByteBuffer(string: "2"),
                ByteBuffer(string: "34"),
            ].async, length: .unknown)

            guard let response1 = await XCTAssertNoThrowWithResult(
                try await client.execute(request, deadline: .now() + .seconds(10), logger: logger)
            ) else { return }
            XCTAssertEqual(response1.headers["content-length"], [])
            guard let body = await XCTAssertNoThrowWithResult(
                try await response1.body.collect(upTo: 1024)
            ) else { return }
            XCTAssertEqual(body, ByteBuffer(string: "1234"))

            guard let response2 = await XCTAssertNoThrowWithResult(
                try await client.execute(request, deadline: .now() + .seconds(10), logger: logger)
            ) else { return }
            XCTAssertEqual(response2.headers["content-length"], [])
            guard let body = await XCTAssertNoThrowWithResult(
                try await response2.body.collect(upTo: 1024)
            ) else { return }
            XCTAssertEqual(body, ByteBuffer(string: "1234"))
        }
    }

    func testRejectsInvalidCharactersInHeaderFieldNames_http1() {
        self._rejectsInvalidCharactersInHeaderFieldNames(mode: .http1_1(ssl: true))
    }

    func testRejectsInvalidCharactersInHeaderFieldNames_http2() {
        self._rejectsInvalidCharactersInHeaderFieldNames(mode: .http2(compress: false))
    }

    private func _rejectsInvalidCharactersInHeaderFieldNames(mode: HTTPBin<HTTPBinHandler>.Mode) {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest {
            let bin = HTTPBin(mode)
            defer { XCTAssertNoThrow(try bin.shutdown()) }
            let client = makeDefaultHTTPClient()
            defer { XCTAssertNoThrow(try client.syncShutdown()) }
            let logger = Logger(label: "HTTPClient", factory: StreamLogHandler.standardOutput(label:))

            // The spec in [RFC 9110](https://httpwg.org/specs/rfc9110.html#fields.values) defines the valid
            // characters as the following:
            //
            // ```
            // field-name     = token
            //
            // token          = 1*tchar
            //
            // tchar          = "!" / "#" / "$" / "%" / "&" / "'" / "*"
            //                / "+" / "-" / "." / "^" / "_" / "`" / "|" / "~"
            //                / DIGIT / ALPHA
            //                ; any VCHAR, except delimiters
            let weirdAllowedFieldName = "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

            var request = HTTPClientRequest(url: "https://localhost:\(bin.port)/get")
            request.headers.add(name: weirdAllowedFieldName, value: "present")

            // This should work fine.
            guard let response = await XCTAssertNoThrowWithResult(
                try await client.execute(request, deadline: .now() + .seconds(10), logger: logger)
            ) else {
                return
            }

            XCTAssertEqual(response.status, .ok)

            // Now, let's confirm all other bytes are rejected. We want to stay within the ASCII space as the HTTPHeaders type will forbid anything else.
            for byte in UInt8(0)...UInt8(127) {
                // Skip bytes that we already believe are allowed.
                if weirdAllowedFieldName.utf8.contains(byte) {
                    continue
                }
                let forbiddenFieldName = weirdAllowedFieldName + String(decoding: [byte], as: UTF8.self)

                var request = HTTPClientRequest(url: "https://localhost:\(bin.port)/get")
                request.headers.add(name: forbiddenFieldName, value: "present")

                await XCTAssertThrowsError(try await client.execute(request, deadline: .now() + .seconds(10), logger: logger)) { error in
                    XCTAssertEqual(error as? HTTPClientError, .invalidHeaderFieldNames([forbiddenFieldName]))
                }
            }
        }
    }

    func testRejectsInvalidCharactersInHeaderFieldValues_http1() {
        self._rejectsInvalidCharactersInHeaderFieldValues(mode: .http1_1(ssl: true))
    }

    func testRejectsInvalidCharactersInHeaderFieldValues_http2() {
        self._rejectsInvalidCharactersInHeaderFieldValues(mode: .http2(compress: false))
    }

    private func _rejectsInvalidCharactersInHeaderFieldValues(mode: HTTPBin<HTTPBinHandler>.Mode) {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest {
            let bin = HTTPBin(mode)
            defer { XCTAssertNoThrow(try bin.shutdown()) }
            let client = makeDefaultHTTPClient()
            defer { XCTAssertNoThrow(try client.syncShutdown()) }
            let logger = Logger(label: "HTTPClient", factory: StreamLogHandler.standardOutput(label:))

            // We reject all ASCII control characters except HTAB and tolerate everything else.
            let weirdAllowedFieldValue = "!\" \t#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~"

            var request = HTTPClientRequest(url: "https://localhost:\(bin.port)/get")
            request.headers.add(name: "Weird-Value", value: weirdAllowedFieldValue)

            // This should work fine.
            guard let response = await XCTAssertNoThrowWithResult(
                try await client.execute(request, deadline: .now() + .seconds(10), logger: logger)
            ) else {
                return
            }

            XCTAssertEqual(response.status, .ok)

            // Now, let's confirm all other bytes in the ASCII range ar rejected
            for byte in UInt8(0)...UInt8(127) {
                // Skip bytes that we already believe are allowed.
                if weirdAllowedFieldValue.utf8.contains(byte) {
                    continue
                }
                let forbiddenFieldValue = weirdAllowedFieldValue + String(decoding: [byte], as: UTF8.self)

                var request = HTTPClientRequest(url: "https://localhost:\(bin.port)/get")
                request.headers.add(name: "Weird-Value", value: forbiddenFieldValue)

                await XCTAssertThrowsError(try await client.execute(request, deadline: .now() + .seconds(10), logger: logger)) { error in
                    XCTAssertEqual(error as? HTTPClientError, .invalidHeaderFieldValues([forbiddenFieldValue]))
                }
            }

            // All the bytes outside the ASCII range are fine though.
            for byte in UInt8(128)...UInt8(255) {
                let evenWeirderAllowedValue = weirdAllowedFieldValue + String(decoding: [byte], as: UTF8.self)

                var request = HTTPClientRequest(url: "https://localhost:\(bin.port)/get")
                request.headers.add(name: "Weird-Value", value: evenWeirderAllowedValue)

                // This should work fine.
                guard let response = await XCTAssertNoThrowWithResult(
                    try await client.execute(request, deadline: .now() + .seconds(10), logger: logger)
                ) else {
                    return
                }

                XCTAssertEqual(response.status, .ok)
            }
        }
    }

    func testUsingGetMethodInsteadOfWait() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest {
            let bin = HTTPBin(.http2(compress: false))
            defer { XCTAssertNoThrow(try bin.shutdown()) }
            let client = makeDefaultHTTPClient()
            defer { XCTAssertNoThrow(try client.syncShutdown()) }
            let request = try HTTPClient.Request(url: "https://localhost:\(bin.port)/get")

            guard let response = await XCTAssertNoThrowWithResult(
                try await client.execute(request: request).get()
            ) else {
                return
            }

            XCTAssertEqual(response.status, .ok)
            XCTAssertEqual(response.version, .http2)
        }
    }

    func testSimpleContentLengthErrorNoBody() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest {
            let bin = HTTPBin(.http2(compress: false))
            defer { XCTAssertNoThrow(try bin.shutdown()) }
            let client = makeDefaultHTTPClient()
            defer { XCTAssertNoThrow(try client.syncShutdown()) }
            let logger = Logger(label: "HTTPClient", factory: StreamLogHandler.standardOutput(label:))
            let request = HTTPClientRequest(url: "https://localhost:\(bin.port)/content-length-without-body")
            guard let response = await XCTAssertNoThrowWithResult(
                try await client.execute(request, deadline: .now() + .seconds(10), logger: logger)
            ) else { return }
            await XCTAssertThrowsError(
                try await response.body.collect(upTo: 3)
            ) {
                XCTAssertEqualTypeAndValue($0, NIOTooManyBytesError())
            }
        }
    }
}

struct AnySendableSequence<Element>: @unchecked Sendable {
    private let wrapped: AnySequence<Element>
    init<WrappedSequence: Sequence & Sendable>(
        _ sequence: WrappedSequence
    ) where WrappedSequence.Element == Element {
        self.wrapped = .init(sequence)
    }
}

extension AnySendableSequence: Sequence {
    func makeIterator() -> AnySequence<Element>.Iterator {
        self.wrapped.makeIterator()
    }
}

struct AnySendableCollection<Element>: @unchecked Sendable {
    private let wrapped: AnyCollection<Element>
    init<WrappedCollection: Collection & Sendable>(
        _ collection: WrappedCollection
    ) where WrappedCollection.Element == Element {
        self.wrapped = .init(collection)
    }
}

extension AnySendableCollection: Collection {
    var startIndex: AnyCollection<Element>.Index {
        self.wrapped.startIndex
    }

    var endIndex: AnyCollection<Element>.Index {
        self.wrapped.endIndex
    }

    func index(after i: AnyIndex) -> AnyIndex {
        self.wrapped.index(after: i)
    }

    subscript(position: AnyCollection<Element>.Index) -> Element {
        self.wrapped[position]
    }
}
