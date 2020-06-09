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

/* NOT @testable */ import AsyncHTTPClient // Tests that need @testable go into HTTPClientInternalTests.swift
#if canImport(Network)
    import Network
#endif
import Logging
import NIO
import NIOConcurrencyHelpers
import NIOFoundationCompat
import NIOHTTP1
import NIOHTTPCompression
import NIOSSL
import NIOTestUtils
import NIOTransportServices
import XCTest

class HTTPClientTests: XCTestCase {
    typealias Request = HTTPClient.Request

    var clientGroup: EventLoopGroup!
    var serverGroup: EventLoopGroup!
    var defaultHTTPBin: HTTPBin!
    var defaultClient: HTTPClient!
    var backgroundLogStore: CollectEverythingLogHandler.LogStore!

    var defaultHTTPBinURLPrefix: String {
        return "http://localhost:\(self.defaultHTTPBin.port)/"
    }

    override func setUp() {
        XCTAssertNil(self.clientGroup)
        XCTAssertNil(self.serverGroup)
        XCTAssertNil(self.defaultHTTPBin)
        XCTAssertNil(self.defaultClient)
        XCTAssertNil(self.backgroundLogStore)

        self.clientGroup = getDefaultEventLoopGroup(numberOfThreads: 1)
        self.serverGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.defaultHTTPBin = HTTPBin()
        self.backgroundLogStore = CollectEverythingLogHandler.LogStore()
        var backgroundLogger = Logger(label: "\(#function)", factory: { _ in
            CollectEverythingLogHandler(logStore: self.backgroundLogStore!)
        })
        backgroundLogger.logLevel = .trace
        self.defaultClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup),
                                        backgroundActivityLogger: backgroundLogger)
    }

    override func tearDown() {
        if let defaultClient = self.defaultClient {
            XCTAssertNoThrow(try defaultClient.syncShutdown())
            self.defaultClient = nil
        }

        XCTAssertNotNil(self.defaultHTTPBin)
        XCTAssertNoThrow(try self.defaultHTTPBin.shutdown())
        self.defaultHTTPBin = nil

        XCTAssertNotNil(self.clientGroup)
        XCTAssertNoThrow(try self.clientGroup.syncShutdownGracefully())
        self.clientGroup = nil

        XCTAssertNotNil(self.serverGroup)
        XCTAssertNoThrow(try self.serverGroup.syncShutdownGracefully())
        self.serverGroup = nil

        XCTAssertNotNil(self.backgroundLogStore)
        self.backgroundLogStore = nil
    }

    func testRequestURI() throws {
        let request1 = try Request(url: "https://someserver.com:8888/some/path?foo=bar")
        XCTAssertEqual(request1.url.host, "someserver.com")
        XCTAssertEqual(request1.url.path, "/some/path")
        XCTAssertEqual(request1.url.query!, "foo=bar")
        XCTAssertEqual(request1.port, 8888)
        XCTAssertTrue(request1.useTLS)

        let request2 = try Request(url: "https://someserver.com")
        XCTAssertEqual(request2.url.path, "")

        let request3 = try Request(url: "unix:///tmp/file")
        XCTAssertNil(request3.url.host)
        XCTAssertEqual(request3.host, "")
        XCTAssertEqual(request3.url.path, "/tmp/file")
        XCTAssertEqual(request3.port, 80)
        XCTAssertFalse(request3.useTLS)
    }

    func testBadRequestURI() throws {
        XCTAssertThrowsError(try Request(url: "some/path"), "should throw") { error in
            XCTAssertEqual(error as! HTTPClientError, HTTPClientError.emptyScheme)
        }
        XCTAssertThrowsError(try Request(url: "app://somewhere/some/path?foo=bar"), "should throw") { error in
            XCTAssertEqual(error as! HTTPClientError, HTTPClientError.unsupportedScheme("app"))
        }
        XCTAssertThrowsError(try Request(url: "https:/foo"), "should throw") { error in
            XCTAssertEqual(error as! HTTPClientError, HTTPClientError.emptyHost)
        }
    }

    func testSchemaCasing() throws {
        XCTAssertNoThrow(try Request(url: "hTTpS://someserver.com:8888/some/path?foo=bar"))
        XCTAssertNoThrow(try Request(url: "uNIx:///some/path"))
    }

    func testGet() throws {
        let response = try self.defaultClient.get(url: self.defaultHTTPBinURLPrefix + "get").wait()
        XCTAssertEqual(.ok, response.status)
    }

    func testGetWithDifferentEventLoopBackpressure() throws {
        let request = try HTTPClient.Request(url: self.defaultHTTPBinURLPrefix + "events/10/1")
        let delegate = TestHTTPDelegate(backpressureEventLoop: self.serverGroup.next())
        let task = self.defaultClient.execute(request: request, delegate: delegate)
        try task.wait()
    }

    func testPost() throws {
        let response = try self.defaultClient.post(url: self.defaultHTTPBinURLPrefix + "post", body: .string("1234")).wait()
        let bytes = response.body.flatMap { $0.getData(at: 0, length: $0.readableBytes) }
        let data = try JSONDecoder().decode(RequestInfo.self, from: bytes!)

        XCTAssertEqual(.ok, response.status)
        XCTAssertEqual("1234", data.data)
    }

    func testGetHttps() throws {
        let localHTTPBin = HTTPBin(ssl: true)
        let localClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup),
                                     configuration: HTTPClient.Configuration(certificateVerification: .none))
        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            XCTAssertNoThrow(try localHTTPBin.shutdown())
        }

        let response = try localClient.get(url: "https://localhost:\(localHTTPBin.port)/get").wait()
        XCTAssertEqual(.ok, response.status)
    }

    func testGetHttpsWithIP() throws {
        let localHTTPBin = HTTPBin(ssl: true)
        let localClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup),
                                     configuration: HTTPClient.Configuration(certificateVerification: .none))
        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            XCTAssertNoThrow(try localHTTPBin.shutdown())
        }

        let response = try localClient.get(url: "https://127.0.0.1:\(localHTTPBin.port)/get").wait()
        XCTAssertEqual(.ok, response.status)
    }

    func testPostHttps() throws {
        let localHTTPBin = HTTPBin(ssl: true)
        let localClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup),
                                     configuration: HTTPClient.Configuration(certificateVerification: .none))
        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            XCTAssertNoThrow(try localHTTPBin.shutdown())
        }

        let request = try Request(url: "https://localhost:\(localHTTPBin.port)/post", method: .POST, body: .string("1234"))

        let response = try localClient.execute(request: request).wait()
        let bytes = response.body.flatMap { $0.getData(at: 0, length: $0.readableBytes) }
        let data = try JSONDecoder().decode(RequestInfo.self, from: bytes!)

        XCTAssertEqual(.ok, response.status)
        XCTAssertEqual("1234", data.data)
    }

    func testHttpRedirect() throws {
        let httpsBin = HTTPBin(ssl: true)
        let localClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup),
                                     configuration: HTTPClient.Configuration(certificateVerification: .none, redirectConfiguration: .follow(max: 10, allowCycles: true)))

        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            XCTAssertNoThrow(try httpsBin.shutdown())
        }

        var response = try localClient.get(url: self.defaultHTTPBinURLPrefix + "redirect/302").wait()
        XCTAssertEqual(response.status, .ok)

        response = try localClient.get(url: self.defaultHTTPBinURLPrefix + "redirect/https?port=\(httpsBin.port)").wait()
        XCTAssertEqual(response.status, .ok)
    }

    func testHttpHostRedirect() {
        let localClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup),
                                     configuration: HTTPClient.Configuration(certificateVerification: .none, redirectConfiguration: .follow(max: 10, allowCycles: true)))

        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
        }

        let url = self.defaultHTTPBinURLPrefix + "redirect/loopback?port=\(self.defaultHTTPBin.port)"
        var maybeResponse: HTTPClient.Response?
        XCTAssertNoThrow(maybeResponse = try localClient.get(url: url).wait())
        guard let response = maybeResponse, let body = response.body else {
            XCTFail("request failed")
            return
        }
        let hostName = try? JSONDecoder().decode(RequestInfo.self, from: body).data
        XCTAssertEqual("127.0.0.1", hostName)
    }

    func testPercentEncoded() throws {
        let response = try self.defaultClient.get(url: self.defaultHTTPBinURLPrefix + "percent%20encoded").wait()
        XCTAssertEqual(.ok, response.status)
    }

    func testPercentEncodedBackslash() throws {
        let response = try self.defaultClient.get(url: self.defaultHTTPBinURLPrefix + "percent%2Fencoded/hello").wait()
        XCTAssertEqual(.ok, response.status)
    }

    func testMultipleContentLengthHeaders() throws {
        let body = ByteBuffer.of(string: "hello world!")

        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: "12")
        let request = try Request(url: self.defaultHTTPBinURLPrefix + "post", method: .POST, headers: headers, body: .byteBuffer(body))
        let response = try self.defaultClient.execute(request: request).wait()
        // if the library adds another content length header we'll get a bad request error.
        XCTAssertEqual(.ok, response.status)
    }

    func testStreaming() throws {
        var request = try Request(url: self.defaultHTTPBinURLPrefix + "events/10/1")
        request.headers.add(name: "Accept", value: "text/event-stream")

        let delegate = CountingDelegate()
        let count = try self.defaultClient.execute(request: request, delegate: delegate).wait()

        XCTAssertEqual(10, count)
    }

    func testRemoteClose() throws {
        XCTAssertThrowsError(try self.defaultClient.get(url: self.defaultHTTPBinURLPrefix + "close").wait(), "Should fail") { error in
            guard case let error = error as? HTTPClientError, error == .remoteConnectionClosed else {
                return XCTFail("Should fail with remoteConnectionClosed")
            }
        }
    }

    func testReadTimeout() throws {
        let localClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup),
                                     configuration: HTTPClient.Configuration(timeout: HTTPClient.Configuration.Timeout(read: .milliseconds(150))))

        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
        }

        XCTAssertThrowsError(try localClient.get(url: self.defaultHTTPBinURLPrefix + "wait").wait(), "Should fail") { error in
            guard case let error = error as? HTTPClientError, error == .readTimeout else {
                return XCTFail("Should fail with readTimeout")
            }
        }
    }

    func testDeadline() throws {
        XCTAssertThrowsError(try self.defaultClient.get(url: self.defaultHTTPBinURLPrefix + "wait", deadline: .now() + .milliseconds(150)).wait(), "Should fail") { error in
            guard case let error = error as? HTTPClientError, error == .readTimeout else {
                return XCTFail("Should fail with readTimeout")
            }
        }
    }

    func testCancel() throws {
        let queue = DispatchQueue(label: "nio-test")
        let request = try Request(url: self.defaultHTTPBinURLPrefix + "wait")
        let task = self.defaultClient.execute(request: request, delegate: TestHTTPDelegate())

        queue.asyncAfter(deadline: .now() + .milliseconds(100)) {
            task.cancel()
        }

        XCTAssertThrowsError(try task.wait(), "Should fail") { error in
            guard case let error = error as? HTTPClientError, error == .cancelled else {
                return XCTFail("Should fail with cancelled")
            }
        }
    }

    func testStressCancel() throws {
        let request = try Request(url: self.defaultHTTPBinURLPrefix + "wait", method: .GET)
        let tasks = (1...100).map { _ -> HTTPClient.Task<TestHTTPDelegate.Response> in
            let task = self.defaultClient.execute(request: request, delegate: TestHTTPDelegate())
            task.cancel()
            return task
        }

        for task in tasks {
            switch (Result { try task.futureResult.timeout(after: .seconds(10)).wait() }) {
            case .success:
                XCTFail("Shouldn't succeed")
                return
            case .failure(let error):
                guard let clientError = error as? HTTPClientError, clientError == .cancelled else {
                    XCTFail("Unexpected error: \(error)")
                    return
                }
            }
        }
    }

    func testHTTPClientAuthorization() {
        var authorization = HTTPClient.Authorization.basic(username: "aladdin", password: "opensesame")
        XCTAssertEqual(authorization.headerValue, "Basic YWxhZGRpbjpvcGVuc2VzYW1l")

        authorization = HTTPClient.Authorization.bearer(tokens: "mF_9.B5f-4.1JqM")
        XCTAssertEqual(authorization.headerValue, "Bearer mF_9.B5f-4.1JqM")
    }

    func testProxyPlaintext() throws {
        let localHTTPBin = HTTPBin(simulateProxy: .plaintext)
        let localClient = HTTPClient(
            eventLoopGroupProvider: .shared(self.clientGroup),
            configuration: .init(proxy: .server(host: "localhost", port: localHTTPBin.port))
        )
        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            XCTAssertNoThrow(try localHTTPBin.shutdown())
        }
        let res = try localClient.get(url: "http://test/ok").wait()
        XCTAssertEqual(res.status, .ok)
    }

    func testProxyTLS() throws {
        let localHTTPBin = HTTPBin(simulateProxy: .tls)
        let localClient = HTTPClient(
            eventLoopGroupProvider: .shared(self.clientGroup),
            configuration: .init(
                certificateVerification: .none,
                proxy: .server(host: "localhost", port: localHTTPBin.port)
            )
        )
        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            XCTAssertNoThrow(try localHTTPBin.shutdown())
        }
        let res = try localClient.get(url: "https://test/ok").wait()
        XCTAssertEqual(res.status, .ok)
    }

    func testProxyPlaintextWithCorrectlyAuthorization() throws {
        let localHTTPBin = HTTPBin(simulateProxy: .plaintext)
        let localClient = HTTPClient(
            eventLoopGroupProvider: .shared(self.clientGroup),
            configuration: .init(proxy: .server(host: "localhost", port: localHTTPBin.port, authorization: .basic(username: "aladdin", password: "opensesame")))
        )
        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            XCTAssertNoThrow(try localHTTPBin.shutdown())
        }
        let res = try localClient.get(url: "http://test/ok").wait()
        XCTAssertEqual(res.status, .ok)
    }

    func testProxyPlaintextWithIncorrectlyAuthorization() throws {
        let localHTTPBin = HTTPBin(simulateProxy: .plaintext)
        let localClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup),
                                     configuration: .init(proxy: .server(host: "localhost",
                                                                         port: localHTTPBin.port,
                                                                         authorization: .basic(username: "aladdin",
                                                                                               password: "opensesamefoo"))))
        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            XCTAssertNoThrow(try localHTTPBin.shutdown())
        }
        XCTAssertThrowsError(try localClient.get(url: "http://test/ok").wait(), "Should fail") { error in
            guard case let error = error as? HTTPClientError, error == .proxyAuthenticationRequired else {
                return XCTFail("Should fail with HTTPClientError.proxyAuthenticationRequired")
            }
        }
    }

    func testUploadStreaming() throws {
        let body: HTTPClient.Body = .stream(length: 8) { writer in
            let buffer = ByteBuffer.of(string: "1234")
            return writer.write(.byteBuffer(buffer)).flatMap {
                let buffer = ByteBuffer.of(string: "4321")
                return writer.write(.byteBuffer(buffer))
            }
        }

        let response = try self.defaultClient.post(url: self.defaultHTTPBinURLPrefix + "post", body: body).wait()
        let bytes = response.body.flatMap { $0.getData(at: 0, length: $0.readableBytes) }
        let data = try JSONDecoder().decode(RequestInfo.self, from: bytes!)

        XCTAssertEqual(.ok, response.status)
        XCTAssertEqual("12344321", data.data)
    }

    func testNoContentLengthForSSLUncleanShutdown() throws {
        // NIOTS deals with ssl unclean shutdown internally
        guard !isTestingNIOTS() else { return }

        let localHTTPBin = HttpBinForSSLUncleanShutdown()
        let localClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup),
                                     configuration: HTTPClient.Configuration(certificateVerification: .none))

        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            localHTTPBin.shutdown()
        }

        XCTAssertThrowsError(try localClient.get(url: "https://localhost:\(localHTTPBin.port)/nocontentlength").wait(), "Should fail") { error in
            guard case let error = error as? NIOSSLError, error == .uncleanShutdown else {
                return XCTFail("Should fail with NIOSSLError.uncleanShutdown")
            }
        }
    }

    func testNoContentLengthWithIgnoreErrorForSSLUncleanShutdown() throws {
        // NIOTS deals with ssl unclean shutdown internally
        guard !isTestingNIOTS() else { return }

        let localHTTPBin = HttpBinForSSLUncleanShutdown()
        let localClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup),
                                     configuration: HTTPClient.Configuration(certificateVerification: .none, ignoreUncleanSSLShutdown: true))

        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            localHTTPBin.shutdown()
        }

        let response = try localClient.get(url: "https://localhost:\(localHTTPBin.port)/nocontentlength").wait()
        let bytes = response.body.flatMap { $0.getData(at: 0, length: $0.readableBytes) }
        let string = String(decoding: bytes!, as: UTF8.self)

        XCTAssertEqual(.ok, response.status)
        XCTAssertEqual("foo", string)
    }

    func testCorrectContentLengthForSSLUncleanShutdown() throws {
        // NIOTS deals with ssl unclean shutdown internally
        guard !isTestingNIOTS() else { return }

        let localHTTPBin = HttpBinForSSLUncleanShutdown()
        let localClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup),
                                     configuration: HTTPClient.Configuration(certificateVerification: .none))

        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            localHTTPBin.shutdown()
        }

        let response = try localClient.get(url: "https://localhost:\(localHTTPBin.port)/").wait()
        let bytes = response.body.flatMap { $0.getData(at: 0, length: $0.readableBytes) }
        let string = String(decoding: bytes!, as: UTF8.self)

        XCTAssertEqual(.notFound, response.status)
        XCTAssertEqual("Not Found", string)
    }

    func testNoContentForSSLUncleanShutdown() throws {
        // NIOTS deals with ssl unclean shutdown internally
        guard !isTestingNIOTS() else { return }

        let localHTTPBin = HttpBinForSSLUncleanShutdown()
        let localClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup),
                                     configuration: HTTPClient.Configuration(certificateVerification: .none))

        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            localHTTPBin.shutdown()
        }

        let response = try localClient.get(url: "https://localhost:\(localHTTPBin.port)/nocontent").wait()

        XCTAssertEqual(.noContent, response.status)
        XCTAssertEqual(response.body, nil)
    }

    func testNoResponseForSSLUncleanShutdown() throws {
        // NIOTS deals with ssl unclean shutdown internally
        guard !isTestingNIOTS() else { return }

        let localHTTPBin = HttpBinForSSLUncleanShutdown()
        let localClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup),
                                     configuration: HTTPClient.Configuration(certificateVerification: .none))

        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            localHTTPBin.shutdown()
        }

        XCTAssertThrowsError(try localClient.get(url: "https://localhost:\(localHTTPBin.port)/noresponse").wait(), "Should fail") { error in
            guard case let sslError = error as? NIOSSLError, sslError == .uncleanShutdown else {
                return XCTFail("Should fail with NIOSSLError.uncleanShutdown")
            }
        }
    }

    func testNoResponseWithIgnoreErrorForSSLUncleanShutdown() throws {
        // NIOTS deals with ssl unclean shutdown internally
        guard !isTestingNIOTS() else { return }

        let localHTTPBin = HttpBinForSSLUncleanShutdown()
        let localClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup),
                                     configuration: HTTPClient.Configuration(certificateVerification: .none, ignoreUncleanSSLShutdown: true))

        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            localHTTPBin.shutdown()
        }

        XCTAssertThrowsError(try localClient.get(url: "https://localhost:\(localHTTPBin.port)/noresponse").wait(), "Should fail") { error in
            guard case let sslError = error as? NIOSSLError, sslError == .uncleanShutdown else {
                return XCTFail("Should fail with NIOSSLError.uncleanShutdown")
            }
        }
    }

    func testWrongContentLengthForSSLUncleanShutdown() throws {
        // NIOTS deals with ssl unclean shutdown internally
        guard !isTestingNIOTS() else { return }

        let localHTTPBin = HttpBinForSSLUncleanShutdown()
        let localClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup),
                                     configuration: HTTPClient.Configuration(certificateVerification: .none))

        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            localHTTPBin.shutdown()
        }

        XCTAssertThrowsError(try localClient.get(url: "https://localhost:\(localHTTPBin.port)/wrongcontentlength").wait(), "Should fail") { error in
            XCTAssertEqual(.uncleanShutdown, error as? NIOSSLError)
        }
    }

    func testWrongContentLengthWithIgnoreErrorForSSLUncleanShutdown() throws {
        // NIOTS deals with ssl unclean shutdown internally
        guard !isTestingNIOTS() else { return }

        let localHTTPBin = HttpBinForSSLUncleanShutdown()
        let localClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup),
                                     configuration: HTTPClient.Configuration(certificateVerification: .none,
                                                                             ignoreUncleanSSLShutdown: true))

        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            localHTTPBin.shutdown()
        }

        XCTAssertThrowsError(try localClient.get(url: "https://localhost:\(localHTTPBin.port)/wrongcontentlength").wait(), "Should fail") { error in
            XCTAssertEqual(.invalidEOFState, error as? HTTPParserError)
        }
    }

    func testEventLoopArgument() throws {
        let localClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup),
                                     configuration: HTTPClient.Configuration(redirectConfiguration: .follow(max: 10, allowCycles: true)))
        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
        }

        class EventLoopValidatingDelegate: HTTPClientResponseDelegate {
            typealias Response = Bool

            let eventLoop: EventLoop
            var result = false

            init(eventLoop: EventLoop) {
                self.eventLoop = eventLoop
            }

            func didReceiveHead(task: HTTPClient.Task<Bool>, _ head: HTTPResponseHead) -> EventLoopFuture<Void> {
                self.result = task.eventLoop === self.eventLoop
                return task.eventLoop.makeSucceededFuture(())
            }

            func didFinishRequest(task: HTTPClient.Task<Bool>) throws -> Bool {
                return self.result
            }
        }

        let eventLoop = self.clientGroup.next()
        let delegate = EventLoopValidatingDelegate(eventLoop: eventLoop)
        var request = try HTTPClient.Request(url: self.defaultHTTPBinURLPrefix + "get")
        var response = try localClient.execute(request: request, delegate: delegate, eventLoop: .delegate(on: eventLoop)).wait()
        XCTAssertEqual(true, response)

        // redirect
        request = try HTTPClient.Request(url: self.defaultHTTPBinURLPrefix + "redirect/302")
        response = try localClient.execute(request: request, delegate: delegate, eventLoop: .delegate(on: eventLoop)).wait()
        XCTAssertEqual(true, response)
    }

    func testDecompression() throws {
        let localHTTPBin = HTTPBin(compress: true)
        let localClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup),
                                     configuration: .init(decompression: .enabled(limit: .none)))

        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            XCTAssertNoThrow(try localHTTPBin.shutdown())
        }

        var body = ""
        for _ in 1...1000 {
            body += "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua."
        }

        for algorithm in [nil, "gzip", "deflate"] {
            var request = try HTTPClient.Request(url: "http://localhost:\(localHTTPBin.port)/post", method: .POST)
            request.body = .string(body)
            if let algorithm = algorithm {
                request.headers.add(name: "Accept-Encoding", value: algorithm)
            }

            let response = try localClient.execute(request: request).wait()
            let bytes = response.body!.getData(at: 0, length: response.body!.readableBytes)!
            let data = try JSONDecoder().decode(RequestInfo.self, from: bytes)

            XCTAssertEqual(.ok, response.status)
            XCTAssertGreaterThan(body.count, response.headers["Content-Length"].first.flatMap { Int($0) }!)
            if let algorithm = algorithm {
                XCTAssertEqual(algorithm, response.headers["Content-Encoding"].first)
            } else {
                XCTAssertEqual("deflate", response.headers["Content-Encoding"].first)
            }
            XCTAssertEqual(body, data.data)
        }
    }

    func testDecompressionLimit() throws {
        let localHTTPBin = HTTPBin(compress: true)
        let localClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup), configuration: .init(decompression: .enabled(limit: .ratio(1))))

        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            XCTAssertNoThrow(try localHTTPBin.shutdown())
        }

        var request = try HTTPClient.Request(url: "http://localhost:\(localHTTPBin.port)/post", method: .POST)
        request.body = .byteBuffer(ByteBuffer.of(bytes: [120, 156, 75, 76, 28, 5, 200, 0, 0, 248, 66, 103, 17]))
        request.headers.add(name: "Accept-Encoding", value: "deflate")

        XCTAssertThrowsError(try localClient.execute(request: request).wait()) { error in
            guard case .some(.limit) = error as? NIOHTTPDecompression.DecompressionError else {
                XCTFail("wrong error: \(error)")
                return
            }
        }
    }

    func testLoopDetectionRedirectLimit() throws {
        let localHTTPBin = HTTPBin(ssl: true)
        let localClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup),
                                     configuration: HTTPClient.Configuration(certificateVerification: .none, redirectConfiguration: .follow(max: 5, allowCycles: false)))

        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            XCTAssertNoThrow(try localHTTPBin.shutdown())
        }

        XCTAssertThrowsError(try localClient.get(url: "https://localhost:\(localHTTPBin.port)/redirect/infinite1").wait(), "Should fail with redirect limit") { error in
            XCTAssertEqual(error as? HTTPClientError, HTTPClientError.redirectCycleDetected)
        }
    }

    func testCountRedirectLimit() throws {
        let localHTTPBin = HTTPBin(ssl: true)
        let localClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup),
                                     configuration: HTTPClient.Configuration(certificateVerification: .none, redirectConfiguration: .follow(max: 10, allowCycles: true)))

        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            XCTAssertNoThrow(try localHTTPBin.shutdown())
        }

        XCTAssertThrowsError(try localClient.get(url: "https://localhost:\(localHTTPBin.port)/redirect/infinite1").wait(), "Should fail with redirect limit") { error in
            XCTAssertEqual(error as? HTTPClientError, HTTPClientError.redirectLimitReached)
        }
    }

    func testMultipleConcurrentRequests() throws {
        let numberOfRequestsPerThread = 1000
        let numberOfParallelWorkers = 5

        final class HTTPServer: ChannelInboundHandler {
            typealias InboundIn = HTTPServerRequestPart
            typealias OutboundOut = HTTPServerResponsePart

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                if case .end = self.unwrapInboundIn(data) {
                    let responseHead = HTTPServerResponsePart.head(.init(version: .init(major: 1, minor: 1),
                                                                         status: .ok))
                    context.write(self.wrapOutboundOut(responseHead), promise: nil)
                    context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
                }
            }
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        var server: Channel?
        XCTAssertNoThrow(server = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socket(.init(SOL_SOCKET), .init(SO_REUSEADDR)), value: 1)
            .serverChannelOption(ChannelOptions.backlog, value: .init(numberOfParallelWorkers))
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: false,
                                                             withServerUpgrade: nil,
                                                             withErrorHandling: false).flatMap {
                    channel.pipeline.addHandler(HTTPServer())
                }
            }
            .bind(to: .init(ipAddress: "127.0.0.1", port: 0))
            .wait())
        defer {
            XCTAssertNoThrow(try server?.close().wait())
        }

        let g = DispatchGroup()
        for workerID in 0..<numberOfParallelWorkers {
            DispatchQueue(label: "\(#file):\(#line):worker-\(workerID)").async(group: g) {
                func makeRequest() {
                    let url = "http://127.0.0.1:\(server?.localAddress?.port ?? -1)/hello"
                    XCTAssertNoThrow(try self.defaultClient.get(url: url).wait())
                }
                for _ in 0..<numberOfRequestsPerThread {
                    makeRequest()
                }
            }
        }
        let timeout = DispatchTime.now() + .seconds(180)
        switch g.wait(timeout: timeout) {
        case .success:
            break
        case .timedOut:
            XCTFail("Timed out")
        }
    }

    func testWorksWith500Error() {
        let web = NIOHTTP1TestServer(group: self.serverGroup)
        defer {
            XCTAssertNoThrow(try web.stop())
        }
        let result = self.defaultClient.get(url: "http://localhost:\(web.serverPort)/foo")

        XCTAssertNoThrow(XCTAssertEqual(.head(.init(version: .init(major: 1, minor: 1),
                                                    method: .GET,
                                                    uri: "/foo",
                                                    headers: HTTPHeaders([("Host", "localhost")]))),
                                        try web.readInbound()))
        XCTAssertNoThrow(XCTAssertEqual(.end(nil),
                                        try web.readInbound()))
        XCTAssertNoThrow(try web.writeOutbound(.head(.init(version: .init(major: 1, minor: 1),
                                                           status: .internalServerError))))
        XCTAssertNoThrow(try web.writeOutbound(.end(nil)))

        var response: HTTPClient.Response?
        XCTAssertNoThrow(response = try result.wait())
        XCTAssertEqual(.internalServerError, response?.status)
        XCTAssertNil(response?.body)
    }

    func testWorksWithHTTP10Response() {
        let web = NIOHTTP1TestServer(group: self.serverGroup)
        defer {
            XCTAssertNoThrow(try web.stop())
        }
        let result = self.defaultClient.get(url: "http://localhost:\(web.serverPort)/foo")

        XCTAssertNoThrow(XCTAssertEqual(.head(.init(version: .init(major: 1, minor: 1),
                                                    method: .GET,
                                                    uri: "/foo",
                                                    headers: HTTPHeaders([("Host", "localhost")]))),
                                        try web.readInbound()))
        XCTAssertNoThrow(XCTAssertEqual(.end(nil),
                                        try web.readInbound()))
        XCTAssertNoThrow(try web.writeOutbound(.head(.init(version: .init(major: 1, minor: 0),
                                                           status: .internalServerError))))
        XCTAssertNoThrow(try web.writeOutbound(.end(nil)))

        var response: HTTPClient.Response?
        XCTAssertNoThrow(response = try result.wait())
        XCTAssertEqual(.internalServerError, response?.status)
        XCTAssertNil(response?.body)
    }

    func testWorksWhenServerClosesConnectionAfterReceivingRequest() {
        let web = NIOHTTP1TestServer(group: self.serverGroup)
        let result = self.defaultClient.get(url: "http://localhost:\(web.serverPort)/foo")

        XCTAssertNoThrow(XCTAssertEqual(.head(.init(version: .init(major: 1, minor: 1),
                                                    method: .GET,
                                                    uri: "/foo",
                                                    headers: HTTPHeaders([("Host", "localhost")]))),
                                        try web.readInbound()))
        XCTAssertNoThrow(XCTAssertEqual(.end(nil),
                                        try web.readInbound()))
        XCTAssertNoThrow(try web.stop())

        XCTAssertThrowsError(try result.wait()) { error in
            XCTAssertEqual(HTTPClientError.remoteConnectionClosed, error as? HTTPClientError)
        }
    }

    func testSubsequentRequestsWorkWithServerSendingConnectionClose() {
        let web = NIOHTTP1TestServer(group: self.serverGroup)
        defer {
            XCTAssertNoThrow(try web.stop())
        }

        for _ in 0..<10 {
            let result = self.defaultClient.get(url: "http://localhost:\(web.serverPort)/foo")

            XCTAssertNoThrow(XCTAssertEqual(.head(.init(version: .init(major: 1, minor: 1),
                                                        method: .GET,
                                                        uri: "/foo",
                                                        headers: HTTPHeaders([("Host", "localhost")]))),
                                            try web.readInbound()))
            XCTAssertNoThrow(XCTAssertEqual(.end(nil),
                                            try web.readInbound()))
            XCTAssertNoThrow(try web.writeOutbound(.head(.init(version: .init(major: 1, minor: 0),
                                                               status: .ok,
                                                               headers: HTTPHeaders([("connection", "close")])))))
            XCTAssertNoThrow(try web.writeOutbound(.end(nil)))

            var response: HTTPClient.Response?
            XCTAssertNoThrow(response = try result.wait())
            XCTAssertEqual(.ok, response?.status)
            XCTAssertNil(response?.body)
        }
    }

    func testSubsequentRequestsWorkWithServerAlternatingBetweenKeepAliveAndClose() {
        let web = NIOHTTP1TestServer(group: self.serverGroup)
        defer {
            XCTAssertNoThrow(try web.stop())
        }

        for i in 0..<10 {
            let result = self.defaultClient.get(url: "http://localhost:\(web.serverPort)/foo")

            XCTAssertNoThrow(XCTAssertEqual(.head(.init(version: .init(major: 1, minor: 1),
                                                        method: .GET,
                                                        uri: "/foo",
                                                        headers: HTTPHeaders([("Host", "localhost")]))),
                                            try web.readInbound()))
            XCTAssertNoThrow(XCTAssertEqual(.end(nil),
                                            try web.readInbound()))
            XCTAssertNoThrow(try web.writeOutbound(.head(.init(version: .init(major: 1, minor: 0),
                                                               status: .ok,
                                                               headers: HTTPHeaders([("connection",
                                                                                      i % 2 == 0 ? "close" : "keep-alive")])))))
            XCTAssertNoThrow(try web.writeOutbound(.end(nil)))

            var response: HTTPClient.Response?
            XCTAssertNoThrow(response = try result.wait())
            XCTAssertEqual(.ok, response?.status)
            XCTAssertNil(response?.body)
        }
    }

    func testStressGetHttps() throws {
        let localHTTPBin = HTTPBin(ssl: true)
        let localClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup),
                                     configuration: HTTPClient.Configuration(certificateVerification: .none))
        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            XCTAssertNoThrow(try localHTTPBin.shutdown())
        }

        let eventLoop = localClient.eventLoopGroup.next()
        let requestCount = 200
        var futureResults = [EventLoopFuture<HTTPClient.Response>]()
        for _ in 1...requestCount {
            let req = try HTTPClient.Request(url: "https://localhost:\(localHTTPBin.port)/get", method: .GET, headers: ["X-internal-delay": "100"])
            futureResults.append(localClient.execute(request: req))
        }
        XCTAssertNoThrow(try EventLoopFuture<HTTPClient.Response>.andAllSucceed(futureResults, on: eventLoop).wait())
    }

    func testStressGetHttpsSSLError() throws {
        let request = try Request(url: "https://localhost:\(self.defaultHTTPBin.port)/wait", method: .GET)
        let tasks = (1...100).map { _ -> HTTPClient.Task<TestHTTPDelegate.Response> in
            self.defaultClient.execute(request: request, delegate: TestHTTPDelegate())
        }

        let results = try EventLoopFuture<TestHTTPDelegate.Response>.whenAllComplete(tasks.map { $0.futureResult }, on: self.defaultClient.eventLoopGroup.next()).wait()

        for result in results {
            switch result {
            case .success:
                XCTFail("Shouldn't succeed")
                continue
            case .failure(let error):
                if isTestingNIOTS() {
                    #if canImport(Network)
                        guard let clientError = error as? HTTPClient.NWTLSError else {
                            XCTFail("Unexpected error: \(error)")
                            continue
                        }
                        // We're speaking TLS to a plain text server. This will cause the handshake to fail but given
                        // that the bytes "HTTP/1.1" aren't the start of a valid TLS packet, we can also get
                        // errSSLPeerProtocolVersion because the first bytes contain the version.
                        XCTAssert(clientError.status == errSSLHandshakeFail ||
                            clientError.status == errSSLPeerProtocolVersion,
                                  "unexpected NWTLSError with status \(clientError.status)")
                    #endif
                } else {
                    guard let clientError = error as? NIOSSLError, case NIOSSLError.handshakeFailed = clientError else {
                        XCTFail("Unexpected error: \(error)")
                        continue
                    }
                }
            }
        }
    }

    func testFailingConnectionIsReleased() {
        let localHTTPBin = HTTPBin(refusesConnections: true)
        let localClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup))
        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            XCTAssertNoThrow(try localHTTPBin.shutdown())
        }
        do {
            _ = try localClient.get(url: "http://localhost:\(localHTTPBin.port)/get").timeout(after: .seconds(5)).wait()
            XCTFail("Shouldn't succeed")
        } catch {
            guard !(error is EventLoopFutureTimeoutError) else {
                XCTFail("Timed out but should have failed immediately")
                return
            }
        }
    }

    func testResponseDelayGet() throws {
        let req = try HTTPClient.Request(url: self.defaultHTTPBinURLPrefix + "get",
                                         method: .GET,
                                         headers: ["X-internal-delay": "2000"],
                                         body: nil)
        let start = Date()
        let response = try! self.defaultClient.execute(request: req).wait()
        XCTAssertGreaterThan(Date().timeIntervalSince(start), 2)
        XCTAssertEqual(response.status, .ok)
    }

    func testIdleTimeoutNoReuse() throws {
        var req = try HTTPClient.Request(url: self.defaultHTTPBinURLPrefix + "get", method: .GET)
        XCTAssertNoThrow(try self.defaultClient.execute(request: req, deadline: .now() + .seconds(2)).wait())
        req.headers.add(name: "X-internal-delay", value: "2500")
        try self.defaultClient.eventLoopGroup.next().scheduleTask(in: .milliseconds(250)) {}.futureResult.wait()
        XCTAssertNoThrow(try self.defaultClient.execute(request: req).timeout(after: .seconds(10)).wait())
    }

    func testStressGetClose() throws {
        let eventLoop = self.defaultClient.eventLoopGroup.next()
        let requestCount = 200
        var futureResults = [EventLoopFuture<HTTPClient.Response>]()
        for _ in 1...requestCount {
            let req = try HTTPClient.Request(url: self.defaultHTTPBinURLPrefix + "get",
                                             method: .GET,
                                             headers: ["X-internal-delay": "5", "Connection": "close"])
            futureResults.append(self.defaultClient.execute(request: req))
        }
        XCTAssertNoThrow(try EventLoopFuture<HTTPClient.Response>.andAllComplete(futureResults, on: eventLoop)
            .timeout(after: .seconds(10)).wait())
    }

    func testManyConcurrentRequestsWork() {
        let numberOfWorkers = 20
        let numberOfRequestsPerWorkers = 20
        let allWorkersReady = DispatchSemaphore(value: 0)
        let allWorkersGo = DispatchSemaphore(value: 0)
        let allDone = DispatchGroup()

        let url = self.defaultHTTPBinURLPrefix + "get"
        XCTAssertNoThrow(XCTAssertEqual(.ok, try self.defaultClient.get(url: url).wait().status))

        for w in 0..<numberOfWorkers {
            let q = DispatchQueue(label: "worker \(w)")
            q.async(group: allDone) {
                func go() {
                    allWorkersReady.signal() // tell the driver we're ready
                    allWorkersGo.wait() // wait for the driver to let us go

                    for _ in 0..<numberOfRequestsPerWorkers {
                        XCTAssertNoThrow(XCTAssertEqual(.ok, try self.defaultClient.get(url: url).wait().status))
                    }
                }
                go()
            }
        }

        for _ in 0..<numberOfWorkers {
            allWorkersReady.wait()
        }
        // now all workers should be waiting for the go signal

        for _ in 0..<numberOfWorkers {
            allWorkersGo.signal()
        }
        // all workers should be running, let's wait for them to finish
        allDone.wait()
    }

    func testRepeatedRequestsWorkWhenServerAlwaysCloses() {
        let web = NIOHTTP1TestServer(group: self.serverGroup)
        defer {
            XCTAssertNoThrow(try web.stop())
        }

        let localClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup))
        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
        }

        for _ in 0..<10 {
            let result = localClient.get(url: "http://localhost:\(web.serverPort)/foo")
            XCTAssertNoThrow(XCTAssertEqual(.head(.init(version: .init(major: 1, minor: 1),
                                                        method: .GET,
                                                        uri: "/foo",
                                                        headers: HTTPHeaders([("Host", "localhost")]))),
                                            try web.readInbound()))
            XCTAssertNoThrow(XCTAssertEqual(.end(nil),
                                            try web.readInbound()))
            XCTAssertNoThrow(try web.writeOutbound(.head(.init(version: .init(major: 1, minor: 1),
                                                               status: .ok,
                                                               headers: HTTPHeaders([("CoNnEcTiOn", "cLoSe")])))))
            XCTAssertNoThrow(try web.writeOutbound(.end(nil)))

            var response: HTTPClient.Response?
            XCTAssertNoThrow(response = try result.wait())
            XCTAssertEqual(.ok, response?.status)
            XCTAssertNil(response?.body)
        }
    }

    func testShutdownBeforeTasksCompletion() throws {
        let client = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup))
        let req = try HTTPClient.Request(url: self.defaultHTTPBinURLPrefix + "get", method: .GET, headers: ["X-internal-delay": "500"])
        let res = client.execute(request: req)
        XCTAssertNoThrow(try client.syncShutdown())
        _ = try? res.timeout(after: .seconds(2)).wait()
    }

    /// This test would cause an assertion failure on `HTTPClient` deinit if client doesn't actually shutdown
    func testUncleanShutdownActuallyShutsDown() throws {
        let client = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup))
        let req = try HTTPClient.Request(url: self.defaultHTTPBinURLPrefix + "get", method: .GET, headers: ["X-internal-delay": "200"])
        _ = client.execute(request: req)
        try? client.syncShutdown()
    }

    func testUncleanShutdownCancelsTasks() throws {
        let client = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup))

        let responses = (1...100).map { _ in
            client.get(url: self.defaultHTTPBinURLPrefix + "wait")
        }

        try client.syncShutdown()

        let results = try EventLoopFuture.whenAllComplete(responses, on: self.clientGroup.next()).timeout(after: .seconds(100)).wait()

        for result in results {
            switch result {
            case .success:
                XCTFail("Shouldn't succeed")
            case .failure(let error):
                if let clientError = error as? HTTPClientError, clientError == .cancelled {
                    continue
                } else {
                    XCTFail("Unexpected error: \(error)")
                }
            }
        }
    }

    func testDoubleShutdown() {
        let client = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup))
        XCTAssertNoThrow(try client.syncShutdown())
        do {
            try client.syncShutdown()
            XCTFail("Shutdown should fail with \(HTTPClientError.alreadyShutdown)")
        } catch {
            guard let clientError = error as? HTTPClientError, clientError == .alreadyShutdown else {
                XCTFail("Unexpected error: \(error) instead of \(HTTPClientError.alreadyShutdown)")
                return
            }
        }
    }

    func testTaskFailsWhenClientIsShutdown() {
        let client = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup))
        XCTAssertNoThrow(try client.syncShutdown())
        do {
            _ = try client.get(url: "http://localhost/").wait()
            XCTFail("Request shouldn't succeed")
        } catch {
            if let error = error as? HTTPClientError, error == .alreadyShutdown {
                return
            } else {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRaceNewRequestsVsShutdown() {
        let numberOfWorkers = 20
        let allWorkersReady = DispatchSemaphore(value: 0)
        let allWorkersGo = DispatchSemaphore(value: 0)
        let allDone = DispatchGroup()

        let localClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup))
        defer {
            XCTAssertThrowsError(try localClient.syncShutdown()) { error in
                XCTAssertEqual(.alreadyShutdown, error as? HTTPClientError)
            }
        }

        let url = self.defaultHTTPBinURLPrefix + "get"
        XCTAssertNoThrow(XCTAssertEqual(.ok, try localClient.get(url: url).wait().status))

        for w in 0..<numberOfWorkers {
            let q = DispatchQueue(label: "worker \(w)")
            q.async(group: allDone) {
                func go() {
                    allWorkersReady.signal() // tell the driver we're ready
                    allWorkersGo.wait() // wait for the driver to let us go

                    do {
                        while true {
                            let result = try localClient.get(url: url).wait().status
                            XCTAssertEqual(.ok, result)
                        }
                    } catch {
                        // ok, we failed, pool probably shutdown
                        if let clientError = error as? HTTPClientError, clientError == .cancelled || clientError == .alreadyShutdown {
                            return
                        } else {
                            XCTFail("Unexpected error: \(error)")
                        }
                    }
                }
                go()
            }
        }

        for _ in 0..<numberOfWorkers {
            allWorkersReady.wait()
        }
        // now all workers should be waiting for the go signal

        for _ in 0..<numberOfWorkers {
            allWorkersGo.signal()
        }
        Thread.sleep(until: .init(timeIntervalSinceNow: 0.2))
        XCTAssertNoThrow(try localClient.syncShutdown())
        // all workers should be running, let's wait for them to finish
        allDone.wait()
    }

    func testVaryingLoopPreference() throws {
        let elg = getDefaultEventLoopGroup(numberOfThreads: 2)
        let first = elg.next()
        let second = elg.next()
        XCTAssert(first !== second)
        let client = HTTPClient(eventLoopGroupProvider: .shared(elg))

        defer {
            XCTAssertNoThrow(try client.syncShutdown())
            XCTAssertNoThrow(try elg.syncShutdownGracefully())
        }

        var futureResults = [EventLoopFuture<HTTPClient.Response>]()
        for i in 1...100 {
            let request = try HTTPClient.Request(url: self.defaultHTTPBinURLPrefix + "get", method: .GET, headers: ["X-internal-delay": "10"])
            let preference: HTTPClient.EventLoopPreference
            if i <= 50 {
                preference = .delegateAndChannel(on: first)
            } else {
                preference = .delegateAndChannel(on: second)
            }
            futureResults.append(client.execute(request: request, eventLoop: preference))
        }

        let results = try EventLoopFuture.whenAllComplete(futureResults, on: elg.next()).wait()

        for result in results {
            switch result {
            case .success:
                break
            case .failure(let error):
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testMakeSecondRequestDuringCancelledCallout() {
        let el = self.clientGroup.next()
        let web = NIOHTTP1TestServer(group: self.serverGroup.next())
        defer {
            // This will throw as we've started the request but haven't fulfilled it.
            XCTAssertThrowsError(try web.stop())
        }

        let url = "http://127.0.0.1:\(web.serverPort)"
        let localClient = HTTPClient(eventLoopGroupProvider: .shared(el))
        defer {
            XCTAssertThrowsError(try localClient.syncShutdown()) { error in
                XCTAssertEqual(.alreadyShutdown, error as? HTTPClientError)
            }
        }

        let seenError = DispatchGroup()
        seenError.enter()
        var maybeSecondRequest: EventLoopFuture<HTTPClient.Response>?
        XCTAssertNoThrow(maybeSecondRequest = try el.submit {
            let neverSucceedingRequest = localClient.get(url: url)
            let secondRequest = neverSucceedingRequest.flatMapError { error in
                XCTAssertEqual(.cancelled, error as? HTTPClientError)
                seenError.leave()
                return localClient.get(url: url) // <== this is the main part, during the error callout, we call back in
            }
            return secondRequest
        }.wait())

        guard let secondRequest = maybeSecondRequest else {
            XCTFail("couldn't get request future")
            return
        }

        // Let's pull out the request .head so we know the request has started (but nothing else)
        XCTAssertNoThrow(XCTAssertNotNil(try web.readInbound()))

        XCTAssertNoThrow(try localClient.syncShutdown())

        seenError.wait()
        XCTAssertThrowsError(try secondRequest.wait()) { error in
            XCTAssertEqual(.alreadyShutdown, error as? HTTPClientError)
        }
    }

    func testMakeSecondRequestDuringSuccessCallout() {
        let el = self.clientGroup.next()
        let url = "http://127.0.0.1:\(self.defaultHTTPBin.port)/get"
        let localClient = HTTPClient(eventLoopGroupProvider: .shared(el))
        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
        }

        XCTAssertNoThrow(XCTAssertEqual(.ok,
                                        try el.flatSubmit { () -> EventLoopFuture<HTTPClient.Response> in
                                            localClient.get(url: url).flatMap { firstResponse in
                                                XCTAssertEqual(.ok, firstResponse.status)
                                                return localClient.get(url: url) // <== interesting bit here
                                            }
        }.wait().status))
    }

    func testMakeSecondRequestWhilstFirstIsOngoing() {
        let web = NIOHTTP1TestServer(group: self.serverGroup)
        defer {
            XCTAssertNoThrow(try web.stop())
        }

        let client = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup))
        defer {
            XCTAssertNoThrow(try client.syncShutdown())
        }

        let url = "http://127.0.0.1:\(web.serverPort)"
        let firstRequest = client.get(url: url)

        XCTAssertNoThrow(XCTAssertNotNil(try web.readInbound())) // first request: .head

        // Now, the first request is ongoing but not complete, let's start a second one
        let secondRequest = client.get(url: url)
        XCTAssertNoThrow(XCTAssertEqual(.end(nil), try web.readInbound())) // first request: .end

        XCTAssertNoThrow(try web.writeOutbound(.head(.init(version: .init(major: 1, minor: 1), status: .ok))))
        XCTAssertNoThrow(try web.writeOutbound(.end(nil)))

        XCTAssertNoThrow(XCTAssertEqual(.ok, try firstRequest.wait().status))

        // Okay, first request done successfully, let's do the second one too.
        XCTAssertNoThrow(XCTAssertNotNil(try web.readInbound())) // first request: .head
        XCTAssertNoThrow(XCTAssertEqual(.end(nil), try web.readInbound())) // first request: .end

        XCTAssertNoThrow(try web.writeOutbound(.head(.init(version: .init(major: 1, minor: 1), status: .created))))
        XCTAssertNoThrow(try web.writeOutbound(.end(nil)))
        XCTAssertNoThrow(XCTAssertEqual(.created, try secondRequest.wait().status))
    }

    func testUDSBasic() {
        // This tests just connecting to a URL where the whole URL is the UNIX domain socket path like
        //     unix:///this/is/my/socket.sock
        // We don't really have a path component, so we'll have to use "/"
        XCTAssertNoThrow(try TemporaryFileHelpers.withTemporaryUnixDomainSocketPathName { path in
            let localHTTPBin = HTTPBin(bindTarget: .unixDomainSocket(path))
            defer {
                XCTAssertNoThrow(try localHTTPBin.shutdown())
            }
            let target = "unix://\(path)"
            XCTAssertNoThrow(XCTAssertEqual(["Yes"[...]],
                                            try self.defaultClient.get(url: target).wait().headers[canonicalForm: "X-Is-This-Slash"]))
        })
    }

    func testUDSSocketAndPath() {
        // Here, we're testing a URL that's encoding two different paths:
        //
        //  1. a "base path" which is the path to the UNIX domain socket
        //  2. an actual path which is the normal path in a regular URL like https://example.com/this/is/the/path
        XCTAssertNoThrow(try TemporaryFileHelpers.withTemporaryUnixDomainSocketPathName { path in
            let localHTTPBin = HTTPBin(bindTarget: .unixDomainSocket(path))
            defer {
                XCTAssertNoThrow(try localHTTPBin.shutdown())
            }
            guard let target = URL(string: "/echo-uri", relativeTo: URL(string: "unix://\(path)")),
                let request = try? Request(url: target) else {
                XCTFail("couldn't build URL for request")
                return
            }
            XCTAssertNoThrow(XCTAssertEqual(["/echo-uri"[...]],
                                            try self.defaultClient.execute(request: request).wait().headers[canonicalForm: "X-Calling-URI"]))
        })
    }

    func testHTTPPlusUNIX() {
        // Here, we're testing a URL where the UNIX domain socket is encoded as the host name
        XCTAssertNoThrow(try TemporaryFileHelpers.withTemporaryUnixDomainSocketPathName { path in
            let localHTTPBin = HTTPBin(bindTarget: .unixDomainSocket(path))
            defer {
                XCTAssertNoThrow(try localHTTPBin.shutdown())
            }
            guard let target = URL(string: "http+unix://\(path.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed)!)/echo-uri"),
                let request = try? Request(url: target) else {
                XCTFail("couldn't build URL for request")
                return
            }
            XCTAssertNoThrow(XCTAssertEqual(["/echo-uri"[...]],
                                            try self.defaultClient.execute(request: request).wait().headers[canonicalForm: "X-Calling-URI"]))
        })
    }

    func testHTTPSPlusUNIX() {
        // Here, we're testing a URL where the UNIX domain socket is encoded as the host name
        XCTAssertNoThrow(try TemporaryFileHelpers.withTemporaryUnixDomainSocketPathName { path in
            let localHTTPBin = HTTPBin(ssl: true, bindTarget: .unixDomainSocket(path))
            let localClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup),
                                         configuration: HTTPClient.Configuration(certificateVerification: .none))
            defer {
                XCTAssertNoThrow(try localClient.syncShutdown())
                XCTAssertNoThrow(try localHTTPBin.shutdown())
            }
            guard let target = URL(string: "https+unix://\(path.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed)!)/echo-uri"),
                let request = try? Request(url: target) else {
                XCTFail("couldn't build URL for request")
                return
            }
            XCTAssertNoThrow(XCTAssertEqual(["/echo-uri"[...]],
                                            try localClient.execute(request: request).wait().headers[canonicalForm: "X-Calling-URI"]))
        })
    }

    func testUseExistingConnectionOnDifferentEL() throws {
        let threadCount = 16
        let elg = getDefaultEventLoopGroup(numberOfThreads: threadCount)
        let localClient = HTTPClient(eventLoopGroupProvider: .shared(elg))
        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            XCTAssertNoThrow(try elg.syncShutdownGracefully())
        }

        let eventLoops = (1...threadCount).map { _ in elg.next() }
        let request = try HTTPClient.Request(url: self.defaultHTTPBinURLPrefix + "get")
        let closingRequest = try HTTPClient.Request(url: self.defaultHTTPBinURLPrefix + "get", headers: ["Connection": "close"])

        for (index, el) in eventLoops.enumerated() {
            if index.isMultiple(of: 2) {
                XCTAssertNoThrow(try localClient.execute(request: request, eventLoop: .delegateAndChannel(on: el)).wait())
            } else {
                XCTAssertNoThrow(try localClient.execute(request: request, eventLoop: .delegateAndChannel(on: el)).wait())
                XCTAssertNoThrow(try localClient.execute(request: closingRequest, eventLoop: .indifferent).wait())
            }
        }
    }

    func testWeRecoverFromServerThatClosesTheConnectionOnUs() {
        final class ServerThatAcceptsThenRejects: ChannelInboundHandler {
            typealias InboundIn = HTTPServerRequestPart
            typealias OutboundOut = HTTPServerResponsePart

            let requestNumber: NIOAtomic<Int>
            let connectionNumber: NIOAtomic<Int>

            init(requestNumber: NIOAtomic<Int>, connectionNumber: NIOAtomic<Int>) {
                self.requestNumber = requestNumber
                self.connectionNumber = connectionNumber
            }

            func channelActive(context: ChannelHandlerContext) {
                _ = self.connectionNumber.add(1)
            }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                let req = self.unwrapInboundIn(data)

                switch req {
                case .head, .body:
                    ()
                case .end:
                    let last = self.requestNumber.add(1)
                    switch last {
                    case 0, 2:
                        context.write(self.wrapOutboundOut(.head(.init(version: .init(major: 1, minor: 1), status: .ok))),
                                      promise: nil)
                        context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
                    case 1:
                        context.close(promise: nil)
                    default:
                        XCTFail("did not expect request \(last + 1)")
                    }
                }
            }
        }

        let requestNumber = NIOAtomic<Int>.makeAtomic(value: 0)
        let connectionNumber = NIOAtomic<Int>.makeAtomic(value: 0)
        let sharedStateServerHandler = ServerThatAcceptsThenRejects(requestNumber: requestNumber,
                                                                    connectionNumber: connectionNumber)
        var maybeServer: Channel?
        XCTAssertNoThrow(maybeServer = try ServerBootstrap(group: self.serverGroup)
            .serverChannelOption(ChannelOptions.socket(.init(SOL_SOCKET), .init(SO_REUSEADDR)), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    // We're deliberately adding a handler which is shared between multiple channels. This is normally
                    // very verboten but this handler is specially crafted to tolerate this.
                    channel.pipeline.addHandler(sharedStateServerHandler)
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait())
        guard let server = maybeServer else {
            XCTFail("couldn't create server")
            return
        }
        defer {
            XCTAssertNoThrow(try server.close().wait())
        }

        let url = "http://127.0.0.1:\(server.localAddress!.port!)"
        let client = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup))
        defer {
            XCTAssertNoThrow(try client.syncShutdown())
        }

        XCTAssertEqual(0, sharedStateServerHandler.connectionNumber.load())
        XCTAssertEqual(0, sharedStateServerHandler.requestNumber.load())
        XCTAssertNoThrow(XCTAssertEqual(.ok, try client.get(url: url).wait().status))
        XCTAssertEqual(1, sharedStateServerHandler.connectionNumber.load())
        XCTAssertEqual(1, sharedStateServerHandler.requestNumber.load())
        XCTAssertThrowsError(try client.get(url: url).wait().status) { error in
            XCTAssertEqual(.remoteConnectionClosed, error as? HTTPClientError)
        }
        XCTAssertEqual(1, sharedStateServerHandler.connectionNumber.load())
        XCTAssertEqual(2, sharedStateServerHandler.requestNumber.load())
        XCTAssertNoThrow(XCTAssertEqual(.ok, try client.get(url: url).wait().status))
        XCTAssertEqual(2, sharedStateServerHandler.connectionNumber.load())
        XCTAssertEqual(3, sharedStateServerHandler.requestNumber.load())
    }

    func testPoolClosesIdleConnections() {
        let localClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup),
                                     configuration: .init(maximumAllowedIdleTimeInConnectionPool: .milliseconds(100)))
        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
        }
        XCTAssertNoThrow(try localClient.get(url: self.defaultHTTPBinURLPrefix + "get").wait())
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(self.defaultHTTPBin.activeConnections, 0)
    }

    func testRacePoolIdleConnectionsAndGet() {
        let localClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup),
                                     configuration: .init(maximumAllowedIdleTimeInConnectionPool: .milliseconds(10)))
        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
        }
        for _ in 1...500 {
            XCTAssertNoThrow(try localClient.get(url: self.defaultHTTPBinURLPrefix + "get").wait())
            Thread.sleep(forTimeInterval: 0.01 + .random(in: -0.05...0.05))
        }
    }

    func testAvoidLeakingTLSHandshakeCompletionPromise() {
        let localClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup))
        let localHTTPBin = HTTPBin()
        let port = localHTTPBin.port
        XCTAssertNoThrow(try localHTTPBin.shutdown())
        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
        }

        XCTAssertThrowsError(try localClient.get(url: "http://localhost:\(port)").wait()) { error in
            if isTestingNIOTS() {
                guard case ChannelError.connectTimeout = error else {
                    XCTFail("Unexpected error: \(error)")
                    return
                }
            } else {
                guard error is NIOConnectionError else {
                    XCTFail("Unexpected error: \(error)")
                    return
                }
            }
        }
    }

    func testAsyncShutdown() throws {
        let localClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup))
        let promise = self.clientGroup.next().makePromise(of: Void.self)
        self.clientGroup.next().execute {
            localClient.shutdown(queue: DispatchQueue(label: "testAsyncShutdown")) { error in
                XCTAssertNil(error)
                promise.succeed(())
            }
        }
        XCTAssertNoThrow(try promise.futureResult.wait())
    }

    func testValidationErrorsAreSurfaced() throws {
        let request = try HTTPClient.Request(url: self.defaultHTTPBinURLPrefix + "get", method: .TRACE, body: .stream { _ in
            self.defaultClient.eventLoopGroup.next().makeSucceededFuture(())
        })
        let runningRequest = self.defaultClient.execute(request: request)
        XCTAssertThrowsError(try runningRequest.wait()) { error in
            XCTAssertEqual(HTTPClientError.traceRequestWithBody, error as? HTTPClientError)
        }
    }

    func testUploadsReallyStream() {
        final class HTTPServer: ChannelInboundHandler {
            typealias InboundIn = HTTPServerRequestPart
            typealias OutboundOut = HTTPServerResponsePart

            private let headPromise: EventLoopPromise<HTTPRequestHead>
            private let bodyPromises: [EventLoopPromise<ByteBuffer>]
            private let endPromise: EventLoopPromise<Void>
            private var bodyPartsSeenSoFar = 0
            private var atEnd = false

            init(headPromise: EventLoopPromise<HTTPRequestHead>,
                 bodyPromises: [EventLoopPromise<ByteBuffer>],
                 endPromise: EventLoopPromise<Void>) {
                self.headPromise = headPromise
                self.bodyPromises = bodyPromises
                self.endPromise = endPromise
            }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                switch self.unwrapInboundIn(data) {
                case .head(let head):
                    XCTAssert(self.bodyPartsSeenSoFar == 0)
                    self.headPromise.succeed(head)
                case .body(let bytes):
                    let myNumber = self.bodyPartsSeenSoFar
                    self.bodyPartsSeenSoFar += 1
                    self.bodyPromises.dropFirst(myNumber).first?.succeed(bytes) ?? XCTFail("ouch, too many chunks")
                case .end:
                    context.write(self.wrapOutboundOut(.head(.init(version: .init(major: 1, minor: 1), status: .ok))),
                                  promise: nil)
                    context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: self.endPromise)
                    self.atEnd = true
                }
            }

            func handlerRemoved(context: ChannelHandlerContext) {
                guard !self.atEnd else {
                    return
                }
                struct NotFulfilledError: Error {}

                self.headPromise.fail(NotFulfilledError())
                self.bodyPromises.forEach {
                    $0.fail(NotFulfilledError())
                }
                self.endPromise.fail(NotFulfilledError())
            }
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }
        let client = HTTPClient(eventLoopGroupProvider: .shared(group))
        defer {
            XCTAssertNoThrow(try client.syncShutdown())
        }
        let headPromise = group.next().makePromise(of: HTTPRequestHead.self)
        let bodyPromises = (0..<16).map { _ in group.next().makePromise(of: ByteBuffer.self) }
        let endPromise = group.next().makePromise(of: Void.self)
        let sentOffAllBodyPartsPromise = group.next().makePromise(of: Void.self)
        let streamWriterPromise = group.next().makePromise(of: HTTPClient.Body.StreamWriter.self)

        func makeServer() -> Channel? {
            return try? ServerBootstrap(group: group)
                .childChannelInitializer { channel in
                    channel.pipeline.configureHTTPServerPipeline().flatMap {
                        channel.pipeline.addHandler(HTTPServer(headPromise: headPromise,
                                                               bodyPromises: bodyPromises,
                                                               endPromise: endPromise))
                    }
                }
                .serverChannelOption(ChannelOptions.socket(.init(SOL_SOCKET), .init(SO_REUSEADDR)), value: 1)
                .bind(host: "127.0.0.1", port: 0)
                .wait()
        }

        func makeRequest(server: Channel) -> Request? {
            guard let localAddress = server.localAddress else {
                return nil
            }

            return try? HTTPClient.Request(url: "http://\(localAddress.ipAddress!):\(localAddress.port!)",
                                           method: .POST,
                                           headers: ["transfer-encoding": "chunked"],
                                           body: .stream { streamWriter in
                                               streamWriterPromise.succeed(streamWriter)
                                               return sentOffAllBodyPartsPromise.futureResult
            })
        }

        guard let server = makeServer(), let request = makeRequest(server: server) else {
            XCTFail("couldn't make a server Channel and a matching Request...")
            return
        }
        defer {
            XCTAssertNoThrow(try server.close().wait())
        }

        var buffer = ByteBufferAllocator().buffer(capacity: 1)
        let runningRequest = client.execute(request: request)
        guard let streamWriter = try? streamWriterPromise.futureResult.wait() else {
            XCTFail("didn't get StreamWriter")
            return
        }

        XCTAssertNoThrow(XCTAssertEqual(.POST, try headPromise.futureResult.wait().method))
        for bodyChunkNumber in 0..<16 {
            buffer.clear()
            buffer.writeString(String(bodyChunkNumber, radix: 16))
            XCTAssertEqual(1, buffer.readableBytes)
            XCTAssertNoThrow(try streamWriter.write(.byteBuffer(buffer)).wait())
            XCTAssertNoThrow(XCTAssertEqual(buffer, try bodyPromises[bodyChunkNumber].futureResult.wait()))
        }
        sentOffAllBodyPartsPromise.succeed(())
        XCTAssertNoThrow(try endPromise.futureResult.wait())
        XCTAssertNoThrow(try runningRequest.wait())
    }

    func testUploadStreamingCallinToleratedFromOtsideEL() throws {
        let request = try HTTPClient.Request(url: self.defaultHTTPBinURLPrefix + "get", method: .POST, body: .stream(length: 4) { writer in
            let promise = self.defaultClient.eventLoopGroup.next().makePromise(of: Void.self)
            // We have to toleare callins from any thread
            DispatchQueue(label: "upload-streaming").async {
                writer.write(.byteBuffer(ByteBuffer.of(string: "1234"))).whenComplete { _ in
                    promise.succeed(())
                }
            }
            return promise.futureResult
        })
        XCTAssertNoThrow(try self.defaultClient.execute(request: request).wait())
    }

    func testWeHandleUsSendingACloseHeaderCorrectly() {
        guard let req1 = try? Request(url: self.defaultHTTPBinURLPrefix + "stats",
                                      method: .GET,
                                      headers: ["connection": "close"]),
            let statsBytes1 = try? self.defaultClient.execute(request: req1).wait().body,
            let stats1 = try? JSONDecoder().decode(RequestInfo.self, from: statsBytes1) else {
            XCTFail("request 1 didn't work")
            return
        }
        guard let statsBytes2 = try? self.defaultClient.get(url: self.defaultHTTPBinURLPrefix + "stats").wait().body,
            let stats2 = try? JSONDecoder().decode(RequestInfo.self, from: statsBytes2) else {
            XCTFail("request 2 didn't work")
            return
        }
        guard let statsBytes3 = try? self.defaultClient.get(url: self.defaultHTTPBinURLPrefix + "stats").wait().body,
            let stats3 = try? JSONDecoder().decode(RequestInfo.self, from: statsBytes3) else {
            XCTFail("request 3 didn't work")
            return
        }

        // req 1 and 2 cannot share the same connection (close header)
        XCTAssertEqual(stats1.connectionNumber + 1, stats2.connectionNumber)
        XCTAssertEqual(stats1.requestNumber + 1, stats2.requestNumber)

        // req 2 and 3 should share the same connection (keep-alive is default)
        XCTAssertEqual(stats2.requestNumber + 1, stats3.requestNumber)
        XCTAssertEqual(stats2.connectionNumber, stats3.connectionNumber)
    }

    func testWeHandleUsReceivingACloseHeaderCorrectly() {
        guard let req1 = try? Request(url: self.defaultHTTPBinURLPrefix + "stats",
                                      method: .GET,
                                      headers: ["X-Send-Back-Header-Connection": "close"]),
            let statsBytes1 = try? self.defaultClient.execute(request: req1).wait().body,
            let stats1 = try? JSONDecoder().decode(RequestInfo.self, from: statsBytes1) else {
            XCTFail("request 1 didn't work")
            return
        }
        guard let statsBytes2 = try? self.defaultClient.get(url: self.defaultHTTPBinURLPrefix + "stats").wait().body,
            let stats2 = try? JSONDecoder().decode(RequestInfo.self, from: statsBytes2) else {
            XCTFail("request 2 didn't work")
            return
        }
        guard let statsBytes3 = try? self.defaultClient.get(url: self.defaultHTTPBinURLPrefix + "stats").wait().body,
            let stats3 = try? JSONDecoder().decode(RequestInfo.self, from: statsBytes3) else {
            XCTFail("request 3 didn't work")
            return
        }

        // req 1 and 2 cannot share the same connection (close header)
        XCTAssertEqual(stats1.connectionNumber + 1, stats2.connectionNumber)
        XCTAssertEqual(stats1.requestNumber + 1, stats2.requestNumber)

        // req 2 and 3 should share the same connection (keep-alive is default)
        XCTAssertEqual(stats2.requestNumber + 1, stats3.requestNumber)
        XCTAssertEqual(stats2.connectionNumber, stats3.connectionNumber)
    }

    func testWeHandleUsSendingACloseHeaderAmongstOtherConnectionHeadersCorrectly() {
        for closeHeader in [("connection", "close"), ("CoNneCTION", "ClOSe")] {
            guard let req1 = try? Request(url: self.defaultHTTPBinURLPrefix + "stats",
                                          method: .GET,
                                          headers: ["X-Send-Back-Header-\(closeHeader.0)":
                                              "foo,\(closeHeader.1),bar"]),
                let statsBytes1 = try? self.defaultClient.execute(request: req1).wait().body,
                let stats1 = try? JSONDecoder().decode(RequestInfo.self, from: statsBytes1) else {
                XCTFail("request 1 didn't work")
                return
            }
            guard let statsBytes2 = try? self.defaultClient.get(url: self.defaultHTTPBinURLPrefix + "stats").wait().body,
                let stats2 = try? JSONDecoder().decode(RequestInfo.self, from: statsBytes2) else {
                XCTFail("request 2 didn't work")
                return
            }
            guard let statsBytes3 = try? self.defaultClient.get(url: self.defaultHTTPBinURLPrefix + "stats").wait().body,
                let stats3 = try? JSONDecoder().decode(RequestInfo.self, from: statsBytes3) else {
                XCTFail("request 3 didn't work")
                return
            }

            // req 1 and 2 cannot share the same connection (close header)
            XCTAssertEqual(stats1.connectionNumber + 1, stats2.connectionNumber)
            XCTAssertEqual(stats1.requestNumber + 1, stats2.requestNumber)

            // req 2 and 3 should share the same connection (keep-alive is default)
            XCTAssertEqual(stats2.requestNumber + 1, stats3.requestNumber)
            XCTAssertEqual(stats2.connectionNumber, stats3.connectionNumber)
        }
    }

    func testWeHandleUsReceivingACloseHeaderAmongstOtherConnectionHeadersCorrectly() {
        for closeHeader in [("connection", "close"), ("CoNneCTION", "ClOSe")] {
            guard let req1 = try? Request(url: self.defaultHTTPBinURLPrefix + "stats",
                                          method: .GET,
                                          headers: ["X-Send-Back-Header-\(closeHeader.0)":
                                              "foo,\(closeHeader.1),bar"]),
                let statsBytes1 = try? self.defaultClient.execute(request: req1).wait().body,
                let stats1 = try? JSONDecoder().decode(RequestInfo.self, from: statsBytes1) else {
                XCTFail("request 1 didn't work")
                return
            }
            guard let statsBytes2 = try? self.defaultClient.get(url: self.defaultHTTPBinURLPrefix + "stats").wait().body,
                let stats2 = try? JSONDecoder().decode(RequestInfo.self, from: statsBytes2) else {
                XCTFail("request 2 didn't work")
                return
            }
            guard let statsBytes3 = try? self.defaultClient.get(url: self.defaultHTTPBinURLPrefix + "stats").wait().body,
                let stats3 = try? JSONDecoder().decode(RequestInfo.self, from: statsBytes3) else {
                XCTFail("request 3 didn't work")
                return
            }

            // req 1 and 2 cannot share the same connection (close header)
            XCTAssertEqual(stats1.connectionNumber + 1, stats2.connectionNumber)
            XCTAssertEqual(stats1.requestNumber + 1, stats2.requestNumber)

            // req 2 and 3 should share the same connection (keep-alive is default)
            XCTAssertEqual(stats2.requestNumber + 1, stats3.requestNumber)
            XCTAssertEqual(stats2.connectionNumber, stats3.connectionNumber)
        }
    }

    func testLoggingCorrectlyAttachesRequestInformation() {
        let logStore = CollectEverythingLogHandler.LogStore()

        var loggerYolo001: Logger = Logger(label: "\(#function)", factory: { _ in
            CollectEverythingLogHandler(logStore: logStore)
        })
        loggerYolo001.logLevel = .trace
        loggerYolo001[metadataKey: "yolo-request-id"] = "yolo-001"
        var loggerACME002: Logger = Logger(label: "\(#function)", factory: { _ in
            CollectEverythingLogHandler(logStore: logStore)
        })
        loggerACME002.logLevel = .trace
        loggerACME002[metadataKey: "acme-request-id"] = "acme-002"

        guard let request1 = try? HTTPClient.Request(url: self.defaultHTTPBinURLPrefix + "get"),
            let request2 = try? HTTPClient.Request(url: self.defaultHTTPBinURLPrefix + "stats"),
            let request3 = try? HTTPClient.Request(url: self.defaultHTTPBinURLPrefix + "ok") else {
            XCTFail("bad stuff, can't even make request structures")
            return
        }

        // === Request 1 (Yolo001)
        XCTAssertNoThrow(try self.defaultClient.execute(request: request1,
                                                        eventLoop: .indifferent,
                                                        deadline: nil,
                                                        logger: loggerYolo001).wait())
        let logsAfterReq1 = logStore.allEntries
        logStore.allEntries = []

        // === Request 2 (Yolo001)
        XCTAssertNoThrow(try self.defaultClient.execute(request: request2,
                                                        eventLoop: .indifferent,
                                                        deadline: nil,
                                                        logger: loggerYolo001).wait())
        let logsAfterReq2 = logStore.allEntries
        logStore.allEntries = []

        // === Request 3 (ACME002)
        XCTAssertNoThrow(try self.defaultClient.execute(request: request3,
                                                        eventLoop: .indifferent,
                                                        deadline: nil,
                                                        logger: loggerACME002).wait())
        let logsAfterReq3 = logStore.allEntries
        logStore.allEntries = []

        // === Assertions
        XCTAssertGreaterThan(logsAfterReq1.count, 0)
        XCTAssertGreaterThan(logsAfterReq2.count, 0)
        XCTAssertGreaterThan(logsAfterReq3.count, 0)

        XCTAssert(logsAfterReq1.allSatisfy { entry in
            if let httpRequestMetadata = entry.metadata["ahc-request-id"],
                let yoloRequestID = entry.metadata["yolo-request-id"] {
                XCTAssertNil(entry.metadata["acme-request-id"])
                XCTAssertEqual("yolo-001", yoloRequestID)
                XCTAssertNotNil(Int(httpRequestMetadata))
                return true
            } else {
                XCTFail("log message doesn't contain the right IDs: \(entry)")
                return false
            }
        })
        XCTAssert(logsAfterReq1.contains { entry in
            entry.message == "opening fresh connection (no connections to reuse available)"
        })

        XCTAssert(logsAfterReq2.allSatisfy { entry in
            if let httpRequestMetadata = entry.metadata["ahc-request-id"],
                let yoloRequestID = entry.metadata["yolo-request-id"] {
                XCTAssertNil(entry.metadata["acme-request-id"])
                XCTAssertEqual("yolo-001", yoloRequestID)
                XCTAssertNotNil(Int(httpRequestMetadata))
                return true
            } else {
                XCTFail("log message doesn't contain the right IDs: \(entry)")
                return false
            }
        })
        XCTAssert(logsAfterReq2.contains { entry in
            entry.message.starts(with: "leasing existing connection")
        })

        XCTAssert(logsAfterReq3.allSatisfy { entry in
            if let httpRequestMetadata = entry.metadata["ahc-request-id"],
                let acmeRequestID = entry.metadata["acme-request-id"] {
                XCTAssertNil(entry.metadata["yolo-request-id"])
                XCTAssertEqual("acme-002", acmeRequestID)
                XCTAssertNotNil(Int(httpRequestMetadata))
                return true
            } else {
                XCTFail("log message doesn't contain the right IDs: \(entry)")
                return false
            }
        })
        XCTAssert(logsAfterReq3.contains { entry in
            entry.message.starts(with: "leasing existing connection")
        })
    }

    func testNothingIsLoggedAtInfoOrHigher() {
        let logStore = CollectEverythingLogHandler.LogStore()

        var logger: Logger = Logger(label: "\(#function)", factory: { _ in
            CollectEverythingLogHandler(logStore: logStore)
        })
        logger.logLevel = .info

        guard let request1 = try? HTTPClient.Request(url: self.defaultHTTPBinURLPrefix + "get"),
            let request2 = try? HTTPClient.Request(url: self.defaultHTTPBinURLPrefix + "stats") else {
            XCTFail("bad stuff, can't even make request structures")
            return
        }

        // === Request 1
        XCTAssertNoThrow(try self.defaultClient.execute(request: request1,
                                                        eventLoop: .indifferent,
                                                        deadline: nil,
                                                        logger: logger).wait())
        XCTAssertEqual(0, logStore.allEntries.count)

        // === Request 2
        XCTAssertNoThrow(try self.defaultClient.execute(request: request2,
                                                        eventLoop: .indifferent,
                                                        deadline: nil,
                                                        logger: logger).wait())
        XCTAssertEqual(0, logStore.allEntries.count)

        XCTAssertEqual(0, self.backgroundLogStore.allEntries.count)
    }

    func testAllMethodsLog() {
        func checkExpectationsWithLogger<T>(type: String, _ body: (Logger, String) throws -> T) throws -> T {
            let logStore = CollectEverythingLogHandler.LogStore()

            var logger: Logger = Logger(label: "\(#function)", factory: { _ in
                CollectEverythingLogHandler(logStore: logStore)
            })
            logger.logLevel = .trace
            logger[metadataKey: "req"] = "yo-\(type)"

            let url = self.defaultHTTPBinURLPrefix + "not-found/request/\(type))"
            let result = try body(logger, url)

            XCTAssertGreaterThan(logStore.allEntries.count, 0)
            logStore.allEntries.forEach { entry in
                XCTAssertEqual("yo-\(type)", entry.metadata["req"] ?? "n/a")
                XCTAssertNotNil(Int(entry.metadata["ahc-request-id"] ?? "n/a"))
            }
            return result
        }

        XCTAssertNoThrow(XCTAssertEqual(.notFound, try checkExpectationsWithLogger(type: "GET") { logger, url in
            try self.defaultClient.get(url: url, logger: logger).wait()
        }.status))

        XCTAssertNoThrow(XCTAssertEqual(.notFound, try checkExpectationsWithLogger(type: "PUT") { logger, url in
            try self.defaultClient.put(url: url, logger: logger).wait()
        }.status))

        XCTAssertNoThrow(XCTAssertEqual(.notFound, try checkExpectationsWithLogger(type: "POST") { logger, url in
            try self.defaultClient.post(url: url, logger: logger).wait()
        }.status))

        XCTAssertNoThrow(XCTAssertEqual(.notFound, try checkExpectationsWithLogger(type: "DELETE") { logger, url in
            try self.defaultClient.delete(url: url, logger: logger).wait()
        }.status))

        XCTAssertNoThrow(XCTAssertEqual(.notFound, try checkExpectationsWithLogger(type: "PATCH") { logger, url in
            try self.defaultClient.patch(url: url, logger: logger).wait()
        }.status))

        // No background activity expected here.
        XCTAssertEqual(0, self.backgroundLogStore.allEntries.count)
    }

    func testClosingIdleConnectionsInPoolLogsInTheBackground() {
        XCTAssertNoThrow(try self.defaultClient.get(url: self.defaultHTTPBinURLPrefix + "/get").wait())

        XCTAssertNoThrow(try self.defaultClient.syncShutdown())

        XCTAssertGreaterThanOrEqual(self.backgroundLogStore.allEntries.count, 0)
        XCTAssert(self.backgroundLogStore.allEntries.contains { entry in
            entry.message == "closing provider"
        })
        XCTAssert(self.backgroundLogStore.allEntries.allSatisfy { entry in
            entry.metadata["ahc-request-id"] == nil &&
                entry.metadata["ahc-request"] == nil &&
                entry.metadata["ahc-provider"] != nil
        })

        self.defaultClient = nil // so it doesn't get shut down again.
    }
}
