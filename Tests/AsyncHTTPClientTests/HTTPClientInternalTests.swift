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

import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import NIOFoundationCompat
import NIOHTTP1
import NIOPosix
import NIOTestUtils
import XCTest

@testable import AsyncHTTPClient

class HTTPClientInternalTests: XCTestCase {
    typealias Request = HTTPClient.Request
    typealias Task = HTTPClient.Task

    var serverGroup: EventLoopGroup!
    var clientGroup: EventLoopGroup!

    override func setUp() {
        XCTAssertNil(self.clientGroup)
        XCTAssertNil(self.serverGroup)
        self.serverGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.clientGroup = getDefaultEventLoopGroup(numberOfThreads: 1)
    }

    override func tearDown() {
        XCTAssertNotNil(self.serverGroup)
        XCTAssertNoThrow(try self.serverGroup.syncShutdownGracefully())
        XCTAssertNotNil(self.clientGroup)
        XCTAssertNoThrow(try self.clientGroup.syncShutdownGracefully())
        self.clientGroup = nil
        self.serverGroup = nil
    }

    func testProxyStreaming() throws {
        let httpBin = HTTPBin()
        let httpClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup))
        defer {
            XCTAssertNoThrow(try httpClient.syncShutdown(requiresCleanClose: true))
            XCTAssertNoThrow(try httpBin.shutdown())
        }

        let body: HTTPClient.Body = .stream(contentLength: 50) { writer in
            do {
                var request = try Request(url: "http://localhost:\(httpBin.port)/events/10/1")
                request.headers.add(name: "Accept", value: "text/event-stream")

                let delegate = HTTPClientCopyingDelegate { part in
                    writer.write(.byteBuffer(part))
                }
                return httpClient.execute(request: request, delegate: delegate).futureResult
            } catch {
                return httpClient.eventLoopGroup.next().makeFailedFuture(error)
            }
        }

        let upload = try! httpClient.post(url: "http://localhost:\(httpBin.port)/post", body: body).wait()
        let data = upload.body.flatMap { try? JSONDecoder().decode(RequestInfo.self, from: $0) }

        XCTAssertEqual(.ok, upload.status)
        XCTAssertEqual("id: 0id: 1id: 2id: 3id: 4id: 5id: 6id: 7id: 8id: 9", data?.data)
    }

    func testProxyStreamingFailure() throws {
        let httpBin = HTTPBin()
        let httpClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup))
        defer {
            XCTAssertNoThrow(try httpClient.syncShutdown())
            XCTAssertNoThrow(try httpBin.shutdown())
        }

        var body: HTTPClient.Body = .stream(contentLength: 50) { _ in
            httpClient.eventLoopGroup.next().makeFailedFuture(HTTPClientError.invalidProxyResponse)
        }

        XCTAssertThrowsError(try httpClient.post(url: "http://localhost:\(httpBin.port)/post", body: body).wait())

        body = .stream(contentLength: 50) { _ in
            do {
                var request = try Request(url: "http://localhost:\(httpBin.port)/events/10/1")
                request.headers.add(name: "Accept", value: "text/event-stream")

                let delegate = HTTPClientCopyingDelegate { _ in
                    httpClient.eventLoopGroup.next().makeFailedFuture(HTTPClientError.invalidProxyResponse)
                }
                return httpClient.execute(request: request, delegate: delegate).futureResult
            } catch {
                return httpClient.eventLoopGroup.next().makeFailedFuture(error)
            }
        }

        XCTAssertThrowsError(try httpClient.post(url: "http://localhost:\(httpBin.port)/post", body: body).wait())
    }

    func testRequestURITrailingSlash() throws {
        let request1 = try Request(url: "https://someserver.com:8888/some/path?foo=bar#ref")
        XCTAssertEqual(request1.url.uri, "/some/path?foo=bar")

        let request2 = try Request(url: "https://someserver.com:8888/some/path/?foo=bar#ref")
        XCTAssertEqual(request2.url.uri, "/some/path/?foo=bar")

        let request3 = try Request(url: "https://someserver.com:8888?foo=bar#ref")
        XCTAssertEqual(request3.url.uri, "/?foo=bar")

        let request4 = try Request(url: "https://someserver.com:8888/?foo=bar#ref")
        XCTAssertEqual(request4.url.uri, "/?foo=bar")

        let request5 = try Request(url: "https://someserver.com:8888/some/path")
        XCTAssertEqual(request5.url.uri, "/some/path")

        let request6 = try Request(url: "https://someserver.com:8888/some/path/")
        XCTAssertEqual(request6.url.uri, "/some/path/")

        let request7 = try Request(url: "https://someserver.com:8888")
        XCTAssertEqual(request7.url.uri, "/")

        let request8 = try Request(url: "https://someserver.com:8888/")
        XCTAssertEqual(request8.url.uri, "/")

        let request9 = try Request(url: "https://someserver.com:8888#ref")
        XCTAssertEqual(request9.url.uri, "/")

        let request10 = try Request(url: "https://someserver.com:8888/#ref")
        XCTAssertEqual(request10.url.uri, "/")

        let request11 = try Request(url: "https://someserver.com/some%20path")
        XCTAssertEqual(request11.url.uri, "/some%20path")

        let request12 = try Request(url: "https://someserver.com/some%2Fpathsegment1/pathsegment2")
        XCTAssertEqual(request12.url.uri, "/some%2Fpathsegment1/pathsegment2")
    }

    func testURIOfRelativeURLRequest() throws {
        let requestNoLeadingSlash = try Request(
            url: URL(
                string: "percent%2Fencoded/hello",
                relativeTo: URL(string: "http://127.0.0.1")!
            )!
        )

        let requestWithLeadingSlash = try Request(
            url: URL(
                string: "/percent%2Fencoded/hello",
                relativeTo: URL(string: "http://127.0.0.1")!
            )!
        )

        XCTAssertEqual(requestNoLeadingSlash.url.uri, "/percent%2Fencoded/hello")
        XCTAssertEqual(requestWithLeadingSlash.url.uri, "/percent%2Fencoded/hello")
    }

    func testChannelAndDelegateOnDifferentEventLoops() throws {
        final class Delegate: HTTPClientResponseDelegate {
            typealias Response = ([Message], [Message])

            enum Message: Sendable {
                case head(HTTPResponseHead)
                case bodyPart(ByteBuffer)
                case sentRequestHead(HTTPRequestHead)
                case sentRequestPart(IOData)
                case sentRequest
                case error(Error)
            }

            private struct Messages: Sendable {
                var received: [Message] = []
                var sent: [Message] = []
            }

            private let messages: NIOLoopBoundBox<Messages>

            var receivedMessages: [Message] {
                get {
                    self.messages.value.received
                }
                set {
                    self.messages.value.received = newValue
                }
            }
            var sentMessages: [Message] {
                get {
                    self.messages.value.sent
                }
                set {
                    self.messages.value.sent = newValue
                }
            }
            private let eventLoop: EventLoop
            private let randoEL: EventLoop

            init(expectedEventLoop: EventLoop, randomOtherEventLoop: EventLoop) {
                self.eventLoop = expectedEventLoop
                self.randoEL = randomOtherEventLoop
                self.messages = .makeBoxSendingValue(Messages(), eventLoop: expectedEventLoop)
            }

            func didSendRequestHead(task: HTTPClient.Task<Response>, _ head: HTTPRequestHead) {
                self.sentMessages.append(.sentRequestHead(head))
            }

            func didSendRequestPart(task: HTTPClient.Task<Response>, _ part: IOData) {
                self.sentMessages.append(.sentRequestPart(part))
            }

            func didSendRequest(task: HTTPClient.Task<Response>) {
                self.sentMessages.append(.sentRequest)
            }

            func didReceiveError(task: HTTPClient.Task<Response>, _ error: Error) {
                self.receivedMessages.append(.error(error))
            }

            public func didReceiveHead(
                task: HTTPClient.Task<Response>,
                _ head: HTTPResponseHead
            ) -> EventLoopFuture<Void> {
                self.receivedMessages.append(.head(head))
                return self.randoEL.makeSucceededFuture(())
            }

            func didReceiveBodyPart(
                task: HTTPClient.Task<Response>,
                _ buffer: ByteBuffer
            ) -> EventLoopFuture<Void> {
                self.receivedMessages.append(.bodyPart(buffer))
                return self.randoEL.makeSucceededFuture(())
            }

            func didFinishRequest(task: HTTPClient.Task<Response>) throws -> Response {
                (self.receivedMessages, self.sentMessages)
            }
        }

        let group = getDefaultEventLoopGroup(numberOfThreads: 3)
        let serverGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
            XCTAssertNoThrow(try serverGroup.syncShutdownGracefully())
        }

        let channelEL = group.next()
        let delegateEL = group.next()
        let randoEL = group.next()

        let httpClient = HTTPClient(eventLoopGroupProvider: .shared(group))
        let server = NIOHTTP1TestServer(group: serverGroup)
        defer {
            XCTAssertNoThrow(try server.stop())
            XCTAssertNoThrow(try httpClient.syncShutdown(requiresCleanClose: true))
        }

        let body: HTTPClient.Body = .stream(contentLength: 8) { writer in
            let buffer = ByteBuffer(string: "1234")
            return writer.write(.byteBuffer(buffer)).flatMap {
                let buffer = ByteBuffer(string: "4321")
                return writer.write(.byteBuffer(buffer))
            }
        }

        let request = try Request(
            url: "http://127.0.0.1:\(server.serverPort)/custom",
            body: body
        )
        let delegate = Delegate(expectedEventLoop: delegateEL, randomOtherEventLoop: randoEL)
        let future = httpClient.execute(
            request: request,
            delegate: delegate,
            eventLoop: .init(
                .testOnly_exact(
                    channelOn: channelEL,
                    delegateOn: delegateEL
                )
            )
        ).futureResult

        XCTAssertNoThrow(try server.readInbound())  // .head
        XCTAssertNoThrow(try server.readInbound())  // .body
        XCTAssertNoThrow(try server.readInbound())  // .end

        // Send 3 parts, but only one should be received until the future is complete
        XCTAssertNoThrow(
            try server.writeOutbound(
                .head(
                    .init(
                        version: .init(major: 1, minor: 1),
                        status: .ok,
                        headers: HTTPHeaders([("Transfer-Encoding", "chunked")])
                    )
                )
            )
        )
        let buffer = ByteBuffer(string: "1234")
        XCTAssertNoThrow(try server.writeOutbound(.body(.byteBuffer(buffer))))
        XCTAssertNoThrow(try server.writeOutbound(.end(nil)))

        let (receivedMessages, sentMessages) = try future.wait()
        XCTAssertEqual(2, receivedMessages.count)
        XCTAssertEqual(4, sentMessages.count)

        switch sentMessages.dropFirst(0).first {
        case .some(.sentRequestHead(let head)):
            XCTAssertEqual(request.url.uri, head.uri)
        default:
            XCTFail("wrong message")
        }

        switch sentMessages.dropFirst(1).first {
        case .some(.sentRequestPart(.byteBuffer(let buffer))):
            XCTAssertEqual("1234", String(decoding: buffer.readableBytesView, as: Unicode.UTF8.self))
        default:
            XCTFail("wrong message")
        }

        switch sentMessages.dropFirst(2).first {
        case .some(.sentRequestPart(.byteBuffer(let buffer))):
            XCTAssertEqual("4321", String(decoding: buffer.readableBytesView, as: Unicode.UTF8.self))
        default:
            XCTFail("wrong message")
        }

        switch sentMessages.dropFirst(3).first {
        case .some(.sentRequest):
            ()  // OK
        default:
            XCTFail("wrong message")
        }

        switch receivedMessages.dropFirst(0).first {
        case .some(.head(let head)):
            XCTAssertEqual(head.headers["transfer-encoding"].first, "chunked")
        default:
            XCTFail("wrong message")
        }

        switch receivedMessages.dropFirst(1).first {
        case .some(.bodyPart(let buffer)):
            XCTAssertEqual("1234", String(decoding: buffer.readableBytesView, as: Unicode.UTF8.self))
        default:
            XCTFail("wrong message")
        }
    }

    func testResponseFutureIsOnCorrectEL() throws {
        let group = getDefaultEventLoopGroup(numberOfThreads: 4)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }
        let client = HTTPClient(eventLoopGroupProvider: .shared(group))
        let httpBin = HTTPBin()
        defer {
            XCTAssertNoThrow(try client.syncShutdown())
            XCTAssertNoThrow(try httpBin.shutdown())
        }

        let request = try HTTPClient.Request(url: "http://localhost:\(httpBin.port)/get")
        var futures = [EventLoopFuture<HTTPClient.Response>]()
        for _ in 1...100 {
            let el = group.next()
            let req1 = client.execute(request: request, eventLoop: .delegate(on: el))
            let req2 = client.execute(request: request, eventLoop: .delegateAndChannel(on: el))
            let req3 = client.execute(
                request: request,
                eventLoop: .init(.testOnly_exact(channelOn: el, delegateOn: el))
            )
            XCTAssert(req1.eventLoop === el)
            XCTAssert(req2.eventLoop === el)
            XCTAssert(req3.eventLoop === el)
            futures.append(contentsOf: [req1, req2, req3])
        }
        try EventLoopFuture<HTTPClient.Response>.andAllComplete(futures, on: group.next()).wait()
    }

    func testUncleanCloseThrows() {
        let server = NIOHTTP1TestServer(group: self.serverGroup)
        defer {
            XCTAssertNoThrow(try server.stop())
        }

        let httpClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup))

        _ = httpClient.get(url: "http://localhost:\(server.serverPort)/wait")

        XCTAssertNoThrow(try server.readInbound())  // .head
        XCTAssertNoThrow(try server.readInbound())  // .end

        do {
            try httpClient.syncShutdown(requiresCleanClose: true)
            XCTFail("There should be an error on shutdown")
        } catch {
            guard let clientError = error as? HTTPClientError, clientError == .uncleanShutdown else {
                XCTFail("Unexpected shutdown error: \(error)")
                return
            }
        }
    }

    func testUploadStreamingIsCalledOnTaskEL() throws {
        let group = getDefaultEventLoopGroup(numberOfThreads: 4)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        let httpBin = HTTPBin()
        let httpClient = HTTPClient(eventLoopGroupProvider: .shared(group))
        defer {
            XCTAssertNoThrow(try httpClient.syncShutdown())
            XCTAssertNoThrow(try httpBin.shutdown())
        }

        let el1 = group.next()
        let el2 = group.next()
        XCTAssert(el1 !== el2)

        let body: HTTPClient.Body = .stream(contentLength: 8) { writer in
            XCTAssert(el1.inEventLoop)
            let buffer = ByteBuffer(string: "1234")
            return writer.write(.byteBuffer(buffer)).flatMap {
                XCTAssert(el1.inEventLoop)
                let buffer = ByteBuffer(string: "4321")
                return writer.write(.byteBuffer(buffer))
            }
        }
        let request = try HTTPClient.Request(url: "http://localhost:\(httpBin.port)/post", method: .POST, body: body)
        let response = httpClient.execute(
            request: request,
            delegate: ResponseAccumulator(request: request),
            eventLoop: HTTPClient.EventLoopPreference(
                .testOnly_exact(
                    channelOn: el2,
                    delegateOn: el1
                )
            )
        )
        XCTAssert(el1 === response.eventLoop)
        XCTAssertNoThrow(try response.wait())
    }

    func testTaskPromiseBoundToEL() throws {
        let elg = getDefaultEventLoopGroup(numberOfThreads: 2)
        let el1 = elg.next()
        let el2 = elg.next()

        let httpBin = HTTPBin()
        let client = HTTPClient(eventLoopGroupProvider: .shared(elg))

        defer {
            XCTAssertNoThrow(try client.syncShutdown())
            XCTAssertNoThrow(try httpBin.shutdown())
            XCTAssertNoThrow(try elg.syncShutdownGracefully())
        }

        let request = try HTTPClient.Request(url: "http://localhost:\(httpBin.port)//get")
        let delegate = ResponseAccumulator(request: request)
        let task = client.execute(
            request: request,
            delegate: delegate,
            eventLoop: .init(.testOnly_exact(channelOn: el1, delegateOn: el2))
        )
        XCTAssertTrue(task.futureResult.eventLoop === el2)
        XCTAssertNoThrow(try task.wait())
    }

    func testConnectErrorCalloutOnCorrectEL() throws {
        final class TestDelegate: HTTPClientResponseDelegate {
            typealias Response = Void

            let expectedEL: EventLoop
            let _receivedError = NIOLockedValueBox(false)

            var receivedError: Bool {
                self._receivedError.withLockedValue { $0 }
            }

            init(expectedEL: EventLoop) {
                self.expectedEL = expectedEL
            }

            func didFinishRequest(task: HTTPClient.Task<Void>) throws {}

            func didReceiveError(task: HTTPClient.Task<Void>, _ error: Error) {
                self._receivedError.withLockedValue { $0 = true }
                XCTAssertTrue(self.expectedEL.inEventLoop)
            }
        }

        let elg = getDefaultEventLoopGroup(numberOfThreads: 2)
        let el1 = elg.next()
        let el2 = elg.next()

        let httpBin = HTTPBin(.refuse)
        let config = HTTPClient.Configuration()
            .enableFastFailureModeForTesting()
        let client = HTTPClient(eventLoopGroupProvider: .shared(elg), configuration: config)

        defer {
            XCTAssertNoThrow(try client.syncShutdown())
            XCTAssertNoThrow(try elg.syncShutdownGracefully())
        }

        let request = try HTTPClient.Request(url: "http://localhost:\(httpBin.port)/get")
        let delegate = TestDelegate(expectedEL: el1)
        XCTAssertNoThrow(try httpBin.shutdown())
        let task = client.execute(
            request: request,
            delegate: delegate,
            eventLoop: .init(.testOnly_exact(channelOn: el2, delegateOn: el1))
        )
        XCTAssertThrowsError(try task.wait())
        XCTAssertTrue(delegate.receivedError)
    }

    func testInternalRequestURI() throws {
        let request1 = try Request(url: "https://someserver.com:8888/some/path?foo=bar")
        XCTAssertEqual(request1.deconstructedURL.scheme, .https)
        XCTAssertEqual(request1.deconstructedURL.connectionTarget, .domain(name: "someserver.com", port: 8888))
        XCTAssertEqual(request1.deconstructedURL.uri, "/some/path?foo=bar")

        let request2 = try Request(url: "https://someserver.com")
        XCTAssertEqual(request2.deconstructedURL.scheme, .https)
        XCTAssertEqual(request2.deconstructedURL.connectionTarget, .domain(name: "someserver.com", port: 443))
        XCTAssertEqual(request2.deconstructedURL.uri, "/")

        let request3 = try Request(url: "unix:///tmp/file")
        XCTAssertEqual(request3.deconstructedURL.scheme, .unix)
        XCTAssertEqual(request3.deconstructedURL.connectionTarget, .unixSocket(path: "/tmp/file"))
        XCTAssertEqual(request3.deconstructedURL.uri, "/")

        let request4 = try Request(url: "http+unix://%2Ftmp%2Ffile/file/path")
        XCTAssertEqual(request4.deconstructedURL.scheme, .httpUnix)
        XCTAssertEqual(request4.deconstructedURL.connectionTarget, .unixSocket(path: "/tmp/file"))
        XCTAssertEqual(request4.deconstructedURL.uri, "/file/path")

        let request5 = try Request(url: "https+unix://%2Ftmp%2Ffile/file/path")
        XCTAssertEqual(request5.deconstructedURL.scheme, .httpsUnix)
        XCTAssertEqual(request5.deconstructedURL.connectionTarget, .unixSocket(path: "/tmp/file"))
        XCTAssertEqual(request5.deconstructedURL.uri, "/file/path")

        let request6 = try Request(url: "https://127.0.0.1")
        XCTAssertEqual(request6.deconstructedURL.scheme, .https)
        XCTAssertEqual(
            request6.deconstructedURL.connectionTarget,
            .ipAddress(
                serialization: "127.0.0.1",
                address: try! SocketAddress(ipAddress: "127.0.0.1", port: 443)
            )
        )
        XCTAssertEqual(request6.deconstructedURL.uri, "/")

        let request7 = try Request(url: "https://0x7F.1:9999")
        XCTAssertEqual(request7.deconstructedURL.scheme, .https)
        XCTAssertEqual(request7.deconstructedURL.connectionTarget, .domain(name: "0x7F.1", port: 9999))
        XCTAssertEqual(request7.deconstructedURL.uri, "/")

        let request8 = try Request(url: "http://[::1]")
        XCTAssertEqual(request8.deconstructedURL.scheme, .http)
        XCTAssertEqual(
            request8.deconstructedURL.connectionTarget,
            .ipAddress(
                serialization: "[::1]",
                address: try! SocketAddress(ipAddress: "::1", port: 80)
            )
        )
        XCTAssertEqual(request8.deconstructedURL.uri, "/")

        let request9 = try Request(url: "http://[763e:61d9::6ACA:3100:6274]:4242/foo/bar?baz")
        XCTAssertEqual(request9.deconstructedURL.scheme, .http)
        XCTAssertEqual(
            request9.deconstructedURL.connectionTarget,
            .ipAddress(
                serialization: "[763e:61d9::6ACA:3100:6274]",
                address: try! SocketAddress(ipAddress: "763e:61d9::6aca:3100:6274", port: 4242)
            )
        )
        XCTAssertEqual(request9.deconstructedURL.uri, "/foo/bar?baz")

        // Some systems have quirks in their implementations of 'ntop' which cause them to write
        // certain IPv6 addresses with embedded IPv4 parts (e.g. "::192.168.0.1" vs "::c0a8:1").
        // We want to make sure that our request formatting doesn't depend on the platform's quirks,
        // so the serialization must be kept verbatim as it was given in the request.
        let request10 = try Request(url: "http://[::c0a8:1]:4242/foo/bar?baz")
        XCTAssertEqual(request10.deconstructedURL.scheme, .http)
        XCTAssertEqual(
            request10.deconstructedURL.connectionTarget,
            .ipAddress(
                serialization: "[::c0a8:1]",
                address: try! SocketAddress(ipAddress: "::c0a8:1", port: 4242)
            )
        )
        XCTAssertEqual(request10.deconstructedURL.uri, "/foo/bar?baz")

        let request11 = try Request(url: "http://[::192.168.0.1]:4242/foo/bar?baz")
        XCTAssertEqual(request11.deconstructedURL.scheme, .http)
        XCTAssertEqual(
            request11.deconstructedURL.connectionTarget,
            .ipAddress(
                serialization: "[::192.168.0.1]",
                address: try! SocketAddress(ipAddress: "::192.168.0.1", port: 4242)
            )
        )
        XCTAssertEqual(request11.deconstructedURL.uri, "/foo/bar?baz")
    }

    func testHasSuffix() {
        // Simple collection.
        do {
            let elements = (0...10)
            XCTAssertTrue(elements.hasSuffix([8, 9, 10]))
            XCTAssertTrue(elements.hasSuffix([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10]))
            XCTAssertTrue(elements.hasSuffix([10]))
            XCTAssertTrue(elements.hasSuffix([]))

            XCTAssertFalse(elements.hasSuffix([8, 9, 10, 11]))
            XCTAssertFalse(elements.hasSuffix([0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10]))
            XCTAssertFalse(elements.hasSuffix([9]))
            XCTAssertFalse(elements.hasSuffix([0]))
        }
        // Single-element collection.
        do {
            let elements = [99]
            XCTAssertTrue(elements.hasSuffix(["99"].lazy.map { Int($0)! }))
            XCTAssertTrue(elements.hasSuffix([]))
            XCTAssertFalse(elements.hasSuffix([98, 99]))
            XCTAssertFalse(elements.hasSuffix([99, 99]))
            XCTAssertFalse(elements.hasSuffix([99, 100]))
        }
        // Empty collection.
        do {
            let elements: [Int] = []
            XCTAssertTrue(elements.hasSuffix([]))
            XCTAssertFalse(elements.hasSuffix([0]))
            XCTAssertFalse(elements.hasSuffix([42]))
            XCTAssertFalse(elements.hasSuffix([0, 0, 0]))
        }
    }

    /// test to verify that we actually share the same thread pool across all ``FileDownloadDelegate``s for a given ``HTTPClient``
    func testSharedThreadPoolIsIdenticalForAllDelegates() throws {
        let httpBin = HTTPBin()
        let httpClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup))
        defer {
            XCTAssertNoThrow(try httpClient.syncShutdown(requiresCleanClose: true))
            XCTAssertNoThrow(try httpBin.shutdown())
        }
        var request = try Request(url: "http://localhost:\(httpBin.port)/events/10/content-length")
        request.headers.add(name: "Accept", value: "text/event-stream")

        let filePaths = (0..<10).map { _ in
            TemporaryFileHelpers.makeTemporaryFilePath()
        }
        defer {
            for filePath in filePaths {
                TemporaryFileHelpers.removeTemporaryFile(at: filePath)
            }
        }
        let delegates = try filePaths.map {
            try FileDownloadDelegate(path: $0)
        }

        let resultFutures = delegates.map { delegate in
            httpClient.execute(
                request: request,
                delegate: delegate
            ).futureResult
        }
        _ = try EventLoopFuture.whenAllSucceed(resultFutures, on: self.clientGroup.next()).wait()

        let threadPools = delegates.map { $0._fileIOThreadPool }
        let firstThreadPool = threadPools.first ?? nil
        XCTAssert(threadPools.dropFirst().allSatisfy { $0 === firstThreadPool })
    }
}

extension HTTPClient.Configuration {
    func enableFastFailureModeForTesting() -> Self {
        var copy = self
        copy.networkFrameworkWaitForConnectivity = false
        copy.connectionPool.retryConnectionEstablishment = false
        return copy
    }
}
