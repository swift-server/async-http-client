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

import AsyncHTTPClient  // NOT @testable - tests that need @testable go into HTTPClientInternalTests.swift
import Atomics
import InMemoryLogging
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import NIOFoundationCompat
import NIOHTTP1
import NIOHTTP2
import NIOHTTPCompression
import NIOPosix
import NIOSSL
import NIOTestUtils
import NIOTransportServices
import XCTest

#if canImport(Network)
import Network
#endif

final class HTTPClientTests: XCTestCaseHTTPClientTestsBaseClass {
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
        XCTAssertEqual(request3.host, "")
        #if os(Linux) && compiler(<6.1)
        XCTAssertEqual(request3.url.host, "")
        #else
        XCTAssertNil(request3.url.host)
        #endif
        XCTAssertEqual(request3.url.path, "/tmp/file")
        XCTAssertEqual(request3.port, 80)
        XCTAssertFalse(request3.useTLS)

        let request4 = try Request(url: "http+unix://%2Ftmp%2Ffile/file/path")
        XCTAssertEqual(request4.host, "")
        XCTAssertEqual(request4.url.host, "/tmp/file")
        XCTAssertEqual(request4.url.path, "/file/path")
        XCTAssertFalse(request4.useTLS)

        let request5 = try Request(url: "https+unix://%2Ftmp%2Ffile/file/path")
        XCTAssertEqual(request5.host, "")
        XCTAssertEqual(request5.url.host, "/tmp/file")
        XCTAssertEqual(request5.url.path, "/file/path")
        XCTAssertTrue(request5.useTLS)
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
        XCTAssertThrowsError(try Request(url: "http+unix:///path"), "should throw") { error in
            XCTAssertEqual(error as! HTTPClientError, HTTPClientError.missingSocketPath)
        }
    }

    func testSchemaCasing() throws {
        XCTAssertNoThrow(try Request(url: "hTTpS://someserver.com:8888/some/path?foo=bar"))
        XCTAssertNoThrow(try Request(url: "uNIx:///some/path"))
        XCTAssertNoThrow(try Request(url: "hTtP+uNIx://%2Fsome%2Fpath/"))
        XCTAssertNoThrow(try Request(url: "hTtPS+uNIx://%2Fsome%2Fpath/"))
    }

    func testURLSocketPathInitializers() throws {
        let url1 = URL(httpURLWithSocketPath: "/tmp/file")
        XCTAssertNotNil(url1)
        if let url = url1 {
            XCTAssertEqual(url.scheme, "http+unix")
            XCTAssertEqual(url.host, "/tmp/file")
            XCTAssertEqual(url.path, "/")
            XCTAssertEqual(url.absoluteString, "http+unix://%2Ftmp%2Ffile/")
        }

        let url2 = URL(httpURLWithSocketPath: "/tmp/file", uri: "/file/path")
        XCTAssertNotNil(url2)
        if let url = url2 {
            XCTAssertEqual(url.scheme, "http+unix")
            XCTAssertEqual(url.host, "/tmp/file")
            XCTAssertEqual(url.path, "/file/path")
            XCTAssertEqual(url.absoluteString, "http+unix://%2Ftmp%2Ffile/file/path")
        }

        let url3 = URL(httpURLWithSocketPath: "/tmp/file", uri: "file/path")
        XCTAssertNotNil(url3)
        if let url = url3 {
            XCTAssertEqual(url.scheme, "http+unix")
            XCTAssertEqual(url.host, "/tmp/file")
            XCTAssertEqual(url.path, "/file/path")
            XCTAssertEqual(url.absoluteString, "http+unix://%2Ftmp%2Ffile/file/path")
        }

        let url4 = URL(httpURLWithSocketPath: "/tmp/file with spacesと漢字", uri: "file/path")
        XCTAssertNotNil(url4)
        if let url = url4 {
            XCTAssertEqual(url.scheme, "http+unix")
            XCTAssertEqual(url.host, "/tmp/file with spacesと漢字")
            XCTAssertEqual(url.path, "/file/path")
            XCTAssertEqual(
                url.absoluteString,
                "http+unix://%2Ftmp%2Ffile%20with%20spaces%E3%81%A8%E6%BC%A2%E5%AD%97/file/path"
            )
        }

        let url5 = URL(httpsURLWithSocketPath: "/tmp/file")
        XCTAssertNotNil(url5)
        if let url = url5 {
            XCTAssertEqual(url.scheme, "https+unix")
            XCTAssertEqual(url.host, "/tmp/file")
            XCTAssertEqual(url.path, "/")
            XCTAssertEqual(url.absoluteString, "https+unix://%2Ftmp%2Ffile/")
        }

        let url6 = URL(httpsURLWithSocketPath: "/tmp/file", uri: "/file/path")
        XCTAssertNotNil(url6)
        if let url = url6 {
            XCTAssertEqual(url.scheme, "https+unix")
            XCTAssertEqual(url.host, "/tmp/file")
            XCTAssertEqual(url.path, "/file/path")
            XCTAssertEqual(url.absoluteString, "https+unix://%2Ftmp%2Ffile/file/path")
        }

        let url7 = URL(httpsURLWithSocketPath: "/tmp/file", uri: "file/path")
        XCTAssertNotNil(url7)
        if let url = url7 {
            XCTAssertEqual(url.scheme, "https+unix")
            XCTAssertEqual(url.host, "/tmp/file")
            XCTAssertEqual(url.path, "/file/path")
            XCTAssertEqual(url.absoluteString, "https+unix://%2Ftmp%2Ffile/file/path")
        }

        let url8 = URL(httpsURLWithSocketPath: "/tmp/file with spacesと漢字", uri: "file/path")
        XCTAssertNotNil(url8)
        if let url = url8 {
            XCTAssertEqual(url.scheme, "https+unix")
            XCTAssertEqual(url.host, "/tmp/file with spacesと漢字")
            XCTAssertEqual(url.path, "/file/path")
            XCTAssertEqual(
                url.absoluteString,
                "https+unix://%2Ftmp%2Ffile%20with%20spaces%E3%81%A8%E6%BC%A2%E5%AD%97/file/path"
            )
        }
    }

    func testBadUnixWithBaseURL() {
        let badUnixBaseURL = URL(string: "/foo", relativeTo: URL(string: "unix:")!)!
        XCTAssertEqual(badUnixBaseURL.baseURL?.path, "")
        XCTAssertThrowsError(try Request(url: badUnixBaseURL)) { error in
            XCTAssertEqual(error as! HTTPClientError, HTTPClientError.missingSocketPath)
        }
    }

    func testConvenienceExecuteMethods() throws {
        XCTAssertEqual(
            ["GET"[...]],
            try self.defaultClient.get(url: self.defaultHTTPBinURLPrefix + "echo-method").wait().headers[
                canonicalForm: "X-Method-Used"
            ]
        )
        XCTAssertEqual(
            ["POST"[...]],
            try self.defaultClient.post(url: self.defaultHTTPBinURLPrefix + "echo-method").wait().headers[
                canonicalForm: "X-Method-Used"
            ]
        )
        XCTAssertEqual(
            ["PATCH"[...]],
            try self.defaultClient.patch(url: self.defaultHTTPBinURLPrefix + "echo-method").wait().headers[
                canonicalForm: "X-Method-Used"
            ]
        )
        XCTAssertEqual(
            ["PUT"[...]],
            try self.defaultClient.put(url: self.defaultHTTPBinURLPrefix + "echo-method").wait().headers[
                canonicalForm: "X-Method-Used"
            ]
        )
        XCTAssertEqual(
            ["DELETE"[...]],
            try self.defaultClient.delete(url: self.defaultHTTPBinURLPrefix + "echo-method").wait().headers[
                canonicalForm: "X-Method-Used"
            ]
        )
        XCTAssertEqual(
            ["GET"[...]],
            try self.defaultClient.execute(url: self.defaultHTTPBinURLPrefix + "echo-method").wait().headers[
                canonicalForm: "X-Method-Used"
            ]
        )
        XCTAssertEqual(
            ["CHECKOUT"[...]],
            try self.defaultClient.execute(.CHECKOUT, url: self.defaultHTTPBinURLPrefix + "echo-method").wait().headers[
                canonicalForm: "X-Method-Used"
            ]
        )
    }

    func testConvenienceExecuteMethodsOverSocket() throws {
        XCTAssertNoThrow(
            try TemporaryFileHelpers.withTemporaryUnixDomainSocketPathName { path in
                let localSocketPathHTTPBin = HTTPBin(bindTarget: .unixDomainSocket(path))
                defer {
                    XCTAssertNoThrow(try localSocketPathHTTPBin.shutdown())
                }

                XCTAssertEqual(
                    ["GET"[...]],
                    try self.defaultClient.execute(socketPath: path, urlPath: "echo-method").wait().headers[
                        canonicalForm: "X-Method-Used"
                    ]
                )
                XCTAssertEqual(
                    ["GET"[...]],
                    try self.defaultClient.execute(.GET, socketPath: path, urlPath: "echo-method").wait().headers[
                        canonicalForm: "X-Method-Used"
                    ]
                )
                XCTAssertEqual(
                    ["POST"[...]],
                    try self.defaultClient.execute(.POST, socketPath: path, urlPath: "echo-method").wait().headers[
                        canonicalForm: "X-Method-Used"
                    ]
                )
            }
        )
    }

    func testConvenienceExecuteMethodsOverSecureSocket() throws {
        XCTAssertNoThrow(
            try TemporaryFileHelpers.withTemporaryUnixDomainSocketPathName { path in
                let localSocketPathHTTPBin = HTTPBin(
                    .http1_1(ssl: true, compress: false),
                    bindTarget: .unixDomainSocket(path)
                )
                let localClient = HTTPClient(
                    eventLoopGroupProvider: .shared(self.clientGroup),
                    configuration: HTTPClient.Configuration(certificateVerification: .none)
                )
                defer {
                    XCTAssertNoThrow(try localClient.syncShutdown())
                    XCTAssertNoThrow(try localSocketPathHTTPBin.shutdown())
                }

                XCTAssertEqual(
                    ["GET"[...]],
                    try localClient.execute(secureSocketPath: path, urlPath: "echo-method").wait().headers[
                        canonicalForm: "X-Method-Used"
                    ]
                )
                XCTAssertEqual(
                    ["GET"[...]],
                    try localClient.execute(.GET, secureSocketPath: path, urlPath: "echo-method").wait().headers[
                        canonicalForm: "X-Method-Used"
                    ]
                )
                XCTAssertEqual(
                    ["POST"[...]],
                    try localClient.execute(.POST, secureSocketPath: path, urlPath: "echo-method").wait().headers[
                        canonicalForm: "X-Method-Used"
                    ]
                )
            }
        )
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
        let response = try self.defaultClient.post(url: self.defaultHTTPBinURLPrefix + "post", body: .string("1234"))
            .wait()
        let bytes = response.body.flatMap { $0.getData(at: 0, length: $0.readableBytes) }
        let data = try JSONDecoder().decode(RequestInfo.self, from: bytes!)

        XCTAssertEqual(.ok, response.status)
        XCTAssertEqual("1234", data.data)
    }

    func testPostWithGenericBody() throws {
        let bodyData = Array(Array("hello, world!").lazy.map { $0.uppercased().first!.asciiValue! })

        let response = try self.defaultClient.post(url: self.defaultHTTPBinURLPrefix + "post", body: .bytes(bodyData))
            .wait()
        let bytes = response.body.flatMap { $0.getData(at: 0, length: $0.readableBytes) }
        let data = try JSONDecoder().decode(RequestInfo.self, from: bytes!)

        XCTAssertEqual(.ok, response.status)
        XCTAssertEqual("HELLO, WORLD!", data.data)
    }

    func testPostWithFoundationDataBody() throws {
        let bodyData = Data("hello, world!".utf8)

        let response = try self.defaultClient.post(url: self.defaultHTTPBinURLPrefix + "post", body: .data(bodyData))
            .wait()
        let bytes = response.body.flatMap { $0.getData(at: 0, length: $0.readableBytes) }
        let data = try JSONDecoder().decode(RequestInfo.self, from: bytes!)

        XCTAssertEqual(.ok, response.status)
        XCTAssertEqual("hello, world!", data.data)
    }

    func testGetHttps() throws {
        let localHTTPBin = HTTPBin(.http1_1(ssl: true))
        let localClient = HTTPClient(
            eventLoopGroupProvider: .shared(self.clientGroup),
            configuration: HTTPClient.Configuration(certificateVerification: .none)
        )
        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            XCTAssertNoThrow(try localHTTPBin.shutdown())
        }

        let response = try localClient.get(url: "https://localhost:\(localHTTPBin.port)/get").wait()
        XCTAssertEqual(.ok, response.status)
    }

    func testGetHttpsWithIP() throws {
        let localHTTPBin = HTTPBin(.http1_1(ssl: true))
        let localClient = HTTPClient(
            eventLoopGroupProvider: .shared(self.clientGroup),
            configuration: HTTPClient.Configuration(certificateVerification: .none)
        )
        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            XCTAssertNoThrow(try localHTTPBin.shutdown())
        }

        let response = try localClient.get(url: "https://127.0.0.1:\(localHTTPBin.port)/get").wait()
        XCTAssertEqual(.ok, response.status)
    }

    func testGetHTTPSWorksOnMTELGWithIP() throws {
        // Same test as above but this one will use NIO on Sockets even on Apple platforms, just to make sure
        // this works.
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }
        let localHTTPBin = HTTPBin(.http1_1(ssl: true))
        let localClient = HTTPClient(
            eventLoopGroupProvider: .shared(group),
            configuration: HTTPClient.Configuration(certificateVerification: .none)
        )
        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            XCTAssertNoThrow(try localHTTPBin.shutdown())
        }

        let response = try localClient.get(url: "https://127.0.0.1:\(localHTTPBin.port)/get").wait()
        XCTAssertEqual(.ok, response.status)
    }

    func testGetHttpsWithIPv6() throws {
        try XCTSkipUnless(canBindIPv6Loopback, "Requires IPv6")
        let localHTTPBin = HTTPBin(.http1_1(ssl: true), bindTarget: .localhostIPv6RandomPort)
        let localClient = HTTPClient(
            eventLoopGroupProvider: .shared(self.clientGroup),
            configuration: HTTPClient.Configuration(certificateVerification: .none)
        )
        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            XCTAssertNoThrow(try localHTTPBin.shutdown())
        }
        var response: HTTPClient.Response?
        XCTAssertNoThrow(response = try localClient.get(url: "https://[::1]:\(localHTTPBin.port)/get").wait())
        XCTAssertEqual(.ok, response?.status)
    }

    func testGetHTTPSWorksOnMTELGWithIPv6() throws {
        try XCTSkipUnless(canBindIPv6Loopback, "Requires IPv6")
        // Same test as above but this one will use NIO on Sockets even on Apple platforms, just to make sure
        // this works.
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }
        let localHTTPBin = HTTPBin(.http1_1(ssl: true), bindTarget: .localhostIPv6RandomPort)
        let localClient = HTTPClient(
            eventLoopGroupProvider: .shared(group),
            configuration: HTTPClient.Configuration(certificateVerification: .none)
        )
        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            XCTAssertNoThrow(try localHTTPBin.shutdown())
        }
        var response: HTTPClient.Response?
        XCTAssertNoThrow(response = try localClient.get(url: "https://[::1]:\(localHTTPBin.port)/get").wait())
        XCTAssertEqual(.ok, response?.status)
    }

    func testPostHttps() throws {
        let localHTTPBin = HTTPBin(.http1_1(ssl: true))
        let localClient = HTTPClient(
            eventLoopGroupProvider: .shared(self.clientGroup),
            configuration: HTTPClient.Configuration(certificateVerification: .none)
        )
        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            XCTAssertNoThrow(try localHTTPBin.shutdown())
        }

        let request = try Request(
            url: "https://localhost:\(localHTTPBin.port)/post",
            method: .POST,
            body: .string("1234")
        )

        let response = try localClient.execute(request: request).wait()
        let bytes = response.body.flatMap { $0.getData(at: 0, length: $0.readableBytes) }
        let data = try JSONDecoder().decode(RequestInfo.self, from: bytes!)

        XCTAssertEqual(.ok, response.status)
        XCTAssertEqual("1234", data.data)
    }

    func testHttpRedirect() throws {
        let httpsBin = HTTPBin(.http1_1(ssl: true))
        let localClient = HTTPClient(
            eventLoopGroupProvider: .shared(self.clientGroup),
            configuration: HTTPClient.Configuration(
                certificateVerification: .none,
                redirectConfiguration: .follow(max: 10, allowCycles: true)
            )
        )

        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            XCTAssertNoThrow(try httpsBin.shutdown())
        }

        var response = try localClient.get(url: self.defaultHTTPBinURLPrefix + "redirect/302").wait()
        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(response.url?.absoluteString, self.defaultHTTPBinURLPrefix + "ok")
        XCTAssertEqual(
            response.history.map(\.request.url.absoluteString),
            [
                self.defaultHTTPBinURLPrefix + "redirect/302",
                self.defaultHTTPBinURLPrefix + "ok",
            ]
        )

        response = try localClient.get(url: self.defaultHTTPBinURLPrefix + "redirect/https?port=\(httpsBin.port)")
            .wait()
        XCTAssertEqual(response.status, .ok)

        XCTAssertNoThrow(
            try TemporaryFileHelpers.withTemporaryUnixDomainSocketPathName { httpSocketPath in
                XCTAssertNoThrow(
                    try TemporaryFileHelpers.withTemporaryUnixDomainSocketPathName { httpsSocketPath in
                        let socketHTTPBin = HTTPBin(bindTarget: .unixDomainSocket(httpSocketPath))
                        let socketHTTPSBin = HTTPBin(
                            .http1_1(ssl: true),
                            bindTarget: .unixDomainSocket(httpsSocketPath)
                        )
                        defer {
                            XCTAssertNoThrow(try socketHTTPBin.shutdown())
                            XCTAssertNoThrow(try socketHTTPSBin.shutdown())
                        }

                        // From HTTP or HTTPS to HTTP+UNIX should fail to redirect
                        var targetURL =
                            "http+unix://\(httpSocketPath.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed)!)/ok"
                        var request = try Request(
                            url: self.defaultHTTPBinURLPrefix + "redirect/target",
                            method: .GET,
                            headers: ["X-Target-Redirect-URL": targetURL],
                            body: nil
                        )

                        var response = try localClient.execute(request: request).wait()
                        XCTAssertEqual(response.status, .found)
                        XCTAssertEqual(response.headers.first(name: "Location"), targetURL)
                        XCTAssertEqual(response.url, request.url)
                        XCTAssertEqual(response.history.map(\.request.url), [request.url])

                        request = try Request(
                            url: "https://localhost:\(httpsBin.port)/redirect/target",
                            method: .GET,
                            headers: ["X-Target-Redirect-URL": targetURL],
                            body: nil
                        )

                        response = try localClient.execute(request: request).wait()
                        XCTAssertEqual(response.status, .found)
                        XCTAssertEqual(response.headers.first(name: "Location"), targetURL)
                        XCTAssertEqual(response.url, request.url)
                        XCTAssertEqual(response.history.map(\.request.url), [request.url])

                        // From HTTP or HTTPS to HTTPS+UNIX should also fail to redirect
                        targetURL =
                            "https+unix://\(httpsSocketPath.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed)!)/ok"
                        request = try Request(
                            url: self.defaultHTTPBinURLPrefix + "redirect/target",
                            method: .GET,
                            headers: ["X-Target-Redirect-URL": targetURL],
                            body: nil
                        )

                        response = try localClient.execute(request: request).wait()
                        XCTAssertEqual(response.status, .found)
                        XCTAssertEqual(response.headers.first(name: "Location"), targetURL)
                        XCTAssertEqual(response.url, request.url)
                        XCTAssertEqual(response.history.map(\.request.url), [request.url])

                        request = try Request(
                            url: "https://localhost:\(httpsBin.port)/redirect/target",
                            method: .GET,
                            headers: ["X-Target-Redirect-URL": targetURL],
                            body: nil
                        )

                        response = try localClient.execute(request: request).wait()
                        XCTAssertEqual(response.status, .found)
                        XCTAssertEqual(response.headers.first(name: "Location"), targetURL)
                        XCTAssertEqual(response.url, request.url)
                        XCTAssertEqual(response.history.map(\.request.url), [request.url])

                        // ... while HTTP+UNIX to HTTP, HTTPS, or HTTP(S)+UNIX should succeed
                        targetURL = self.defaultHTTPBinURLPrefix + "ok"
                        request = try Request(
                            url:
                                "http+unix://\(httpSocketPath.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed)!)/redirect/target",
                            method: .GET,
                            headers: ["X-Target-Redirect-URL": targetURL],
                            body: nil
                        )

                        response = try localClient.execute(request: request).wait()
                        XCTAssertEqual(response.status, .ok)
                        XCTAssertEqual(response.url?.absoluteString, targetURL)
                        XCTAssertEqual(
                            response.history.map(\.request.url.absoluteString),
                            [request.url.absoluteString, targetURL]
                        )

                        targetURL = "https://localhost:\(httpsBin.port)/ok"
                        request = try Request(
                            url:
                                "http+unix://\(httpSocketPath.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed)!)/redirect/target",
                            method: .GET,
                            headers: ["X-Target-Redirect-URL": targetURL],
                            body: nil
                        )

                        response = try localClient.execute(request: request).wait()
                        XCTAssertEqual(response.status, .ok)
                        XCTAssertEqual(response.url?.absoluteString, targetURL)
                        XCTAssertEqual(
                            response.history.map(\.request.url.absoluteString),
                            [request.url.absoluteString, targetURL]
                        )

                        targetURL =
                            "http+unix://\(httpSocketPath.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed)!)/ok"
                        request = try Request(
                            url:
                                "http+unix://\(httpSocketPath.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed)!)/redirect/target",
                            method: .GET,
                            headers: ["X-Target-Redirect-URL": targetURL],
                            body: nil
                        )

                        response = try localClient.execute(request: request).wait()
                        XCTAssertEqual(response.status, .ok)
                        XCTAssertEqual(response.url?.absoluteString, targetURL)
                        XCTAssertEqual(
                            response.history.map(\.request.url.absoluteString),
                            [request.url.absoluteString, targetURL]
                        )

                        targetURL =
                            "https+unix://\(httpsSocketPath.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed)!)/ok"
                        request = try Request(
                            url:
                                "http+unix://\(httpSocketPath.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed)!)/redirect/target",
                            method: .GET,
                            headers: ["X-Target-Redirect-URL": targetURL],
                            body: nil
                        )

                        response = try localClient.execute(request: request).wait()
                        XCTAssertEqual(response.status, .ok)
                        XCTAssertEqual(response.url?.absoluteString, targetURL)
                        XCTAssertEqual(
                            response.history.map(\.request.url.absoluteString),
                            [request.url.absoluteString, targetURL]
                        )

                        // ... and HTTPS+UNIX to HTTP, HTTPS, or HTTP(S)+UNIX should succeed
                        targetURL = self.defaultHTTPBinURLPrefix + "ok"
                        request = try Request(
                            url:
                                "https+unix://\(httpsSocketPath.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed)!)/redirect/target",
                            method: .GET,
                            headers: ["X-Target-Redirect-URL": targetURL],
                            body: nil
                        )

                        response = try localClient.execute(request: request).wait()
                        XCTAssertEqual(response.status, .ok)
                        XCTAssertEqual(response.url?.absoluteString, targetURL)
                        XCTAssertEqual(
                            response.history.map(\.request.url.absoluteString),
                            [request.url.absoluteString, targetURL]
                        )

                        targetURL = "https://localhost:\(httpsBin.port)/ok"
                        request = try Request(
                            url:
                                "https+unix://\(httpsSocketPath.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed)!)/redirect/target",
                            method: .GET,
                            headers: ["X-Target-Redirect-URL": targetURL],
                            body: nil
                        )

                        response = try localClient.execute(request: request).wait()
                        XCTAssertEqual(response.status, .ok)
                        XCTAssertEqual(response.url?.absoluteString, targetURL)
                        XCTAssertEqual(
                            response.history.map(\.request.url.absoluteString),
                            [request.url.absoluteString, targetURL]
                        )

                        targetURL =
                            "http+unix://\(httpSocketPath.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed)!)/ok"
                        request = try Request(
                            url:
                                "https+unix://\(httpsSocketPath.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed)!)/redirect/target",
                            method: .GET,
                            headers: ["X-Target-Redirect-URL": targetURL],
                            body: nil
                        )

                        response = try localClient.execute(request: request).wait()
                        XCTAssertEqual(response.status, .ok)
                        XCTAssertEqual(response.url?.absoluteString, targetURL)
                        XCTAssertEqual(
                            response.history.map(\.request.url.absoluteString),
                            [request.url.absoluteString, targetURL]
                        )

                        targetURL =
                            "https+unix://\(httpsSocketPath.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed)!)/ok"
                        request = try Request(
                            url:
                                "https+unix://\(httpsSocketPath.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed)!)/redirect/target",
                            method: .GET,
                            headers: ["X-Target-Redirect-URL": targetURL],
                            body: nil
                        )

                        response = try localClient.execute(request: request).wait()
                        XCTAssertEqual(response.status, .ok)
                        XCTAssertEqual(response.url?.absoluteString, targetURL)
                        XCTAssertEqual(
                            response.history.map(\.request.url.absoluteString),
                            [request.url.absoluteString, targetURL]
                        )
                    }
                )
            }
        )
    }

    func testHttpHostRedirect() {
        let localClient = HTTPClient(
            eventLoopGroupProvider: .shared(self.clientGroup),
            configuration: HTTPClient.Configuration(
                certificateVerification: .none,
                redirectConfiguration: .follow(max: 10, allowCycles: true)
            )
        )

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
        XCTAssertEqual("127.0.0.1:\(self.defaultHTTPBin.port)", hostName)
    }

    func testPercentEncoded() throws {
        let response = try self.defaultClient.get(url: self.defaultHTTPBinURLPrefix + "percent%20encoded").wait()
        XCTAssertEqual(.ok, response.status)
    }

    func testPercentEncodedBackslash() throws {
        let response = try self.defaultClient.get(url: self.defaultHTTPBinURLPrefix + "percent%2Fencoded/hello").wait()
        XCTAssertEqual(.ok, response.status)
    }

    func testLeadingSlashRelativeURL() throws {
        let noLeadingSlashURL = URL(
            string: "percent%2Fencoded/hello",
            relativeTo: URL(string: self.defaultHTTPBinURLPrefix)!
        )!
        let withLeadingSlashURL = URL(
            string: "/percent%2Fencoded/hello",
            relativeTo: URL(string: self.defaultHTTPBinURLPrefix)!
        )!

        let noLeadingSlashURLRequest = try HTTPClient.Request(url: noLeadingSlashURL, method: .GET)
        let withLeadingSlashURLRequest = try HTTPClient.Request(url: withLeadingSlashURL, method: .GET)

        let noLeadingSlashURLResponse = try self.defaultClient.execute(request: noLeadingSlashURLRequest).wait()
        let withLeadingSlashURLResponse = try self.defaultClient.execute(request: withLeadingSlashURLRequest).wait()

        XCTAssertEqual(noLeadingSlashURLResponse.status, .ok)
        XCTAssertEqual(withLeadingSlashURLResponse.status, .ok)
    }

    func testMultipleContentLengthHeaders() throws {
        let body = ByteBuffer(string: "hello world!")

        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: "12")
        let request = try Request(
            url: self.defaultHTTPBinURLPrefix + "post",
            method: .POST,
            headers: headers,
            body: .byteBuffer(body)
        )
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

    func testFileDownload() throws {
        var request = try Request(url: self.defaultHTTPBinURLPrefix + "events/10/content-length")
        request.headers.add(name: "Accept", value: "text/event-stream")

        let response =
            try TemporaryFileHelpers.withTemporaryFilePath { path -> FileDownloadDelegate.Response in
                let delegate = try FileDownloadDelegate(path: path)

                let response = try self.defaultClient.execute(
                    request: request,
                    delegate: delegate
                )
                .wait()

                try XCTAssertEqual(50, TemporaryFileHelpers.fileSize(path: path))

                return response
            }

        XCTAssertEqual(.ok, response.head.status)
        XCTAssertEqual("50", response.head.headers.first(name: "content-length"))

        XCTAssertEqual(50, response.totalBytes)
        XCTAssertEqual(50, response.receivedBytes)
    }

    func testFileDownloadError() throws {
        var request = try Request(url: self.defaultHTTPBinURLPrefix + "not-found")
        request.headers.add(name: "Accept", value: "text/event-stream")

        let response =
            try TemporaryFileHelpers.withTemporaryFilePath { path -> FileDownloadDelegate.Response in
                let delegate = try FileDownloadDelegate(
                    path: path,
                    reportHead: {
                        XCTAssertEqual($0.status, .notFound)
                    }
                )

                let response = try self.defaultClient.execute(
                    request: request,
                    delegate: delegate
                )
                .wait()

                XCTAssertFalse(TemporaryFileHelpers.fileExists(path: path))

                return response
            }

        XCTAssertEqual(.notFound, response.head.status)
        XCTAssertFalse(response.head.headers.contains(name: "content-length"))

        XCTAssertEqual(nil, response.totalBytes)
        XCTAssertEqual(0, response.receivedBytes)
    }

    func testFileDownloadCustomError() throws {
        let request = try Request(url: self.defaultHTTPBinURLPrefix + "get")
        struct CustomError: Equatable, Error {}

        try TemporaryFileHelpers.withTemporaryFilePath { path in
            let delegate = try FileDownloadDelegate(
                path: path,
                reportHead: { task, head in
                    XCTAssertEqual(head.status, .ok)
                    task.fail(reason: CustomError())
                },
                reportProgress: { _, _ in
                    XCTFail("should never be called")
                }
            )
            XCTAssertThrowsError(
                try self.defaultClient.execute(
                    request: request,
                    delegate: delegate
                )
                .wait()
            ) { error in
                XCTAssertEqualTypeAndValue(error, CustomError())
            }

            XCTAssertFalse(TemporaryFileHelpers.fileExists(path: path))
        }
    }

    func testRemoteClose() {
        XCTAssertThrowsError(try self.defaultClient.get(url: self.defaultHTTPBinURLPrefix + "close").wait()) {
            XCTAssertEqual($0 as? HTTPClientError, .remoteConnectionClosed)
        }
    }

    func testReadTimeout() {
        let localClient = HTTPClient(
            eventLoopGroupProvider: .shared(self.clientGroup),
            configuration: HTTPClient.Configuration(timeout: HTTPClient.Configuration.Timeout(read: .milliseconds(150)))
        )

        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
        }

        XCTAssertThrowsError(try localClient.get(url: self.defaultHTTPBinURLPrefix + "wait").wait()) {
            XCTAssertEqual($0 as? HTTPClientError, .readTimeout)
        }
    }

    func testWriteTimeout() throws {
        let localClient = HTTPClient(
            eventLoopGroupProvider: .shared(self.clientGroup),
            configuration: HTTPClient.Configuration(timeout: HTTPClient.Configuration.Timeout(write: .nanoseconds(10)))
        )

        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
        }

        // Create a request that writes a chunk, then waits longer than the configured write timeout,
        // and then writes again. This should trigger a write timeout error.
        let request = try HTTPClient.Request(
            url: self.defaultHTTPBinURLPrefix + "post",
            method: .POST,
            headers: ["transfer-encoding": "chunked"],
            body: .stream { streamWriter in
                _ = streamWriter.write(.byteBuffer(.init()))

                let promise = localClient.eventLoopGroup.next().makePromise(of: Void.self)
                localClient.eventLoopGroup.next().scheduleTask(in: .milliseconds(3)) {
                    streamWriter.write(.byteBuffer(.init())).cascade(to: promise)
                }

                return promise.futureResult
            }
        )

        XCTAssertThrowsError(try localClient.execute(request: request).wait()) {
            XCTAssertEqual($0 as? HTTPClientError, .writeTimeout)
        }
    }

    func testConnectTimeout() throws {
        #if os(Linux)
        // 198.51.100.254 is reserved for documentation only and therefore should not accept any TCP connection
        let url = "http://198.51.100.254/get"
        #else
        // on macOS we can use the TCP backlog behaviour when the queue is full to simulate a non reachable server.
        // this makes this test a bit more stable if `198.51.100.254` actually responds to connection attempt.
        // The backlog behaviour on Linux can not be used to simulate a non-reachable server.
        // Linux sends a `SYN/ACK` back even if the `backlog` queue is full as it has two queues.
        // The second queue is not limit by `ChannelOptions.backlog` but by `/proc/sys/net/ipv4/tcp_max_syn_backlog`.

        let serverChannel = try ServerBootstrap(group: self.serverGroup)
            .serverChannelOption(ChannelOptions.backlog, value: 1)
            .serverChannelOption(ChannelOptions.autoRead, value: false)
            .bind(host: "127.0.0.1", port: 0)
            .wait()
        defer {
            XCTAssertNoThrow(try serverChannel.close().wait())
        }
        let port = serverChannel.localAddress!.port!
        let firstClientChannel = try ClientBootstrap(group: self.serverGroup)
            .connect(host: "127.0.0.1", port: port)
            .wait()
        defer {
            XCTAssertNoThrow(try firstClientChannel.close().wait())
        }
        let url = "http://localhost:\(port)/get"
        #endif

        let httpClient = HTTPClient(
            eventLoopGroupProvider: .shared(self.clientGroup),
            configuration: .init(timeout: .init(connect: .milliseconds(100), read: .milliseconds(150)))
        )

        defer {
            XCTAssertNoThrow(try httpClient.syncShutdown())
        }

        XCTAssertThrowsError(try httpClient.get(url: url).wait()) {
            XCTAssertEqualTypeAndValue($0, HTTPClientError.connectTimeout)
        }
    }

    func testDeadline() {
        XCTAssertThrowsError(
            try self.defaultClient.get(
                url: self.defaultHTTPBinURLPrefix + "wait",
                deadline: .now() + .milliseconds(150)
            ).wait()
        ) {
            XCTAssertEqual($0 as? HTTPClientError, .deadlineExceeded)
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
        let localHTTPBin = HTTPBin(proxy: .simulate(authorization: nil))
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
        let localHTTPBin = HTTPBin(.http1_1(ssl: true), proxy: .simulate(authorization: nil))
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
        let localHTTPBin = HTTPBin(proxy: .simulate(authorization: "Basic YWxhZGRpbjpvcGVuc2VzYW1l"))
        let localClient = HTTPClient(
            eventLoopGroupProvider: .shared(self.clientGroup),
            configuration: .init(
                proxy: .server(
                    host: "localhost",
                    port: localHTTPBin.port,
                    authorization: .basic(username: "aladdin", password: "opensesame")
                )
            )
        )
        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            XCTAssertNoThrow(try localHTTPBin.shutdown())
        }
        let res = try localClient.get(url: "http://test/ok").wait()
        XCTAssertEqual(res.status, .ok)
    }

    func testProxyPlaintextWithIncorrectlyAuthorization() throws {
        let localHTTPBin = HTTPBin(proxy: .simulate(authorization: "Basic YWxhZGRpbjpvcGVuc2VzYW1l"))
        let localClient = HTTPClient(
            eventLoopGroupProvider: .shared(self.clientGroup),
            configuration: .init(
                proxy: .server(
                    host: "localhost",
                    port: localHTTPBin.port,
                    authorization: .basic(
                        username: "aladdin",
                        password: "opensesamefoo"
                    )
                )
            ).enableFastFailureModeForTesting()
        )
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
        let body: HTTPClient.Body = .stream(contentLength: 8) { writer in
            let buffer = ByteBuffer(string: "1234")
            return writer.write(.byteBuffer(buffer)).flatMap {
                let buffer = ByteBuffer(string: "4321")
                return writer.write(.byteBuffer(buffer))
            }
        }

        let response = try self.defaultClient.post(url: self.defaultHTTPBinURLPrefix + "post", body: body).wait()
        let bytes = response.body.flatMap { $0.getData(at: 0, length: $0.readableBytes) }
        let data = try JSONDecoder().decode(RequestInfo.self, from: bytes!)

        XCTAssertEqual(.ok, response.status)
        XCTAssertEqual("12344321", data.data)
    }

    func testEventLoopArgument() throws {
        let localClient = HTTPClient(
            eventLoopGroupProvider: .shared(self.clientGroup),
            configuration: HTTPClient.Configuration(redirectConfiguration: .follow(max: 10, allowCycles: true))
        )
        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
        }

        final class EventLoopValidatingDelegate: HTTPClientResponseDelegate {
            typealias Response = Bool

            let eventLoop: EventLoop
            let result = NIOLockedValueBox(false)

            init(eventLoop: EventLoop) {
                self.eventLoop = eventLoop
            }

            func didReceiveHead(task: HTTPClient.Task<Bool>, _ head: HTTPResponseHead) -> EventLoopFuture<Void> {
                self.result.withLockedValue { $0 = task.eventLoop === self.eventLoop }
                return task.eventLoop.makeSucceededFuture(())
            }

            func didFinishRequest(task: HTTPClient.Task<Bool>) throws -> Bool {
                self.result.withLockedValue { $0 }
            }
        }

        let eventLoop = self.clientGroup.next()
        let delegate = EventLoopValidatingDelegate(eventLoop: eventLoop)
        var request = try HTTPClient.Request(url: self.defaultHTTPBinURLPrefix + "get")
        var response = try localClient.execute(
            request: request,
            delegate: delegate,
            eventLoop: .delegate(on: eventLoop)
        ).wait()
        XCTAssertEqual(true, response)

        // redirect
        request = try HTTPClient.Request(url: self.defaultHTTPBinURLPrefix + "redirect/302")
        response = try localClient.execute(request: request, delegate: delegate, eventLoop: .delegate(on: eventLoop))
            .wait()
        XCTAssertEqual(true, response)
    }

    func testDecompression() throws {
        let localHTTPBin = HTTPBin(.http1_1(compress: true))
        let localClient = HTTPClient(
            eventLoopGroupProvider: .shared(self.clientGroup),
            configuration: .init(decompression: .enabled(limit: .none))
        )

        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            XCTAssertNoThrow(try localHTTPBin.shutdown())
        }

        var body = ""
        for _ in 1...1000 {
            body +=
                "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua."
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

    func testDecompressionHTTP2() throws {
        let localHTTPBin = HTTPBin(.http2(compress: true))
        let localClient = HTTPClient(
            eventLoopGroupProvider: .shared(self.clientGroup),
            configuration: .init(
                certificateVerification: .none,
                decompression: .enabled(limit: .none)
            )
        )

        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            XCTAssertNoThrow(try localHTTPBin.shutdown())
        }

        var body = ""
        for _ in 1...1000 {
            body +=
                "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua."
        }

        for algorithm: String? in [nil] {
            var request = try HTTPClient.Request(url: "https://localhost:\(localHTTPBin.port)/post", method: .POST)
            request.body = .string(body)
            if let algorithm = algorithm {
                request.headers.add(name: "Accept-Encoding", value: algorithm)
            }

            let response = try localClient.execute(request: request).wait()
            var responseBody = try XCTUnwrap(response.body)
            let data = try responseBody.readJSONDecodable(RequestInfo.self, length: responseBody.readableBytes)

            XCTAssertEqual(.ok, response.status)
            let contentLength = try XCTUnwrap(response.headers["Content-Length"].first.flatMap { Int($0) })
            XCTAssertGreaterThan(body.count, contentLength)
            if let algorithm = algorithm {
                XCTAssertEqual(algorithm, response.headers["Content-Encoding"].first)
            } else {
                XCTAssertEqual("deflate", response.headers["Content-Encoding"].first)
            }
            XCTAssertEqual(body, data?.data)
        }
    }

    func testDecompressionLimit() throws {
        let localHTTPBin = HTTPBin(.http1_1(compress: true))
        let localClient = HTTPClient(
            eventLoopGroupProvider: .shared(self.clientGroup),
            configuration: .init(decompression: .enabled(limit: .ratio(1)))
        )

        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            XCTAssertNoThrow(try localHTTPBin.shutdown())
        }

        var request = try HTTPClient.Request(url: "http://localhost:\(localHTTPBin.port)/post", method: .POST)
        request.body = .byteBuffer(ByteBuffer(bytes: [120, 156, 75, 76, 28, 5, 200, 0, 0, 248, 66, 103, 17]))
        request.headers.add(name: "Accept-Encoding", value: "deflate")

        XCTAssertThrowsError(try localClient.execute(request: request).wait()) {
            XCTAssertEqual($0 as? NIOHTTPDecompression.DecompressionError, .limit)
        }
    }

    func testLoopDetectionRedirectLimit() throws {
        let localHTTPBin = HTTPBin(.http1_1(ssl: true))
        let localClient = HTTPClient(
            eventLoopGroupProvider: .shared(self.clientGroup),
            configuration: HTTPClient.Configuration(
                certificateVerification: .none,
                redirectConfiguration: .follow(max: 5, allowCycles: false)
            )
        )

        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            XCTAssertNoThrow(try localHTTPBin.shutdown())
        }

        XCTAssertThrowsError(
            try localClient.get(url: "https://localhost:\(localHTTPBin.port)/redirect/infinite1").wait(),
            "Should fail with redirect limit"
        ) { error in
            XCTAssertEqual(error as? HTTPClientError, HTTPClientError.redirectCycleDetected)
        }
    }

    func testCountRedirectLimit() throws {
        let localHTTPBin = HTTPBin(.http1_1(ssl: true))
        let localClient = HTTPClient(
            eventLoopGroupProvider: .shared(self.clientGroup),
            configuration: HTTPClient.Configuration(
                certificateVerification: .none,
                redirectConfiguration: .follow(max: 10, allowCycles: true)
            )
        )

        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            XCTAssertNoThrow(try localHTTPBin.shutdown())
        }

        XCTAssertThrowsError(
            try localClient.get(url: "https://localhost:\(localHTTPBin.port)/redirect/infinite1").timeout(
                after: .seconds(10)
            ).wait()
        ) { error in
            XCTAssertEqual(error as? HTTPClientError, HTTPClientError.redirectLimitReached)
        }
    }

    func testRedirectToTheInitialURLDoesThrowOnFirstRedirect() throws {
        let localHTTPBin = HTTPBin(.http1_1(ssl: true))
        defer { XCTAssertNoThrow(try localHTTPBin.shutdown()) }
        let localClient = HTTPClient(
            eventLoopGroupProvider: .shared(self.clientGroup),
            configuration: .init(
                certificateVerification: .none,
                redirectConfiguration: .follow(max: 1, allowCycles: false)
            )
        )
        defer { XCTAssertNoThrow(try localClient.syncShutdown()) }

        var maybeRequest: HTTPClient.Request?
        XCTAssertNoThrow(
            maybeRequest = try HTTPClient.Request(
                url: "https://localhost:\(localHTTPBin.port)/redirect/target",
                method: .GET,
                headers: [
                    "X-Target-Redirect-URL": "/redirect/target"
                ]
            )
        )
        guard let request = maybeRequest else { return }

        XCTAssertThrowsError(
            try localClient.execute(request: request).timeout(after: .seconds(10)).wait()
        ) { error in
            XCTAssertEqual(error as? HTTPClientError, HTTPClientError.redirectCycleDetected)
        }
    }

    func testMultipleConcurrentRequests() throws {
        let numberOfRequestsPerThread = 1000
        let numberOfParallelWorkers = 5

        final class HTTPServer: ChannelInboundHandler, Sendable {
            typealias InboundIn = HTTPServerRequestPart
            typealias OutboundOut = HTTPServerResponsePart

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                if case .end = self.unwrapInboundIn(data) {
                    let responseHead = HTTPServerResponsePart.head(
                        .init(
                            version: .init(major: 1, minor: 1),
                            status: .ok
                        )
                    )
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
        XCTAssertNoThrow(
            server = try ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.socket(.init(SOL_SOCKET), .init(SO_REUSEADDR)), value: 1)
                .serverChannelOption(ChannelOptions.backlog, value: .init(numberOfParallelWorkers))
                .childChannelInitializer { channel in
                    channel.pipeline.configureHTTPServerPipeline(
                        withPipeliningAssistance: false,
                        withServerUpgrade: nil,
                        withErrorHandling: false
                    ).flatMap {
                        channel.pipeline.addHandler(HTTPServer())
                    }
                }
                .bind(to: .init(ipAddress: "127.0.0.1", port: 0))
                .wait()
        )
        defer {
            XCTAssertNoThrow(try server?.close().wait())
        }

        let url = "http://127.0.0.1:\(server?.localAddress?.port ?? -1)/hello"
        let g = DispatchGroup()
        let defaultClient = self.defaultClient!
        for workerID in 0..<numberOfParallelWorkers {
            DispatchQueue(label: "\(#fileID):\(#line):worker-\(workerID)").async(group: g) {
                func makeRequest() {
                    XCTAssertNoThrow(try defaultClient.get(url: url).wait())
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

        XCTAssertNoThrow(
            try web.receiveHeadAndVerify { received in
                let expected = HTTPRequestHead(
                    version: .http1_1,
                    method: .GET,
                    uri: "/foo",
                    headers: ["Host": "localhost:\(web.serverPort)"]
                )
                XCTAssertEqual(expected, received)
            }
        )
        XCTAssertNoThrow(try web.receiveEnd())
        XCTAssertNoThrow(
            try web.writeOutbound(
                .head(
                    .init(
                        version: .init(major: 1, minor: 1),
                        status: .internalServerError
                    )
                )
            )
        )
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
        XCTAssertNoThrow(
            try web.receiveHeadAndVerify {
                XCTAssertEqual(
                    $0,
                    HTTPRequestHead(
                        version: .init(major: 1, minor: 1),
                        method: .GET,
                        uri: "/foo",
                        headers: HTTPHeaders([("Host", "localhost:\(web.serverPort)")])
                    )
                )
            }
        )
        XCTAssertNoThrow(try web.receiveEnd())

        XCTAssertNoThrow(
            try web.writeOutbound(
                .head(
                    .init(
                        version: .init(major: 1, minor: 0),
                        status: .internalServerError
                    )
                )
            )
        )
        XCTAssertNoThrow(try web.writeOutbound(.end(nil)))

        var response: HTTPClient.Response?
        XCTAssertNoThrow(response = try result.wait())
        XCTAssertEqual(.internalServerError, response?.status)
        XCTAssertNil(response?.body)
    }

    func testWorksWhenServerClosesConnectionAfterReceivingRequest() {
        let web = NIOHTTP1TestServer(group: self.serverGroup)
        let result = self.defaultClient.get(url: "http://localhost:\(web.serverPort)/foo")

        XCTAssertNoThrow(
            try web.receiveHeadAndVerify { received in
                let expected = HTTPRequestHead(
                    version: .http1_1,
                    method: .GET,
                    uri: "/foo",
                    headers: ["Host": "localhost:\(web.serverPort)"]
                )
                XCTAssertEqual(expected, received)
            }
        )
        XCTAssertNoThrow(try web.receiveEnd())
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

            XCTAssertNoThrow(
                try web.receiveHeadAndVerify { received in
                    let expected = HTTPRequestHead(
                        version: .http1_1,
                        method: .GET,
                        uri: "/foo",
                        headers: ["Host": "localhost:\(web.serverPort)"]
                    )
                    XCTAssertEqual(expected, received)
                }
            )
            XCTAssertNoThrow(try web.receiveEnd())
            XCTAssertNoThrow(
                try web.writeOutbound(
                    .head(
                        .init(
                            version: .init(major: 1, minor: 0),
                            status: .ok,
                            headers: HTTPHeaders([("connection", "close")])
                        )
                    )
                )
            )
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

            XCTAssertNoThrow(
                try web.receiveHeadAndVerify { received in
                    let expected = HTTPRequestHead(
                        version: .http1_1,
                        method: .GET,
                        uri: "/foo",
                        headers: ["Host": "localhost:\(web.serverPort)"]
                    )
                    XCTAssertEqual(expected, received)
                }
            )
            XCTAssertNoThrow(try web.receiveEnd())
            XCTAssertNoThrow(
                try web.writeOutbound(
                    .head(
                        .init(
                            version: .init(major: 1, minor: 0),
                            status: .ok,
                            headers: HTTPHeaders([
                                (
                                    "connection",
                                    i % 2 == 0 ? "close" : "keep-alive"
                                )
                            ])
                        )
                    )
                )
            )
            XCTAssertNoThrow(try web.writeOutbound(.end(nil)))

            var response: HTTPClient.Response?
            XCTAssertNoThrow(response = try result.wait())
            XCTAssertEqual(.ok, response?.status)
            XCTAssertNil(response?.body)
        }
    }

    func testStressGetHttpsSSLError() throws {
        let localClient = HTTPClient(
            eventLoopGroupProvider: .shared(self.clientGroup),
            configuration: HTTPClient.Configuration().enableFastFailureModeForTesting()
        )
        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
        }

        let request = try Request(url: "https://localhost:\(self.defaultHTTPBin.port)/wait", method: .GET)
        let tasks = (1...100).map { _ -> HTTPClient.Task<TestHTTPDelegate.Response> in
            localClient.execute(request: request, delegate: TestHTTPDelegate())
        }

        let results = try EventLoopFuture<TestHTTPDelegate.Response>.whenAllComplete(
            tasks.map { $0.futureResult },
            on: localClient.eventLoopGroup.next()
        ).wait()

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
                    XCTAssert(
                        clientError.status == errSSLHandshakeFail || clientError.status == errSSLPeerProtocolVersion,
                        "unexpected NWTLSError with status \(clientError.status)"
                    )
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

    func testSelfSignedCertificateIsRejectedWithCorrectError() throws {
        /// key + cert was created with the follwing command:
        /// openssl req -x509 -newkey rsa:4096 -keyout self_signed_key.pem -out self_signed_cert.pem -sha256 -days 99999 -nodes -subj '/CN=localhost'
        let certPath = Bundle.module.path(forResource: "self_signed_cert", ofType: "pem")!
        let keyPath = Bundle.module.path(forResource: "self_signed_key", ofType: "pem")!
        let key = try NIOSSLPrivateKey(file: keyPath, format: .pem)
        let configuration = try TLSConfiguration.makeServerConfiguration(
            certificateChain: NIOSSLCertificate.fromPEMFile(certPath).map { .certificate($0) },
            privateKey: .privateKey(key)
        )
        let sslContext = try NIOSSLContext(configuration: configuration)

        let server = ServerBootstrap(group: serverGroup)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: sslContext))
                }
            }
        let serverChannel = try server.bind(host: "localhost", port: 0).wait()
        defer { XCTAssertNoThrow(try serverChannel.close().wait()) }
        let port = serverChannel.localAddress!.port!

        let config = HTTPClient.Configuration().enableFastFailureModeForTesting()

        let localClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup), configuration: config)
        defer { XCTAssertNoThrow(try localClient.syncShutdown()) }
        XCTAssertThrowsError(try localClient.get(url: "https://localhost:\(port)").wait()) { error in
            #if canImport(Network)
            guard let nwTLSError = error as? HTTPClient.NWTLSError else {
                XCTFail("could not cast \(error) of type \(type(of: error)) to \(HTTPClient.NWTLSError.self)")
                return
            }
            XCTAssertEqual(nwTLSError.status, errSSLBadCert, "unexpected tls error: \(nwTLSError)")
            #else
            guard let sslError = error as? NIOSSLError,
                case .handshakeFailed(.sslError) = sslError
            else {
                XCTFail("unexpected error \(error)")
                return
            }
            #endif
        }
    }

    func testSelfSignedCertificateIsRejectedWithCorrectErrorIfRequestDeadlineIsExceeded() throws {
        /// key + cert was created with the follwing command:
        /// openssl req -x509 -newkey rsa:4096 -keyout self_signed_key.pem -out self_signed_cert.pem -sha256 -days 99999 -nodes -subj '/CN=localhost'
        let certPath = Bundle.module.path(forResource: "self_signed_cert", ofType: "pem")!
        let keyPath = Bundle.module.path(forResource: "self_signed_key", ofType: "pem")!
        let key = try NIOSSLPrivateKey(file: keyPath, format: .pem)
        let configuration = try TLSConfiguration.makeServerConfiguration(
            certificateChain: NIOSSLCertificate.fromPEMFile(certPath).map { .certificate($0) },
            privateKey: .privateKey(key)
        )
        let sslContext = try NIOSSLContext(configuration: configuration)

        let server = ServerBootstrap(group: serverGroup)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: sslContext))
                }
            }
        let serverChannel = try server.bind(host: "localhost", port: 0).wait()
        defer { XCTAssertNoThrow(try serverChannel.close().wait()) }
        let port = serverChannel.localAddress!.port!

        let config = HTTPClient.Configuration().enableFastFailureModeForTesting()

        let localClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup), configuration: config)
        defer { XCTAssertNoThrow(try localClient.syncShutdown()) }

        XCTAssertThrowsError(
            try localClient.get(url: "https://localhost:\(port)", deadline: .now() + .seconds(2)).wait()
        ) { error in
            #if canImport(Network)
            guard let nwTLSError = error as? HTTPClient.NWTLSError else {
                XCTFail("could not cast \(error) of type \(type(of: error)) to \(HTTPClient.NWTLSError.self)")
                return
            }
            XCTAssertEqual(nwTLSError.status, errSSLBadCert, "unexpected tls error: \(nwTLSError)")
            #else
            guard let sslError = error as? NIOSSLError,
                case .handshakeFailed(.sslError) = sslError
            else {
                XCTFail("unexpected error \(error)")
                return
            }
            #endif
        }
    }

    func testFailingConnectionIsReleased() {
        let localHTTPBin = HTTPBin(.refuse)
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

    func testStressGetClose() throws {
        let eventLoop = self.defaultClient.eventLoopGroup.next()
        let requestCount = 200
        var futureResults = [EventLoopFuture<HTTPClient.Response>]()
        for _ in 1...requestCount {
            let req = try HTTPClient.Request(
                url: self.defaultHTTPBinURLPrefix + "get",
                method: .GET,
                headers: ["X-internal-delay": "5", "Connection": "close"]
            )
            futureResults.append(self.defaultClient.execute(request: req))
        }
        XCTAssertNoThrow(
            try EventLoopFuture<HTTPClient.Response>.andAllComplete(futureResults, on: eventLoop)
                .timeout(after: .seconds(10)).wait()
        )
    }

    func testManyConcurrentRequestsWork() {
        let numberOfWorkers = 20
        let numberOfRequestsPerWorkers = 20
        let allWorkersReady = DispatchSemaphore(value: 0)
        let allWorkersGo = DispatchSemaphore(value: 0)
        let allDone = DispatchGroup()

        let url = self.defaultHTTPBinURLPrefix + "get"
        XCTAssertEqual(.ok, try self.defaultClient.get(url: url).wait().status)

        for w in 0..<numberOfWorkers {
            let q = DispatchQueue(label: "worker \(w)")
            let defaultClient = self.defaultClient!
            q.async(group: allDone) {
                func go() {
                    allWorkersReady.signal()  // tell the driver we're ready
                    allWorkersGo.wait()  // wait for the driver to let us go

                    for _ in 0..<numberOfRequestsPerWorkers {
                        XCTAssertEqual(.ok, try defaultClient.get(url: url).wait().status)
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
            XCTAssertNoThrow(
                try web.receiveHeadAndVerify { received in
                    let expected = HTTPRequestHead(
                        version: .http1_1,
                        method: .GET,
                        uri: "/foo",
                        headers: ["Host": "localhost:\(web.serverPort)"]
                    )
                    XCTAssertEqual(expected, received)
                }
            )
            XCTAssertNoThrow(try web.receiveEnd())
            XCTAssertNoThrow(
                try web.writeOutbound(
                    .head(
                        .init(
                            version: .init(major: 1, minor: 1),
                            status: .ok,
                            headers: HTTPHeaders([("CoNnEcTiOn", "cLoSe")])
                        )
                    )
                )
            )
            XCTAssertNoThrow(try web.writeOutbound(.end(nil)))

            var response: HTTPClient.Response?
            XCTAssertNoThrow(response = try result.wait())
            XCTAssertEqual(.ok, response?.status)
            XCTAssertNil(response?.body)
        }
    }

    func testShutdownBeforeTasksCompletion() throws {
        let client = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup))
        let req = try HTTPClient.Request(
            url: self.defaultHTTPBinURLPrefix + "get",
            method: .GET,
            headers: ["X-internal-delay": "500"]
        )
        let res = client.execute(request: req)
        XCTAssertNoThrow(try client.syncShutdown())
        _ = try? res.timeout(after: .seconds(2)).wait()
    }

    /// This test would cause an assertion failure on `HTTPClient` deinit if client doesn't actually shutdown
    func testUncleanShutdownActuallyShutsDown() throws {
        let client = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup))
        let req = try HTTPClient.Request(
            url: self.defaultHTTPBinURLPrefix + "get",
            method: .GET,
            headers: ["X-internal-delay": "200"]
        )
        _ = client.execute(request: req)
        try? client.syncShutdown()
    }

    func testUncleanShutdownCancelsTasks() throws {
        let client = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup))

        let responses = (1...100).map { _ in
            client.get(url: self.defaultHTTPBinURLPrefix + "wait")
        }

        try client.syncShutdown()

        let results = try EventLoopFuture.whenAllComplete(responses, on: self.clientGroup.next()).timeout(
            after: .seconds(100)
        ).wait()

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
        XCTAssertEqual(.ok, try localClient.get(url: url).wait().status)

        for w in 0..<numberOfWorkers {
            let q = DispatchQueue(label: "worker \(w)")
            q.async(group: allDone) {
                func go() {
                    allWorkersReady.signal()  // tell the driver we're ready
                    allWorkersGo.wait()  // wait for the driver to let us go

                    do {
                        while true {
                            let result = try localClient.get(url: url).wait().status
                            XCTAssertEqual(.ok, result)
                        }
                    } catch {
                        // ok, we failed, pool probably shutdown
                        if let clientError = error as? HTTPClientError,
                            clientError == .cancelled || clientError == .alreadyShutdown
                        {
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
            let request = try HTTPClient.Request(
                url: self.defaultHTTPBinURLPrefix + "get",
                method: .GET,
                headers: ["X-internal-delay": "10"]
            )
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
        XCTAssertNoThrow(
            maybeSecondRequest = try el.submit {
                let neverSucceedingRequest = localClient.get(url: url)
                let secondRequest = neverSucceedingRequest.flatMapError { error in
                    XCTAssertEqual(.cancelled, error as? HTTPClientError)
                    seenError.leave()
                    //     v this is the main part, during the error callout, we call back in
                    return localClient.get(url: url)
                }
                return secondRequest
            }.wait()
        )

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

        XCTAssertEqual(
            .ok,
            try el.flatSubmit { () -> EventLoopFuture<HTTPClient.Response> in
                localClient.get(url: url).flatMap { firstResponse in
                    XCTAssertEqual(.ok, firstResponse.status)
                    return localClient.get(url: url)  // <== interesting bit here
                }
            }.wait().status
        )
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

        XCTAssertNoThrow(XCTAssertNotNil(try web.readInbound()))  // first request: .head

        // Now, the first request is ongoing but not complete, let's start a second one
        let secondRequest = client.get(url: url)
        XCTAssertEqual(.end(nil), try web.readInbound())  // first request: .end

        XCTAssertNoThrow(try web.writeOutbound(.head(.init(version: .init(major: 1, minor: 1), status: .ok))))
        XCTAssertNoThrow(try web.writeOutbound(.end(nil)))

        XCTAssertEqual(.ok, try firstRequest.wait().status)

        // Okay, first request done successfully, let's do the second one too.
        XCTAssertNoThrow(XCTAssertNotNil(try web.readInbound()))  // first request: .head
        XCTAssertEqual(.end(nil), try web.readInbound())  // first request: .end

        XCTAssertNoThrow(try web.writeOutbound(.head(.init(version: .init(major: 1, minor: 1), status: .created))))
        XCTAssertNoThrow(try web.writeOutbound(.end(nil)))
        XCTAssertEqual(.created, try secondRequest.wait().status)
    }

    func testUDSBasic() {
        // This tests just connecting to a URL where the whole URL is the UNIX domain socket path like
        //     unix:///this/is/my/socket.sock
        // We don't really have a path component, so we'll have to use "/"
        XCTAssertNoThrow(
            try TemporaryFileHelpers.withTemporaryUnixDomainSocketPathName { path in
                let localHTTPBin = HTTPBin(bindTarget: .unixDomainSocket(path))
                defer {
                    XCTAssertNoThrow(try localHTTPBin.shutdown())
                }
                let target = "unix://\(path)"
                XCTAssertEqual(
                    ["Yes"[...]],
                    try self.defaultClient.get(url: target).wait().headers[canonicalForm: "X-Is-This-Slash"]
                )
            }
        )
    }

    func testUDSSocketAndPath() {
        // Here, we're testing a URL that's encoding two different paths:
        //
        //  1. a "base path" which is the path to the UNIX domain socket
        //  2. an actual path which is the normal path in a regular URL like https://example.com/this/is/the/path
        XCTAssertNoThrow(
            try TemporaryFileHelpers.withTemporaryUnixDomainSocketPathName { path in
                let localHTTPBin = HTTPBin(bindTarget: .unixDomainSocket(path))
                defer {
                    XCTAssertNoThrow(try localHTTPBin.shutdown())
                }
                guard let target = URL(string: "/echo-uri", relativeTo: URL(string: "unix://\(path)")),
                    let request = try? Request(url: target)
                else {
                    XCTFail("couldn't build URL for request")
                    return
                }
                XCTAssertEqual(
                    ["/echo-uri"[...]],
                    try self.defaultClient.execute(request: request).wait().headers[canonicalForm: "X-Calling-URI"]
                )
            }
        )
    }

    func testHTTPPlusUNIX() {
        // Here, we're testing a URL where the UNIX domain socket is encoded as the host name
        XCTAssertNoThrow(
            try TemporaryFileHelpers.withTemporaryUnixDomainSocketPathName { path in
                let localHTTPBin = HTTPBin(bindTarget: .unixDomainSocket(path))
                defer {
                    XCTAssertNoThrow(try localHTTPBin.shutdown())
                }
                guard let target = URL(httpURLWithSocketPath: path, uri: "/echo-uri"),
                    let request = try? Request(url: target)
                else {
                    XCTFail("couldn't build URL for request")
                    return
                }
                XCTAssertEqual(
                    ["/echo-uri"[...]],
                    try self.defaultClient.execute(request: request).wait().headers[canonicalForm: "X-Calling-URI"]
                )
            }
        )
    }

    func testHTTPSPlusUNIX() {
        // Here, we're testing a URL where the UNIX domain socket is encoded as the host name
        XCTAssertNoThrow(
            try TemporaryFileHelpers.withTemporaryUnixDomainSocketPathName { path in
                let localHTTPBin = HTTPBin(.http1_1(ssl: true), bindTarget: .unixDomainSocket(path))
                let localClient = HTTPClient(
                    eventLoopGroupProvider: .shared(self.clientGroup),
                    configuration: HTTPClient.Configuration(certificateVerification: .none)
                )
                defer {
                    XCTAssertNoThrow(try localClient.syncShutdown())
                    XCTAssertNoThrow(try localHTTPBin.shutdown())
                }
                guard let target = URL(httpsURLWithSocketPath: path, uri: "/echo-uri"),
                    let request = try? Request(url: target)
                else {
                    XCTFail("couldn't build URL for request")
                    return
                }
                XCTAssertEqual(
                    ["/echo-uri"[...]],
                    try localClient.execute(request: request).wait().headers[canonicalForm: "X-Calling-URI"]
                )
            }
        )
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
        let closingRequest = try HTTPClient.Request(
            url: self.defaultHTTPBinURLPrefix + "get",
            headers: ["Connection": "close"]
        )

        for (index, el) in eventLoops.enumerated() {
            if index.isMultiple(of: 2) {
                XCTAssertNoThrow(
                    try localClient.execute(request: request, eventLoop: .delegateAndChannel(on: el)).wait()
                )
            } else {
                XCTAssertNoThrow(
                    try localClient.execute(request: request, eventLoop: .delegateAndChannel(on: el)).wait()
                )
                XCTAssertNoThrow(try localClient.execute(request: closingRequest, eventLoop: .indifferent).wait())
            }
        }
    }

    func testWeRecoverFromServerThatClosesTheConnectionOnUs() {
        final class ServerThatAcceptsThenRejects: ChannelInboundHandler, Sendable {
            typealias InboundIn = HTTPServerRequestPart
            typealias OutboundOut = HTTPServerResponsePart

            let requestNumber: ManagedAtomic<Int>
            let connectionNumber: ManagedAtomic<Int>

            init(requestNumber: ManagedAtomic<Int>, connectionNumber: ManagedAtomic<Int>) {
                self.requestNumber = requestNumber
                self.connectionNumber = connectionNumber
            }

            func channelActive(context: ChannelHandlerContext) {
                _ = self.connectionNumber.loadThenWrappingIncrement(ordering: .relaxed)
            }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                let req = self.unwrapInboundIn(data)

                switch req {
                case .head, .body:
                    ()
                case .end:
                    let last = self.requestNumber.loadThenWrappingIncrement(ordering: .relaxed)
                    switch last {
                    case 0, 2:
                        context.write(
                            self.wrapOutboundOut(.head(.init(version: .init(major: 1, minor: 1), status: .ok))),
                            promise: nil
                        )
                        context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
                    case 1:
                        context.close(promise: nil)
                    default:
                        XCTFail("did not expect request \(last + 1)")
                    }
                }
            }
        }

        let requestNumber = ManagedAtomic(0)
        let connectionNumber = ManagedAtomic(0)
        let sharedStateServerHandler = ServerThatAcceptsThenRejects(
            requestNumber: requestNumber,
            connectionNumber: connectionNumber
        )
        var maybeServer: Channel?
        XCTAssertNoThrow(
            maybeServer = try ServerBootstrap(group: self.serverGroup)
                .serverChannelOption(ChannelOptions.socket(.init(SOL_SOCKET), .init(SO_REUSEADDR)), value: 1)
                .childChannelInitializer { channel in
                    channel.pipeline.configureHTTPServerPipeline().flatMap {
                        // We're deliberately adding a handler which is shared between multiple channels. This is normally
                        // very verboten but this handler is specially crafted to tolerate this.
                        channel.pipeline.addHandler(sharedStateServerHandler)
                    }
                }
                .bind(host: "127.0.0.1", port: 0)
                .wait()
        )
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

        XCTAssertEqual(0, sharedStateServerHandler.connectionNumber.load(ordering: .relaxed))
        XCTAssertEqual(0, sharedStateServerHandler.requestNumber.load(ordering: .relaxed))
        XCTAssertEqual(.ok, try client.get(url: url).wait().status)
        XCTAssertEqual(1, sharedStateServerHandler.connectionNumber.load(ordering: .relaxed))
        XCTAssertEqual(1, sharedStateServerHandler.requestNumber.load(ordering: .relaxed))
        XCTAssertThrowsError(try client.get(url: url).wait().status) { error in
            XCTAssertEqual(.remoteConnectionClosed, error as? HTTPClientError)
        }
        XCTAssertEqual(1, sharedStateServerHandler.connectionNumber.load(ordering: .relaxed))
        XCTAssertEqual(2, sharedStateServerHandler.requestNumber.load(ordering: .relaxed))
        XCTAssertEqual(.ok, try client.get(url: url).wait().status)
        XCTAssertEqual(2, sharedStateServerHandler.connectionNumber.load(ordering: .relaxed))
        XCTAssertEqual(3, sharedStateServerHandler.requestNumber.load(ordering: .relaxed))
    }

    func testPoolClosesIdleConnections() {
        let configuration = HTTPClient.Configuration(
            certificateVerification: .none,
            maximumAllowedIdleTimeInConnectionPool: .milliseconds(100)
        )

        let localClient = HTTPClient(
            eventLoopGroupProvider: .shared(self.clientGroup),
            configuration: configuration
        )
        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
        }

        // Make sure that the idle timeout of the connection pool is properly propagated
        // to the connection pool itself, when using both inits.
        XCTAssertEqual(configuration.connectionPool.idleTimeout, .milliseconds(100))
        XCTAssertEqual(
            configuration.connectionPool.idleTimeout,
            HTTPClient.Configuration(
                certificateVerification: .none,
                connectionPool: .milliseconds(100),
                backgroundActivityLogger: nil
            ).connectionPool.idleTimeout
        )

        XCTAssertNoThrow(try localClient.get(url: self.defaultHTTPBinURLPrefix + "get").wait())
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(self.defaultHTTPBin.activeConnections, 0)
    }

    func testAvoidLeakingTLSHandshakeCompletionPromise() {
        let localClient = HTTPClient(
            eventLoopGroupProvider: .shared(self.clientGroup),
            configuration: .init(timeout: .init(connect: .milliseconds(100)))
        )
        let localHTTPBin = HTTPBin()
        let port = localHTTPBin.port
        XCTAssertNoThrow(try localHTTPBin.shutdown())
        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
        }

        XCTAssertThrowsError(try localClient.get(url: "http://localhost:\(port)").wait()) { error in
            if isTestingNIOTS() {
                #if canImport(Network)
                // We can't be more specific than this.
                XCTAssertTrue(error is HTTPClient.NWTLSError || error is HTTPClient.NWPOSIXError)
                #else
                XCTFail("Impossible condition")
                #endif
            } else {
                XCTAssert(error is NIOConnectionError, "Unexpected error: \(error)")
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

    func testAsyncShutdownDefaultQueue() throws {
        let localClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup))
        let promise = self.clientGroup.next().makePromise(of: Void.self)
        self.clientGroup.next().execute {
            localClient.shutdown { error in
                XCTAssertNil(error)
                promise.succeed(())
            }
        }
        XCTAssertNoThrow(try promise.futureResult.wait())
    }

    func testValidationErrorsAreSurfaced() throws {
        let defaultClient = self.defaultClient!
        let request = try HTTPClient.Request(
            url: self.defaultHTTPBinURLPrefix + "get",
            method: .TRACE,
            body: .stream { _ in
                defaultClient.eventLoopGroup.next().makeSucceededFuture(())
            }
        )
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

            init(
                headPromise: EventLoopPromise<HTTPRequestHead>,
                bodyPromises: [EventLoopPromise<ByteBuffer>],
                endPromise: EventLoopPromise<Void>
            ) {
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
                    context.write(
                        self.wrapOutboundOut(.head(.init(version: .init(major: 1, minor: 1), status: .ok))),
                        promise: nil
                    )
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
                for promise in self.bodyPromises {
                    promise.fail(NotFulfilledError())
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
            try? ServerBootstrap(group: group)
                .childChannelInitializer { channel in
                    channel.pipeline.configureHTTPServerPipeline().flatMapThrowing {
                        try channel.pipeline.syncOperations.addHandler(
                            HTTPServer(
                                headPromise: headPromise,
                                bodyPromises: bodyPromises,
                                endPromise: endPromise
                            )
                        )
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

            return try? HTTPClient.Request(
                url: "http://\(localAddress.ipAddress!):\(localAddress.port!)",
                method: .POST,
                headers: ["transfer-encoding": "chunked"],
                body: .stream { streamWriter in
                    streamWriterPromise.succeed(streamWriter)
                    return sentOffAllBodyPartsPromise.futureResult
                }
            )
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

        XCTAssertEqual(.POST, try headPromise.futureResult.wait().method)
        for bodyChunkNumber in 0..<16 {
            buffer.clear()
            buffer.writeString(String(bodyChunkNumber, radix: 16))
            XCTAssertEqual(1, buffer.readableBytes)
            XCTAssertNoThrow(try streamWriter.write(.byteBuffer(buffer)).wait())
            XCTAssertEqual(buffer, try bodyPromises[bodyChunkNumber].futureResult.wait())
        }
        sentOffAllBodyPartsPromise.succeed(())
        XCTAssertNoThrow(try endPromise.futureResult.wait())
        XCTAssertNoThrow(try runningRequest.wait())
    }

    func testUploadStreamingCallinToleratedFromOtsideEL() throws {
        let defaultClient = self.defaultClient!
        let request = try HTTPClient.Request(
            url: self.defaultHTTPBinURLPrefix + "get",
            method: .POST,
            body: .stream(contentLength: 4) { writer in
                let promise = defaultClient.eventLoopGroup.next().makePromise(of: Void.self)
                // We have to toleare callins from any thread
                DispatchQueue(label: "upload-streaming").async {
                    writer.write(.byteBuffer(ByteBuffer(string: "1234"))).whenComplete { _ in
                        promise.succeed(())
                    }
                }
                return promise.futureResult
            }
        )
        XCTAssertNoThrow(try self.defaultClient.execute(request: request).wait())
    }

    func testWeHandleUsSendingACloseHeaderCorrectly() {
        guard
            let req1 = try? Request(
                url: self.defaultHTTPBinURLPrefix + "stats",
                method: .GET,
                headers: ["connection": "close"]
            ),
            let statsBytes1 = try? self.defaultClient.execute(request: req1).wait().body,
            let stats1 = try? JSONDecoder().decode(RequestInfo.self, from: statsBytes1)
        else {
            XCTFail("request 1 didn't work")
            return
        }
        guard let statsBytes2 = try? self.defaultClient.get(url: self.defaultHTTPBinURLPrefix + "stats").wait().body,
            let stats2 = try? JSONDecoder().decode(RequestInfo.self, from: statsBytes2)
        else {
            XCTFail("request 2 didn't work")
            return
        }
        guard let statsBytes3 = try? self.defaultClient.get(url: self.defaultHTTPBinURLPrefix + "stats").wait().body,
            let stats3 = try? JSONDecoder().decode(RequestInfo.self, from: statsBytes3)
        else {
            XCTFail("request 3 didn't work")
            return
        }

        // req 1 and 2 cannot share the same connection (close header)
        XCTAssertEqual(stats1.connectionNumber + 1, stats2.connectionNumber)
        XCTAssertEqual(stats1.requestNumber, 1)
        XCTAssertEqual(stats2.requestNumber, 1)

        // req 2 and 3 should share the same connection (keep-alive is default)
        XCTAssertEqual(stats2.requestNumber + 1, stats3.requestNumber)
        XCTAssertEqual(stats2.connectionNumber, stats3.connectionNumber)
    }

    func testWeHandleUsReceivingACloseHeaderCorrectly() {
        guard
            let req1 = try? Request(
                url: self.defaultHTTPBinURLPrefix + "stats",
                method: .GET,
                headers: ["X-Send-Back-Header-Connection": "close"]
            ),
            let statsBytes1 = try? self.defaultClient.execute(request: req1).wait().body,
            let stats1 = try? JSONDecoder().decode(RequestInfo.self, from: statsBytes1)
        else {
            XCTFail("request 1 didn't work")
            return
        }
        guard let statsBytes2 = try? self.defaultClient.get(url: self.defaultHTTPBinURLPrefix + "stats").wait().body,
            let stats2 = try? JSONDecoder().decode(RequestInfo.self, from: statsBytes2)
        else {
            XCTFail("request 2 didn't work")
            return
        }
        guard let statsBytes3 = try? self.defaultClient.get(url: self.defaultHTTPBinURLPrefix + "stats").wait().body,
            let stats3 = try? JSONDecoder().decode(RequestInfo.self, from: statsBytes3)
        else {
            XCTFail("request 3 didn't work")
            return
        }

        // req 1 and 2 cannot share the same connection (close header)
        XCTAssertEqual(stats1.connectionNumber + 1, stats2.connectionNumber)
        XCTAssertEqual(stats1.requestNumber, 1)
        XCTAssertEqual(stats2.requestNumber, 1)

        // req 2 and 3 should share the same connection (keep-alive is default)
        XCTAssertEqual(stats2.requestNumber + 1, stats3.requestNumber)
        XCTAssertEqual(stats2.connectionNumber, stats3.connectionNumber)
    }

    func testWeHandleUsSendingACloseHeaderAmongstOtherConnectionHeadersCorrectly() {
        for closeHeader in [("connection", "close"), ("CoNneCTION", "ClOSe")] {
            guard
                let req1 = try? Request(
                    url: self.defaultHTTPBinURLPrefix + "stats",
                    method: .GET,
                    headers: [
                        "X-Send-Back-Header-\(closeHeader.0)":
                            "foo,\(closeHeader.1),bar"
                    ]
                ),
                let statsBytes1 = try? self.defaultClient.execute(request: req1).wait().body,
                let stats1 = try? JSONDecoder().decode(RequestInfo.self, from: statsBytes1)
            else {
                XCTFail("request 1 didn't work")
                return
            }
            guard
                let statsBytes2 = try? self.defaultClient.get(url: self.defaultHTTPBinURLPrefix + "stats").wait().body,
                let stats2 = try? JSONDecoder().decode(RequestInfo.self, from: statsBytes2)
            else {
                XCTFail("request 2 didn't work")
                return
            }
            guard
                let statsBytes3 = try? self.defaultClient.get(url: self.defaultHTTPBinURLPrefix + "stats").wait().body,
                let stats3 = try? JSONDecoder().decode(RequestInfo.self, from: statsBytes3)
            else {
                XCTFail("request 3 didn't work")
                return
            }

            // req 1 and 2 cannot share the same connection (close header)
            XCTAssertEqual(stats1.connectionNumber + 1, stats2.connectionNumber)
            XCTAssertEqual(stats2.requestNumber, 1)

            // req 2 and 3 should share the same connection (keep-alive is default)
            XCTAssertEqual(stats2.requestNumber + 1, stats3.requestNumber)
            XCTAssertEqual(stats2.connectionNumber, stats3.connectionNumber)
        }
    }

    func testWeHandleUsReceivingACloseHeaderAmongstOtherConnectionHeadersCorrectly() {
        for closeHeader in [("connection", "close"), ("CoNneCTION", "ClOSe")] {
            guard
                let req1 = try? Request(
                    url: self.defaultHTTPBinURLPrefix + "stats",
                    method: .GET,
                    headers: [
                        "X-Send-Back-Header-\(closeHeader.0)":
                            "foo,\(closeHeader.1),bar"
                    ]
                ),
                let statsBytes1 = try? self.defaultClient.execute(request: req1).wait().body,
                let stats1 = try? JSONDecoder().decode(RequestInfo.self, from: statsBytes1)
            else {
                XCTFail("request 1 didn't work")
                return
            }
            guard
                let statsBytes2 = try? self.defaultClient.get(url: self.defaultHTTPBinURLPrefix + "stats").wait().body,
                let stats2 = try? JSONDecoder().decode(RequestInfo.self, from: statsBytes2)
            else {
                XCTFail("request 2 didn't work")
                return
            }
            guard
                let statsBytes3 = try? self.defaultClient.get(url: self.defaultHTTPBinURLPrefix + "stats").wait().body,
                let stats3 = try? JSONDecoder().decode(RequestInfo.self, from: statsBytes3)
            else {
                XCTFail("request 3 didn't work")
                return
            }

            // req 1 and 2 cannot share the same connection (close header)
            XCTAssertEqual(stats1.connectionNumber + 1, stats2.connectionNumber)
            XCTAssertEqual(stats2.requestNumber, 1)

            // req 2 and 3 should share the same connection (keep-alive is default)
            XCTAssertEqual(stats2.requestNumber + 1, stats3.requestNumber)
            XCTAssertEqual(stats2.connectionNumber, stats3.connectionNumber)
        }
    }

    func testLoggingCorrectlyAttachesRequestInformationEvenAfterDuringRedirect() {
        var (logStore, logger) = InMemoryLogHandler.makeLogger(logLevel: .trace)
        logger[metadataKey: "custom-request-id"] = "abcd"

        var maybeRequest: HTTPClient.Request?
        XCTAssertNoThrow(
            maybeRequest = try HTTPClient.Request(
                url: "http://localhost:\(self.defaultHTTPBin.port)/redirect/target",
                method: .GET,
                headers: [
                    "X-Target-Redirect-URL": "/get"
                ]
            )
        )
        guard let request = maybeRequest else { return }

        XCTAssertNoThrow(
            try self.defaultClient.execute(
                request: request,
                eventLoop: .indifferent,
                deadline: nil,
                logger: logger
            ).wait()
        )
        let logs = logStore.entries

        XCTAssertTrue(logs.allSatisfy { $0.metadata["custom-request-id"] == "abcd" })

        guard let firstRequestID = logs.first?.metadata["ahc-request-id"] else {
            return XCTFail("could not get first request ID")
        }
        guard let lastRequestID = logs.last?.metadata["ahc-request-id"] else {
            return XCTFail("could not get second request ID")
        }

        let firstRequestLogs = logs.prefix(while: { $0.metadata["ahc-request-id"] == firstRequestID })
        XCTAssertGreaterThan(firstRequestLogs.count, 0)

        let secondRequestLogs = logs.drop(while: { $0.metadata["ahc-request-id"] == firstRequestID })
        XCTAssertGreaterThan(secondRequestLogs.count, 0)
        XCTAssertTrue(secondRequestLogs.allSatisfy { $0.metadata["ahc-request-id"] == lastRequestID })

        for log in logs { print(log) }
    }

    func testLoggingCorrectlyAttachesRequestInformation() {
        let logStore = InMemoryLogHandler()

        var loggerYolo001 = Logger(
            label: "\(#function)",
            factory: { _ in
                logStore
            }
        )
        loggerYolo001.logLevel = .trace
        loggerYolo001[metadataKey: "yolo-request-id"] = "yolo-001"
        var loggerACME002 = Logger(
            label: "\(#function)",
            factory: { _ in
                logStore
            }
        )
        loggerACME002.logLevel = .trace
        loggerACME002[metadataKey: "acme-request-id"] = "acme-002"

        guard let request1 = try? HTTPClient.Request(url: self.defaultHTTPBinURLPrefix + "get"),
            let request2 = try? HTTPClient.Request(url: self.defaultHTTPBinURLPrefix + "stats"),
            let request3 = try? HTTPClient.Request(url: self.defaultHTTPBinURLPrefix + "ok")
        else {
            XCTFail("bad stuff, can't even make request structures")
            return
        }

        // === Request 1 (Yolo001)
        XCTAssertNoThrow(
            try self.defaultClient.execute(
                request: request1,
                eventLoop: .indifferent,
                deadline: nil,
                logger: loggerYolo001
            ).wait()
        )
        let logsAfterReq1 = logStore.entries
        logStore.clear()

        // === Request 2 (Yolo001)
        XCTAssertNoThrow(
            try self.defaultClient.execute(
                request: request2,
                eventLoop: .indifferent,
                deadline: nil,
                logger: loggerYolo001
            ).wait()
        )
        let logsAfterReq2 = logStore.entries
        logStore.clear()

        // === Request 3 (ACME002)
        XCTAssertNoThrow(
            try self.defaultClient.execute(
                request: request3,
                eventLoop: .indifferent,
                deadline: nil,
                logger: loggerACME002
            ).wait()
        )
        let logsAfterReq3 = logStore.entries
        logStore.clear()

        // === Assertions
        XCTAssertGreaterThan(logsAfterReq1.count, 0)
        XCTAssertGreaterThan(logsAfterReq2.count, 0)
        XCTAssertGreaterThan(logsAfterReq3.count, 0)

        XCTAssert(
            logsAfterReq1.allSatisfy { entry in
                if let httpRequestMetadata = entry.metadata["ahc-request-id"],
                    let yoloRequestID = entry.metadata["yolo-request-id"]
                {
                    XCTAssertNil(entry.metadata["acme-request-id"])
                    XCTAssertEqual("yolo-001", yoloRequestID)
                    XCTAssertNotNil(Int("\(httpRequestMetadata)"))
                    return true
                } else {
                    XCTFail("log message doesn't contain the right IDs: \(entry)")
                    return false
                }
            }
        )
        XCTAssert(
            logsAfterReq1.contains { entry in
                // Since a new connection must be created first we expect that the request is queued
                // and log message describing this is emitted.
                entry.message == "Request was queued (waiting for a connection to become available)"
                    && entry.level == .debug
            }
        )
        XCTAssert(
            logsAfterReq1.contains { entry in
                // After the new connection was created we expect a log message that describes that the
                // request was scheduled on a connection. The connection id must be set from here on.
                entry.message == "Request was scheduled on connection"
                    && entry.level == .debug
                    && entry.metadata["ahc-connection-id"] != nil
            }
        )

        XCTAssert(
            logsAfterReq2.allSatisfy { entry in
                if let httpRequestMetadata = entry.metadata["ahc-request-id"],
                    let yoloRequestID = entry.metadata["yolo-request-id"]
                {
                    XCTAssertNil(entry.metadata["acme-request-id"])
                    XCTAssertEqual("yolo-001", yoloRequestID)
                    XCTAssertNotNil(Int("\(httpRequestMetadata)"))
                    return true
                } else {
                    XCTFail("log message doesn't contain the right IDs: \(entry)")
                    return false
                }
            }
        )
        XCTAssertFalse(
            logsAfterReq2.contains { entry in
                entry.message == "Request was queued (waiting for a connection to become available)"
            }
        )
        XCTAssert(
            logsAfterReq2.contains { entry in
                entry.message == "Request was scheduled on connection"
                    && entry.level == .debug
                    && entry.metadata["ahc-connection-id"] != nil
            }
        )

        XCTAssert(
            logsAfterReq3.allSatisfy { entry in
                if let httpRequestMetadata = entry.metadata["ahc-request-id"],
                    let acmeRequestID = entry.metadata["acme-request-id"]
                {
                    XCTAssertNil(entry.metadata["yolo-request-id"])
                    XCTAssertEqual("acme-002", acmeRequestID)
                    XCTAssertNotNil(Int("\(httpRequestMetadata)"))
                    return true
                } else {
                    XCTFail("log message doesn't contain the right IDs: \(entry)")
                    return false
                }
            }
        )
        XCTAssertFalse(
            logsAfterReq3.contains { entry in
                entry.message == "Request was queued (waiting for a connection to become available)"
            }
        )
        XCTAssert(
            logsAfterReq3.contains { entry in
                entry.message == "Request was scheduled on connection"
                    && entry.level == .debug
                    && entry.metadata["ahc-connection-id"] != nil
            }
        )
    }

    func testNothingIsLoggedAtInfoOrHigher() {
        let (logStore, logger) = InMemoryLogHandler.makeLogger(logLevel: .info)

        guard let request1 = try? HTTPClient.Request(url: self.defaultHTTPBinURLPrefix + "get"),
            let request2 = try? HTTPClient.Request(url: self.defaultHTTPBinURLPrefix + "stats")
        else {
            XCTFail("bad stuff, can't even make request structures")
            return
        }

        // === Request 1
        XCTAssertNoThrow(
            try self.defaultClient.execute(
                request: request1,
                eventLoop: .indifferent,
                deadline: nil,
                logger: logger
            ).wait()
        )
        XCTAssertEqual(0, logStore.entries.count)

        // === Request 2
        XCTAssertNoThrow(
            try self.defaultClient.execute(
                request: request2,
                eventLoop: .indifferent,
                deadline: nil,
                logger: logger
            ).wait()
        )
        XCTAssertEqual(0, logStore.entries.count)

        // === Synthesized Request
        XCTAssertNoThrow(
            try self.defaultClient.execute(
                .GET,
                url: self.defaultHTTPBinURLPrefix + "get",
                body: nil,
                deadline: nil,
                logger: logger
            ).wait()
        )
        XCTAssertEqual(0, logStore.entries.count)

        XCTAssertEqual(0, self.backgroundLogStore.entries.filter { $0.level >= .info }.count)

        // === Synthesized Socket Path Request
        XCTAssertNoThrow(
            try TemporaryFileHelpers.withTemporaryUnixDomainSocketPathName { path in
                let (backgroundLogStore, backgroundLogger) = InMemoryLogHandler.makeLogger(logLevel: .trace)

                let localSocketPathHTTPBin = HTTPBin(bindTarget: .unixDomainSocket(path))
                let localClient = HTTPClient(
                    eventLoopGroupProvider: .shared(self.clientGroup),
                    backgroundActivityLogger: backgroundLogger
                )
                defer {
                    XCTAssertNoThrow(try localClient.syncShutdown())
                    XCTAssertNoThrow(try localSocketPathHTTPBin.shutdown())
                }

                XCTAssertNoThrow(
                    try localClient.execute(
                        .GET,
                        socketPath: path,
                        urlPath: "get",
                        body: nil,
                        deadline: nil,
                        logger: logger
                    ).wait()
                )
                XCTAssertEqual(0, logStore.entries.count)

                XCTAssertEqual(0, backgroundLogStore.entries.filter { $0.level >= .info }.count)
            }
        )

        // === Synthesized Secure Socket Path Request
        XCTAssertNoThrow(
            try TemporaryFileHelpers.withTemporaryUnixDomainSocketPathName { path in
                let (backgroundLogStore, backgroundLogger) = InMemoryLogHandler.makeLogger(logLevel: .trace)

                let localSocketPathHTTPBin = HTTPBin(.http1_1(ssl: true), bindTarget: .unixDomainSocket(path))
                let localClient = HTTPClient(
                    eventLoopGroupProvider: .shared(self.clientGroup),
                    configuration: HTTPClient.Configuration(certificateVerification: .none),
                    backgroundActivityLogger: backgroundLogger
                )
                defer {
                    XCTAssertNoThrow(try localClient.syncShutdown())
                    XCTAssertNoThrow(try localSocketPathHTTPBin.shutdown())
                }

                XCTAssertNoThrow(
                    try localClient.execute(
                        .GET,
                        secureSocketPath: path,
                        urlPath: "get",
                        body: nil,
                        deadline: nil,
                        logger: logger
                    ).wait()
                )
                XCTAssertEqual(0, logStore.entries.count)

                XCTAssertEqual(0, backgroundLogStore.entries.filter { $0.level >= .info }.count)
            }
        )
    }

    func testAllMethodsLog() {
        func checkExpectationsWithLogger<T>(type: String, _ body: (Logger, String) throws -> T) throws -> T {
            var (logStore, logger) = InMemoryLogHandler.makeLogger(logLevel: .trace)
            logger[metadataKey: "req"] = "yo-\(type)"

            let url = "not-found/request/\(type))"
            let result = try body(logger, url)

            XCTAssertGreaterThan(logStore.entries.count, 0)
            for entry in logStore.entries {
                XCTAssertEqual("yo-\(type)", entry.metadata["req"] ?? "n/a")
                XCTAssertNotNil(Int(entry.metadata["ahc-request-id"]?.description ?? "n/a"))
            }
            return result
        }

        XCTAssertEqual(
            .notFound,
            try checkExpectationsWithLogger(type: "GET") { logger, url in
                try self.defaultClient.get(url: self.defaultHTTPBinURLPrefix + url, logger: logger).wait()
            }.status
        )

        XCTAssertEqual(
            .notFound,
            try checkExpectationsWithLogger(type: "PUT") { logger, url in
                try self.defaultClient.put(url: self.defaultHTTPBinURLPrefix + url, logger: logger).wait()
            }.status
        )

        XCTAssertEqual(
            .notFound,
            try checkExpectationsWithLogger(type: "POST") { logger, url in
                try self.defaultClient.post(url: self.defaultHTTPBinURLPrefix + url, logger: logger).wait()
            }.status
        )

        XCTAssertEqual(
            .notFound,
            try checkExpectationsWithLogger(type: "DELETE") { logger, url in
                try self.defaultClient.delete(url: self.defaultHTTPBinURLPrefix + url, logger: logger).wait()
            }.status
        )

        XCTAssertEqual(
            .notFound,
            try checkExpectationsWithLogger(type: "PATCH") { logger, url in
                try self.defaultClient.patch(url: self.defaultHTTPBinURLPrefix + url, logger: logger).wait()
            }.status
        )

        XCTAssertEqual(
            .notFound,
            try checkExpectationsWithLogger(type: "CHECKOUT") { logger, url in
                try self.defaultClient.execute(.CHECKOUT, url: self.defaultHTTPBinURLPrefix + url, logger: logger)
                    .wait()
            }.status
        )

        // No background activity expected here.
        XCTAssertEqual(0, self.backgroundLogStore.entries.filter { $0.level >= .debug }.count)

        XCTAssertNoThrow(
            try TemporaryFileHelpers.withTemporaryUnixDomainSocketPathName { path in
                let (backgroundLogStore, backgroundLogger) = InMemoryLogHandler.makeLogger(logLevel: .trace)

                let localSocketPathHTTPBin = HTTPBin(bindTarget: .unixDomainSocket(path))
                let localClient = HTTPClient(
                    eventLoopGroupProvider: .shared(self.clientGroup),
                    backgroundActivityLogger: backgroundLogger
                )
                defer {
                    XCTAssertNoThrow(try localClient.syncShutdown())
                    XCTAssertNoThrow(try localSocketPathHTTPBin.shutdown())
                }

                XCTAssertEqual(
                    .notFound,
                    try checkExpectationsWithLogger(type: "GET") { logger, url in
                        try localClient.execute(socketPath: path, urlPath: url, logger: logger).wait()
                    }.status
                )

                // No background activity expected here.
                XCTAssertEqual(0, backgroundLogStore.entries.filter { $0.level >= .debug }.count)
            }
        )

        XCTAssertNoThrow(
            try TemporaryFileHelpers.withTemporaryUnixDomainSocketPathName { path in
                let (backgroundLogStore, backgroundLogger) = InMemoryLogHandler.makeLogger(logLevel: .trace)

                let localSocketPathHTTPBin = HTTPBin(.http1_1(ssl: true), bindTarget: .unixDomainSocket(path))
                let localClient = HTTPClient(
                    eventLoopGroupProvider: .shared(self.clientGroup),
                    configuration: HTTPClient.Configuration(certificateVerification: .none),
                    backgroundActivityLogger: backgroundLogger
                )
                defer {
                    XCTAssertNoThrow(try localClient.syncShutdown())
                    XCTAssertNoThrow(try localSocketPathHTTPBin.shutdown())
                }

                XCTAssertEqual(
                    .notFound,
                    try checkExpectationsWithLogger(type: "GET") { logger, url in
                        try localClient.execute(secureSocketPath: path, urlPath: url, logger: logger).wait()
                    }.status
                )

                // No background activity expected here.
                XCTAssertEqual(0, backgroundLogStore.entries.filter { $0.level >= .debug }.count)
            }
        )
    }

    func testClosingIdleConnectionsInPoolLogsInTheBackground() {
        XCTAssertNoThrow(try self.defaultClient.get(url: self.defaultHTTPBinURLPrefix + "/get").wait())

        XCTAssertNoThrow(try self.defaultClient.syncShutdown())

        XCTAssertGreaterThanOrEqual(self.backgroundLogStore.entries.count, 0)
        XCTAssert(
            self.backgroundLogStore.entries.contains { entry in
                entry.message == "Shutting down connection pool"
            }
        )
        XCTAssert(
            self.backgroundLogStore.entries.allSatisfy { entry in
                entry.metadata["ahc-request-id"] == nil && entry.metadata["ahc-request"] == nil
                    && entry.metadata["ahc-pool-key"] != nil
            }
        )

        self.defaultClient = nil  // so it doesn't get shut down again.
    }

    func testUploadStreamingNoLength() throws {
        let server = NIOHTTP1TestServer(group: self.serverGroup)
        let client = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup))
        defer {
            XCTAssertNoThrow(try client.syncShutdown())
            XCTAssertNoThrow(try server.stop())
        }

        var request = try HTTPClient.Request(url: "http://localhost:\(server.serverPort)/")
        request.body = .stream { writer in
            writer.write(.byteBuffer(ByteBuffer(string: "1234")))
        }

        let future = client.execute(request: request)

        switch try server.readInbound() {
        case .head(let head):
            XCTAssertEqual(head.headers["transfer-encoding"], ["chunked"])
        default:
            XCTFail("Unexpected part")
        }

        XCTAssertNoThrow(try server.readInbound())  // .body
        XCTAssertNoThrow(try server.readInbound())  // .end

        XCTAssertNoThrow(try server.writeOutbound(.head(.init(version: .init(major: 1, minor: 1), status: .ok))))
        XCTAssertNoThrow(try server.writeOutbound(.end(nil)))

        XCTAssertNoThrow(try future.wait())
    }

    func testConnectErrorPropagatedToDelegate() throws {
        final class TestDelegate: HTTPClientResponseDelegate {
            typealias Response = Void
            let error = NIOLockedValueBox<Error?>(nil)
            func didFinishRequest(task: HTTPClient.Task<Void>) throws {}
            func didReceiveError(task: HTTPClient.Task<Response>, _ error: Error) {
                self.error.withLockedValue { $0 = error }
            }
        }

        let httpClient = HTTPClient(
            eventLoopGroupProvider: .shared(self.clientGroup),
            configuration: .init(timeout: .init(connect: .milliseconds(10)))
        )

        defer {
            XCTAssertNoThrow(try httpClient.syncShutdown())
        }

        // This must throw as 198.51.100.254 is reserved for documentation only
        let request = try HTTPClient.Request(url: "http://198.51.100.254:65535/get")
        let delegate = TestDelegate()

        XCTAssertThrowsError(try httpClient.execute(request: request, delegate: delegate).wait()) {
            XCTAssertEqualTypeAndValue($0, HTTPClientError.connectTimeout)
            XCTAssertEqualTypeAndValue(delegate.error.withLockedValue { $0 }, HTTPClientError.connectTimeout)
        }
    }

    func testDelegateCallinsTolerateRandomEL() throws {
        final class TestDelegate: HTTPClientResponseDelegate {
            typealias Response = Void
            let eventLoop: EventLoop

            init(eventLoop: EventLoop) {
                self.eventLoop = eventLoop
            }

            func didReceiveHead(task: HTTPClient.Task<Void>, _: HTTPResponseHead) -> EventLoopFuture<Void> {
                self.eventLoop.makeSucceededFuture(())
            }

            func didReceiveBodyPart(task: HTTPClient.Task<Void>, _: ByteBuffer) -> EventLoopFuture<Void> {
                self.eventLoop.makeSucceededFuture(())
            }

            func didFinishRequest(task: HTTPClient.Task<Void>) throws {}
        }

        let elg = getDefaultEventLoopGroup(numberOfThreads: 3)
        let first = elg.next()
        let second = elg.next()
        XCTAssertFalse(first === second)

        let httpServer = NIOHTTP1TestServer(group: self.serverGroup)
        let httpClient = HTTPClient(eventLoopGroupProvider: .shared(first))
        defer {
            XCTAssertNoThrow(try httpClient.syncShutdown())
            XCTAssertNoThrow(try httpServer.stop())
            XCTAssertNoThrow(try elg.syncShutdownGracefully())
        }

        let delegate = TestDelegate(eventLoop: second)
        let request = try HTTPClient.Request(url: "http://localhost:\(httpServer.serverPort)/")
        let future = httpClient.execute(request: request, delegate: delegate)

        XCTAssertNoThrow(try httpServer.readInbound())  // .head
        XCTAssertNoThrow(try httpServer.readInbound())  // .end

        XCTAssertNoThrow(try httpServer.writeOutbound(.head(.init(version: .init(major: 1, minor: 1), status: .ok))))
        XCTAssertNoThrow(try httpServer.writeOutbound(.body(.byteBuffer(ByteBuffer(string: "1234")))))
        XCTAssertNoThrow(try httpServer.writeOutbound(.end(nil)))

        XCTAssertNoThrow(try future.wait())
    }

    func testDelegateGetsErrorsFromCreatingRequestBag() throws {
        // We want to test that we propagate errors to the delegate from failures to construct the
        // request bag. Those errors only come from invalid headers.
        final class TestDelegate: HTTPClientResponseDelegate, Sendable {
            typealias Response = Void
            let error: NIOLockedValueBox<Error?> = .init(nil)
            func didFinishRequest(task: HTTPClient.Task<Void>) throws {}
            func didReceiveError(task: HTTPClient.Task<Response>, _ error: Error) {
                self.error.withLockedValue { $0 = error }
            }
        }

        let httpClient = HTTPClient(
            eventLoopGroupProvider: .shared(self.clientGroup)
        )

        defer {
            XCTAssertNoThrow(try httpClient.syncShutdown())
        }

        // 198.51.100.254 is reserved for documentation only
        var request = try HTTPClient.Request(url: "http://198.51.100.254:65535/get")
        request.headers.replaceOrAdd(name: "Not-ASCII", value: "not-fine\n")
        let delegate = TestDelegate()

        XCTAssertThrowsError(try httpClient.execute(request: request, delegate: delegate).wait()) {
            XCTAssertEqualTypeAndValue($0, HTTPClientError.invalidHeaderFieldValues(["not-fine\n"]))
            XCTAssertEqualTypeAndValue(
                delegate.error.withLockedValue { $0 },
                HTTPClientError.invalidHeaderFieldValues(["not-fine\n"])
            )
        }
    }

    func testContentLengthTooLongFails() throws {
        let url = self.defaultHTTPBinURLPrefix + "post"
        let defaultClient = self.defaultClient!
        XCTAssertThrowsError(
            try self.defaultClient.execute(
                request:
                    Request(
                        url: url,
                        body: .stream(contentLength: 10) { streamWriter in
                            let promise = defaultClient.eventLoopGroup.next().makePromise(of: Void.self)
                            DispatchQueue(label: "content-length-test").async {
                                streamWriter.write(.byteBuffer(ByteBuffer(string: "1"))).cascade(to: promise)
                            }
                            return promise.futureResult
                        }
                    )
            ).wait()
        ) { error in
            XCTAssertEqual(error as! HTTPClientError, HTTPClientError.bodyLengthMismatch)
        }
        // Quickly try another request and check that it works.
        let response = try self.defaultClient.get(url: self.defaultHTTPBinURLPrefix + "get").wait()
        guard var body = response.body else {
            XCTFail("Body missing: \(response)")
            return
        }
        guard let info = try body.readJSONDecodable(RequestInfo.self, length: body.readableBytes) else {
            XCTFail("Cannot parse body: \(body.readableBytesView.map { $0 })")
            return
        }
        XCTAssertEqual(info.connectionNumber, 1)
        XCTAssertEqual(info.requestNumber, 1)
    }

    // currently gets stuck because of #250 the server just never replies
    func testContentLengthTooShortFails() throws {
        let url = self.defaultHTTPBinURLPrefix + "post"
        let tooLong = "XBAD BAD BAD NOT HTTP/1.1\r\n\r\n"
        XCTAssertThrowsError(
            try self.defaultClient.execute(
                request:
                    Request(
                        url: url,
                        body: .stream(contentLength: 1) { streamWriter in
                            streamWriter.write(.byteBuffer(ByteBuffer(string: tooLong)))
                        }
                    )
            ).wait()
        ) { error in
            XCTAssertEqual(error as! HTTPClientError, HTTPClientError.bodyLengthMismatch)
        }
        // Quickly try another request and check that it works. If we by accident wrote some extra bytes into the
        // stream (and reuse the connection) that could cause problems.
        let response = try self.defaultClient.get(url: self.defaultHTTPBinURLPrefix + "get").wait()
        guard var body = response.body else {
            XCTFail("Body missing: \(response)")
            return
        }
        guard let info = try body.readJSONDecodable(RequestInfo.self, length: body.readableBytes) else {
            XCTFail("Cannot parse body: \(body.readableBytesView.map { $0 })")
            return
        }
        XCTAssertEqual(info.connectionNumber, 1)
        XCTAssertEqual(info.requestNumber, 1)
    }

    func testBodyUploadAfterEndFails() {
        let url = self.defaultHTTPBinURLPrefix + "post"

        let uploader = { @Sendable (_ streamWriter: HTTPClient.Body.StreamWriter) -> EventLoopFuture<Void> in
            let done = streamWriter.write(.byteBuffer(ByteBuffer(string: "X")))
            done.recover { error in
                XCTFail("unexpected error \(error)")
            }.whenSuccess {
                // This is executed when we have already sent the end of the request.
                done.eventLoop.execute {
                    streamWriter.write(.byteBuffer(ByteBuffer(string: "BAD BAD BAD"))).whenComplete { result in
                        switch result {
                        case .success:
                            XCTFail("we succeeded writing bytes after the end!?")
                        case .failure(let error):
                            XCTAssertEqual(HTTPClientError.writeAfterRequestSent, error as? HTTPClientError)
                        }
                    }
                }
            }
            return done
        }

        var request: HTTPClient.Request?
        XCTAssertNoThrow(request = try Request(url: url, body: .stream(contentLength: 1, uploader)))
        XCTAssertThrowsError(try self.defaultClient.execute(request: XCTUnwrap(request)).wait()) {
            XCTAssertEqual($0 as? HTTPClientError, .writeAfterRequestSent)
        }

        // Quickly try another request and check that it works. If we by accident wrote some extra bytes into the
        // stream (and reuse the connection) that could cause problems.
        XCTAssertNoThrow(try self.defaultClient.get(url: self.defaultHTTPBinURLPrefix + "get").wait())
    }

    func testDoubleError() throws {
        // This is needed to that connection pool will not get into closed state when we release
        // second connection.
        _ = self.defaultClient.get(url: "http://localhost:\(self.defaultHTTPBin.port)/events/10/1")

        let clientGroup = self.clientGroup!
        var request = try HTTPClient.Request(url: "http://localhost:\(self.defaultHTTPBin.port)/wait", method: .POST)
        request.body = .stream { writer in
            // Start writing chunks so tha we will try to write after read timeout is thrown
            for _ in 1...10 {
                _ = writer.write(.byteBuffer(ByteBuffer(string: "1234")))
            }

            let promise = clientGroup.next().makePromise(of: Void.self)
            clientGroup.next().scheduleTask(in: .milliseconds(3)) {
                writer.write(.byteBuffer(ByteBuffer(string: "1234"))).cascade(to: promise)
            }

            return promise.futureResult
        }

        // We specify a deadline of 2 ms co that request will be timed out before all chunks are writtent,
        // we need to verify that second error on write after timeout does not lead to double-release.
        XCTAssertThrowsError(
            try self.defaultClient.execute(request: request, deadline: .now() + .milliseconds(2)).wait()
        )
    }

    func testSSLHandshakeErrorPropagation() throws {
        final class CloseHandler: ChannelInboundHandler, Sendable {
            typealias InboundIn = Any

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                context.close(promise: nil)
            }
        }

        let server = try ServerBootstrap(group: self.serverGroup)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(CloseHandler())
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait()

        defer {
            XCTAssertNoThrow(try server.close().wait())
        }

        var timeout = HTTPClient.Configuration.Timeout(connect: .seconds(10))
        if isTestingNIOTS() {
            // If we are using Network.framework, we set the connect timeout down very low here
            // because on NIOTS a failing TLS handshake manifests as a connect timeout.
            // Note that we do this here to prove that we correctly manifest the underlying error:
            // DO NOT CHANGE THIS TO DISABLE WAITING FOR CONNECTIVITY.
            timeout.connect = .milliseconds(100)
        }

        let config = HTTPClient.Configuration(timeout: timeout)
        let client = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup), configuration: config)
        defer {
            XCTAssertNoThrow(try client.syncShutdown())
        }

        let request = try Request(url: "https://127.0.0.1:\(server.localAddress!.port!)", method: .GET)
        let task = client.execute(request: request, delegate: TestHTTPDelegate())

        XCTAssertThrowsError(try task.wait()) { error in
            if isTestingNIOTS() {
                #if canImport(Network)
                // We can't be more specific than this.
                XCTAssertTrue(error is HTTPClient.NWTLSError)
                #else
                XCTFail("Impossible condition")
                #endif
            } else {
                switch error as? NIOSSLError {
                case .some(.handshakeFailed(.sslError(_))): break
                default: XCTFail("Handshake failed with unexpected error: \(String(describing: error))")
                }
            }
        }
    }

    func testSSLHandshakeErrorPropagationDelayedClose() throws {
        // This is as the test above, but the close handler delays its close action by a few hundred ms.
        // This will tend to catch the pipeline at different weird stages, and flush out different bugs.
        final class CloseHandler: ChannelInboundHandler, Sendable {
            typealias InboundIn = Any

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                context.eventLoop.assumeIsolated().scheduleTask(in: .milliseconds(100)) {
                    context.close(promise: nil)
                }
            }
        }

        let server = try ServerBootstrap(group: self.serverGroup)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(CloseHandler())
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait()

        defer {
            XCTAssertNoThrow(try server.close().wait())
        }

        var timeout = HTTPClient.Configuration.Timeout(connect: .seconds(10))
        if isTestingNIOTS() {
            // If we are using Network.framework, we set the connect timeout down very low here
            // because on NIOTS a failing TLS handshake manifests as a connect timeout.
            timeout.connect = .milliseconds(300)
        }

        let config = HTTPClient.Configuration(timeout: timeout)
        let client = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup), configuration: config)
        defer {
            XCTAssertNoThrow(try client.syncShutdown())
        }

        let request = try Request(url: "https://127.0.0.1:\(server.localAddress!.port!)", method: .GET)
        let task = client.execute(request: request, delegate: TestHTTPDelegate())

        XCTAssertThrowsError(try task.wait()) { error in
            if isTestingNIOTS() {
                #if canImport(Network)
                // We can't be more specific than this.
                XCTAssertTrue(error is HTTPClient.NWTLSError)
                #else
                XCTFail("Impossible condition")
                #endif
            } else {
                switch error as? NIOSSLError {
                case .some(.handshakeFailed(.sslError(_))): break
                default: XCTFail("Handshake failed with unexpected error: \(String(describing: error))")
                }
            }
        }
    }

    func testWeCloseConnectionsWhenConnectionCloseSetByServer() throws {
        let group = DispatchGroup()
        group.enter()

        let server = try ServerBootstrap(group: self.serverGroup)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMapThrowing {
                    try channel.pipeline.syncOperations.addHandler(CloseWithoutClosingServerHandler(group.leave))
                }
            }
            .bind(host: "localhost", port: 0)
            .wait()

        defer {
            server.close(promise: nil)
        }

        // Simple request, should go great.
        XCTAssertNoThrow(try self.defaultClient.get(url: "http://localhost:\(server.localAddress!.port!)/").wait())

        // Shouldn't need more than 100ms of waiting to see the close.
        let result = group.wait(timeout: DispatchTime.now() + DispatchTimeInterval.milliseconds(100))
        XCTAssertEqual(result, .success, "we never closed the connection!")
    }

    // In this test, we test that a request can continue to stream its body after the response head,
    // was received. The client sends a number to the server and waits for the server to echo the
    // number. Once the client receives the echoed number, it will continue with the next number.
    // The client and server ping/pong 30 times.
    func testBiDirectionalStreaming() {
        let httpBin = HTTPBin(.http1_1(ssl: false, compress: false)) { _ in HTTPEchoHandler() }
        defer { XCTAssertNoThrow(try httpBin.shutdown()) }

        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully()) }
        let writeEL = eventLoopGroup.next()
        let delegateEL = eventLoopGroup.next()

        let httpClient = HTTPClient(eventLoopGroupProvider: .shared(eventLoopGroup))
        defer { XCTAssertNoThrow(try httpClient.syncShutdown()) }

        let delegate = ResponseStreamDelegate(eventLoop: delegateEL)

        let body: HTTPClient.Body = .stream { writer in
            let finalPromise = writeEL.makePromise(of: Void.self)

            @Sendable func writeLoop(_ writer: HTTPClient.Body.StreamWriter, index: Int) {
                // always invoke from the wrong el to test thread safety
                writeEL.preconditionInEventLoop()

                if index >= 30 {
                    return finalPromise.succeed(())
                }

                let sent = ByteBuffer(integer: index)
                writer.write(.byteBuffer(sent)).flatMap { () -> EventLoopFuture<ByteBuffer?> in
                    // ensure, that the writer dispatches back to the expected delegate el.
                    delegateEL.preconditionInEventLoop()
                    return delegate.next()
                }.whenComplete { result in
                    switch result {
                    case .success(let returned):
                        XCTAssertEqual(returned, sent)

                        writeEL.execute {
                            writeLoop(writer, index: index + 1)
                        }

                    case .failure(let error):
                        finalPromise.fail(error)
                    }
                }
            }

            writeEL.execute {
                writeLoop(writer, index: 0)
            }

            return finalPromise.futureResult
        }

        let request = try! HTTPClient.Request(url: "http://localhost:\(httpBin.port)", body: body)
        let future = httpClient.execute(request: request, delegate: delegate, eventLoop: .delegate(on: delegateEL))

        XCTAssertNoThrow(try future.wait())
        XCTAssertNil(try delegate.next().wait())
    }

    func testResponseAccumulatorMaxBodySizeLimitExceedingWithContentLength() throws {
        let httpBin = HTTPBin(.http1_1(ssl: false, compress: false)) { _ in HTTPEchoHandler() }
        defer { XCTAssertNoThrow(try httpBin.shutdown()) }

        let body = ByteBuffer(bytes: 0..<11)

        var request = try Request(url: httpBin.baseURL)
        request.body = .byteBuffer(body)
        XCTAssertThrowsError(
            try self.defaultClient.execute(
                request: request,
                delegate: ResponseAccumulator(request: request, maxBodySize: 10)
            ).wait()
        ) { error in
            XCTAssertTrue(error is ResponseAccumulator.ResponseTooBigError, "unexpected error \(error)")
        }
    }

    func testResponseAccumulatorMaxBodySizeLimitNotExceedingWithContentLength() throws {
        let httpBin = HTTPBin(.http1_1(ssl: false, compress: false)) { _ in HTTPEchoHandler() }
        defer { XCTAssertNoThrow(try httpBin.shutdown()) }

        let body = ByteBuffer(bytes: 0..<10)

        var request = try Request(url: httpBin.baseURL)
        request.body = .byteBuffer(body)
        let response = try self.defaultClient.execute(
            request: request,
            delegate: ResponseAccumulator(request: request, maxBodySize: 10)
        ).wait()

        XCTAssertEqual(response.body, body)
    }

    func testResponseAccumulatorMaxBodySizeLimitExceedingWithContentLengthButMethodIsHead() throws {
        let httpBin = HTTPBin(.http1_1(ssl: false, compress: false)) { _ in HTTPEchoHeaders() }
        defer { XCTAssertNoThrow(try httpBin.shutdown()) }

        let body = ByteBuffer(bytes: 0..<11)

        var request = try Request(url: httpBin.baseURL, method: .HEAD)
        request.body = .byteBuffer(body)
        let response = try self.defaultClient.execute(
            request: request,
            delegate: ResponseAccumulator(request: request, maxBodySize: 10)
        ).wait()

        XCTAssertEqual(response.body ?? ByteBuffer(), ByteBuffer())
    }

    func testResponseAccumulatorMaxBodySizeLimitExceedingWithTransferEncodingChuncked() throws {
        let httpBin = HTTPBin(.http1_1(ssl: false, compress: false)) { _ in HTTPEchoHandler() }
        defer { XCTAssertNoThrow(try httpBin.shutdown()) }

        let body = ByteBuffer(bytes: 0..<11)

        var request = try Request(url: httpBin.baseURL)
        request.body = .stream { writer in
            writer.write(.byteBuffer(body))
        }
        XCTAssertThrowsError(
            try self.defaultClient.execute(
                request: request,
                delegate: ResponseAccumulator(request: request, maxBodySize: 10)
            ).wait()
        ) { error in
            XCTAssertTrue(error is ResponseAccumulator.ResponseTooBigError, "unexpected error \(error)")
        }
    }

    func testResponseAccumulatorMaxBodySizeLimitNotExceedingWithTransferEncodingChuncked() throws {
        let httpBin = HTTPBin(.http1_1(ssl: false, compress: false)) { _ in HTTPEchoHandler() }
        defer { XCTAssertNoThrow(try httpBin.shutdown()) }

        let body = ByteBuffer(bytes: 0..<10)

        var request = try Request(url: httpBin.baseURL)
        request.body = .stream { writer in
            writer.write(.byteBuffer(body))
        }
        let response = try self.defaultClient.execute(
            request: request,
            delegate: ResponseAccumulator(request: request, maxBodySize: 10)
        ).wait()

        XCTAssertEqual(response.body, body)
    }

    // In this test, we test that a request can continue to stream its body after the response head and end
    // was received where the end is a 200.
    func testBiDirectionalStreamingEarly200() {
        let httpBin = HTTPBin(.http1_1(ssl: false, compress: false)) { _ in
            HTTP200DelayedHandler(bodyPartsBeforeResponse: 1)
        }
        defer { XCTAssertNoThrow(try httpBin.shutdown()) }

        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully()) }
        let writeEL = eventLoopGroup.next()
        let delegateEL = eventLoopGroup.next()

        let httpClient = HTTPClient(eventLoopGroupProvider: .shared(eventLoopGroup))
        defer { XCTAssertNoThrow(try httpClient.syncShutdown()) }

        let delegate = ResponseStreamDelegate(eventLoop: delegateEL)

        let body: HTTPClient.Body = .stream { writer in
            let finalPromise = writeEL.makePromise(of: Void.self)

            @Sendable func writeLoop(_ writer: HTTPClient.Body.StreamWriter, index: Int) {
                // always invoke from the wrong el to test thread safety
                writeEL.preconditionInEventLoop()

                if index >= 30 {
                    return finalPromise.succeed(())
                }

                let sent = ByteBuffer(integer: index)
                writer.write(.byteBuffer(sent)).whenComplete { result in
                    switch result {
                    case .success:
                        writeEL.execute {
                            writeLoop(writer, index: index + 1)
                        }

                    case .failure(let error):
                        finalPromise.fail(error)
                    }
                }
            }

            writeEL.execute {
                writeLoop(writer, index: 0)
            }

            return finalPromise.futureResult
        }

        let request = try! HTTPClient.Request(url: "http://localhost:\(httpBin.port)", body: body)
        let future = httpClient.execute(request: request, delegate: delegate, eventLoop: .delegate(on: delegateEL))
        XCTAssertNoThrow(try future.wait())
        XCTAssertNil(try delegate.next().wait())
    }

    // This test is identical to the one above, except that we send another request immediately after. This is a regression
    // test for https://github.com/swift-server/async-http-client/issues/595.
    func testBiDirectionalStreamingEarly200DoesntPreventUsFromSendingMoreRequests() {
        let httpBin = HTTPBin(.http1_1(ssl: false, compress: false)) { _ in
            HTTP200DelayedHandler(bodyPartsBeforeResponse: 1)
        }
        defer { XCTAssertNoThrow(try httpBin.shutdown()) }

        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully()) }
        let writeEL = eventLoopGroup.next()

        let httpClient = HTTPClient(eventLoopGroupProvider: .shared(eventLoopGroup))
        defer { XCTAssertNoThrow(try httpClient.syncShutdown()) }

        let body: HTTPClient.Body = .stream { writer in
            let finalPromise = writeEL.makePromise(of: Void.self)

            @Sendable func writeLoop(_ writer: HTTPClient.Body.StreamWriter, index: Int) {
                // always invoke from the wrong el to test thread safety
                writeEL.preconditionInEventLoop()

                if index >= 30 {
                    return finalPromise.succeed(())
                }

                let sent = ByteBuffer(integer: index)
                writer.write(.byteBuffer(sent)).whenComplete { result in
                    switch result {
                    case .success:
                        writeEL.execute {
                            writeLoop(writer, index: index + 1)
                        }

                    case .failure(let error):
                        finalPromise.fail(error)
                    }
                }
            }

            writeEL.execute {
                writeLoop(writer, index: 0)
            }

            return finalPromise.futureResult
        }

        let request = try! HTTPClient.Request(url: "http://localhost:\(httpBin.port)", body: body)
        let future = httpClient.execute(request: request)
        XCTAssertNoThrow(try future.wait())

        // Try another request
        let future2 = httpClient.execute(request: request)
        XCTAssertNoThrow(try future2.wait())
    }

    // This test validates that we correctly close the connection after our body completes when we've streamed a
    // body and received the 2XX response _before_ we finished our stream.
    func testCloseConnectionAfterEarly2XXWhenStreaming() {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully()) }

        let onClosePromise = eventLoopGroup.next().makePromise(of: Void.self)
        let httpBin = HTTPBin(.http1_1(ssl: false, compress: false)) { _ in
            ExpectClosureServerHandler(onClosePromise: onClosePromise)
        }
        defer { XCTAssertNoThrow(try httpBin.shutdown()) }

        let writeEL = eventLoopGroup.next()

        let httpClient = HTTPClient(eventLoopGroupProvider: .shared(eventLoopGroup))
        defer { XCTAssertNoThrow(try httpClient.syncShutdown()) }

        let body: HTTPClient.Body = .stream { writer in
            let finalPromise = writeEL.makePromise(of: Void.self)

            @Sendable func writeLoop(_ writer: HTTPClient.Body.StreamWriter, index: Int) {
                // always invoke from the wrong el to test thread safety
                writeEL.preconditionInEventLoop()

                if index >= 30 {
                    return finalPromise.succeed(())
                }

                let sent = ByteBuffer(integer: index)
                writer.write(.byteBuffer(sent)).whenComplete { result in
                    switch result {
                    case .success:
                        writeEL.execute {
                            writeLoop(writer, index: index + 1)
                        }

                    case .failure(let error):
                        finalPromise.fail(error)
                    }
                }
            }

            writeEL.execute {
                writeLoop(writer, index: 0)
            }

            return finalPromise.futureResult
        }

        let headers = HTTPHeaders([("Connection", "close")])
        let request = try! HTTPClient.Request(url: "http://localhost:\(httpBin.port)", headers: headers, body: body)
        let future = httpClient.execute(request: request)
        XCTAssertNoThrow(try future.wait())
        XCTAssertNoThrow(try onClosePromise.futureResult.wait())
    }

    func testSynchronousHandshakeErrorReporting() throws {
        // This only affects cases where we use NIOSSL.
        guard !isTestingNIOTS() else { return }

        // We use a specially crafted client that has no cipher suites to offer. To do this we ask
        // only for cipher suites incompatible with our TLS version.
        var tlsConfig = TLSConfiguration.makeClientConfiguration()
        tlsConfig.minimumTLSVersion = .tlsv13
        tlsConfig.maximumTLSVersion = .tlsv12
        tlsConfig.certificateVerification = .none
        let localHTTPBin = HTTPBin(.http1_1(ssl: true))
        let localClient = HTTPClient(
            eventLoopGroupProvider: .shared(self.clientGroup),
            configuration: HTTPClient.Configuration(tlsConfiguration: tlsConfig)
        )
        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            XCTAssertNoThrow(try localHTTPBin.shutdown())
        }

        XCTAssertThrowsError(try localClient.get(url: "https://localhost:\(localHTTPBin.port)/").wait()) { error in
            guard let clientError = error as? NIOSSLError, case NIOSSLError.handshakeFailed = clientError else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
    }

    func testFileDownloadChunked() throws {
        var request = try Request(url: self.defaultHTTPBinURLPrefix + "chunked")
        request.headers.add(name: "Accept", value: "text/event-stream")

        let response =
            try TemporaryFileHelpers.withTemporaryFilePath { path -> FileDownloadDelegate.Response in
                let delegate = try FileDownloadDelegate(path: path)

                let response = try self.defaultClient.execute(
                    request: request,
                    delegate: delegate
                )
                .wait()

                try XCTAssertEqual(50, TemporaryFileHelpers.fileSize(path: path))

                return response
            }

        XCTAssertEqual(.ok, response.head.status)
        XCTAssertEqual("chunked", response.head.headers.first(name: "transfer-encoding"))
        XCTAssertFalse(response.head.headers.contains(name: "content-length"))

        XCTAssertEqual(nil, response.totalBytes)
        XCTAssertEqual(50, response.receivedBytes)
    }

    func testCloseWhileBackpressureIsExertedIsFine() throws {
        let request = try Request(url: self.defaultHTTPBinURLPrefix + "close-on-response")
        let delegate = DelayOnHeadDelegate(eventLoop: self.clientGroup.next()) { _, promise in
            promise.futureResult.eventLoop.scheduleTask(in: .milliseconds(50)) {
                promise.succeed(())
            }
        }

        let resultFuture = self.defaultClient.execute(request: request, delegate: delegate)

        // The full response must be correctly delivered.
        var data = try resultFuture.wait()
        guard let info = try data.readJSONDecodable(RequestInfo.self, length: data.readableBytes) else {
            XCTFail("Could not parse response")
            return
        }
        XCTAssertEqual(info.data, "some body content")
    }

    func testErrorAfterCloseWhileBackpressureExerted() throws {
        enum ExpectedError: Error {
            case expected
        }

        let request = try Request(url: self.defaultHTTPBinURLPrefix + "close-on-response")
        let delegate = DelayOnHeadDelegate(eventLoop: self.clientGroup.next()) { _, backpressurePromise in
            backpressurePromise.fail(ExpectedError.expected)
        }

        let resultFuture = self.defaultClient.execute(request: request, delegate: delegate)

        // The task must be failed.
        XCTAssertThrowsError(try resultFuture.wait()) { error in
            XCTAssertEqual(error as? ExpectedError, .expected)
        }
    }

    func testRequestSpecificTLS() throws {
        let configuration = HTTPClient.Configuration(
            tlsConfiguration: nil,
            timeout: .init(),
            decompression: .disabled
        )
        let localHTTPBin = HTTPBin(.http1_1(ssl: true))
        let localClient = HTTPClient(
            eventLoopGroupProvider: .shared(self.clientGroup),
            configuration: configuration
        )
        let decoder = JSONDecoder()

        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            XCTAssertNoThrow(try localHTTPBin.shutdown())
        }

        // First two requests use identical TLS configurations.
        var tlsConfig = TLSConfiguration.makeClientConfiguration()
        tlsConfig.certificateVerification = .none
        let firstRequest = try HTTPClient.Request(
            url: "https://localhost:\(localHTTPBin.port)/get",
            method: .GET,
            tlsConfiguration: tlsConfig
        )
        let firstResponse = try localClient.execute(request: firstRequest).wait()
        guard let firstBody = firstResponse.body else {
            XCTFail("No request body found")
            return
        }
        let firstConnectionNumber = try decoder.decode(RequestInfo.self, from: firstBody).connectionNumber

        let secondRequest = try HTTPClient.Request(
            url: "https://localhost:\(localHTTPBin.port)/get",
            method: .GET,
            tlsConfiguration: tlsConfig
        )
        let secondResponse = try localClient.execute(request: secondRequest).wait()
        guard let secondBody = secondResponse.body else {
            XCTFail("No request body found")
            return
        }
        let secondConnectionNumber = try decoder.decode(RequestInfo.self, from: secondBody).connectionNumber

        // Uses a differrent TLS config.
        var tlsConfig2 = TLSConfiguration.makeClientConfiguration()
        tlsConfig2.certificateVerification = .none
        tlsConfig2.maximumTLSVersion = .tlsv1
        let thirdRequest = try HTTPClient.Request(
            url: "https://localhost:\(localHTTPBin.port)/get",
            method: .GET,
            tlsConfiguration: tlsConfig2
        )
        let thirdResponse = try localClient.execute(request: thirdRequest).wait()
        guard let thirdBody = thirdResponse.body else {
            XCTFail("No request body found")
            return
        }
        let thirdConnectionNumber = try decoder.decode(RequestInfo.self, from: thirdBody).connectionNumber

        XCTAssertEqual(firstResponse.status, .ok)
        XCTAssertEqual(secondResponse.status, .ok)
        XCTAssertEqual(thirdResponse.status, .ok)
        XCTAssertEqual(
            firstConnectionNumber,
            secondConnectionNumber,
            "Identical TLS configurations did not use the same connection"
        )
        XCTAssertNotEqual(
            thirdConnectionNumber,
            firstConnectionNumber,
            "Different TLS configurations did not use different connections."
        )
    }

    func testRequestWithHeaderTransferEncodingIdentityDoesNotFail() {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }

        let client = HTTPClient(eventLoopGroupProvider: .shared(group))
        defer { XCTAssertNoThrow(try client.syncShutdown()) }

        let httpBin = HTTPBin()
        defer { XCTAssertNoThrow(try httpBin.shutdown()) }

        guard var request = try? Request(url: "http://127.0.0.1:\(httpBin.port)/get") else {
            return XCTFail("Expected to have a request here.")
        }
        request.headers.add(name: "X-Test-Header", value: "X-Test-Value")
        request.headers.add(name: "Transfer-Encoding", value: "identity")
        request.body = .string("1234")

        XCTAssertNoThrow(try client.execute(request: request).wait())
    }

    func testMassiveDownload() {
        var response: HTTPClient.Response?
        XCTAssertNoThrow(
            response = try self.defaultClient.get(url: "\(self.defaultHTTPBinURLPrefix)mega-chunked").wait()
        )

        XCTAssertEqual(.ok, response?.status)
        XCTAssertEqual(response?.version, .http1_1)
        XCTAssertEqual(response?.body?.readableBytes, 10_000)
    }

    func testShutdownWithFutures() {
        let httpClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup))
        XCTAssertNoThrow(try httpClient.shutdown().wait())
    }

    func testMassiveHeaderHTTP1() throws {
        var request = try HTTPClient.Request(url: defaultHTTPBin.baseURL, method: .POST)
        // add ~64 KB header
        let headerValue = String(repeating: "0", count: 1024)
        for headerID in 0..<64 {
            request.headers.replaceOrAdd(name: "larg-header-\(headerID)", value: headerValue)
        }

        // non empty body is important to trigger this bug as we otherwise finish the request in a single flush
        request.body = .byteBuffer(ByteBuffer(bytes: [0]))

        XCTAssertNoThrow(try defaultClient.execute(request: request).wait())
    }

    func testMassiveHeaderHTTP2() throws {
        let bin = HTTPBin(
            .http2(settings: [
                .init(parameter: .maxConcurrentStreams, value: 100),
                .init(parameter: .maxHeaderListSize, value: 1024 * 256),
                .init(parameter: .maxFrameSize, value: 1024 * 256),
            ])
        )
        defer { XCTAssertNoThrow(try bin.shutdown()) }

        let client = HTTPClient(
            eventLoopGroupProvider: .shared(clientGroup),
            configuration: .init(certificateVerification: .none)
        )

        defer { XCTAssertNoThrow(try client.syncShutdown()) }

        var request = try HTTPClient.Request(url: bin.baseURL, method: .POST)
        // add ~200 KB header
        let headerValue = String(repeating: "0", count: 1024)
        for headerID in 0..<200 {
            request.headers.replaceOrAdd(name: "larg-header-\(headerID)", value: headerValue)
        }

        // non empty body is important to trigger this bug as we otherwise finish the request in a single flush
        request.body = .byteBuffer(ByteBuffer(bytes: [0]))

        XCTAssertNoThrow(try client.execute(request: request).wait())
    }

    func testCancelingRequestAfterRedirect() throws {
        let request = try Request(
            url: self.defaultHTTPBinURLPrefix + "redirect/target",
            method: .GET,
            headers: ["X-Target-Redirect-URL": self.defaultHTTPBinURLPrefix + "wait"],
            body: nil
        )

        final class CancelAfterRedirect: HTTPClientResponseDelegate, Sendable {
            init() {}
            func didFinishRequest(task: AsyncHTTPClient.HTTPClient.Task<Void>) throws {}
        }

        let task = defaultClient.execute(
            request: request,
            delegate: CancelAfterRedirect(),
            deadline: .now() + .seconds(1)
        )

        // there is currently no HTTPClientResponseDelegate method to ensure the redirect occurs before we cancel, so we just sleep for 500ms
        Thread.sleep(forTimeInterval: 0.5)

        task.cancel()

        XCTAssertThrowsError(try task.wait()) { error in
            guard case let error = error as? HTTPClientError, error == .cancelled else {
                return XCTFail("Should fail with cancelled")
            }
        }
    }

    func testFailingRequestAfterRedirect() throws {
        let request = try Request(
            url: self.defaultHTTPBinURLPrefix + "redirect/target",
            method: .GET,
            headers: ["X-Target-Redirect-URL": self.defaultHTTPBinURLPrefix + "wait"],
            body: nil
        )

        final class FailAfterRedirect: HTTPClientResponseDelegate, Sendable {
            init() {}
            func didFinishRequest(task: AsyncHTTPClient.HTTPClient.Task<Void>) throws {}
        }

        let task = defaultClient.execute(
            request: request,
            delegate: FailAfterRedirect(),
            deadline: .now() + .seconds(1)
        )

        // there is currently no HTTPClientResponseDelegate method to ensure the redirect occurs before we fail, so we just sleep for 500ms
        Thread.sleep(forTimeInterval: 0.5)

        struct TestError: Error {}

        task.fail(reason: TestError())

        XCTAssertThrowsError(try task.wait()) { error in
            guard error is TestError else {
                return XCTFail("Should fail with TestError")
            }
        }
    }

    func testCancelingHTTP1RequestAfterHeaderSend() throws {
        var request = try HTTPClient.Request(url: self.defaultHTTPBin.baseURL + "/wait", method: .POST)
        // non-empty body is important
        request.body = .byteBuffer(ByteBuffer([1]))

        final class CancelAfterHeadSend: HTTPClientResponseDelegate, Sendable {
            init() {}
            func didFinishRequest(task: AsyncHTTPClient.HTTPClient.Task<Void>) throws {}
            func didSendRequestHead(task: HTTPClient.Task<Void>, _ head: HTTPRequestHead) {
                task.cancel()
            }
        }
        XCTAssertThrowsError(try defaultClient.execute(request: request, delegate: CancelAfterHeadSend()).wait())
    }

    func testCancelingHTTP2RequestAfterHeaderSend() throws {
        let bin = HTTPBin(.http2())
        defer { XCTAssertNoThrow(try bin.shutdown()) }
        var request = try HTTPClient.Request(url: bin.baseURL + "/wait", method: .POST)
        // non-empty body is important
        request.body = .byteBuffer(ByteBuffer([1]))

        final class CancelAfterHeadSend: HTTPClientResponseDelegate, Sendable {
            init() {}
            func didFinishRequest(task: AsyncHTTPClient.HTTPClient.Task<Void>) throws {}
            func didSendRequestHead(task: HTTPClient.Task<Void>, _ head: HTTPRequestHead) {
                task.cancel()
            }
        }
        XCTAssertThrowsError(try defaultClient.execute(request: request, delegate: CancelAfterHeadSend()).wait())
    }

    private func testMaxConnectionReuses(mode: HTTPBin<HTTPBinHandler>.Mode, maximumUses: Int, requests: Int) throws {
        let bin = HTTPBin(mode)
        defer { XCTAssertNoThrow(try bin.shutdown()) }

        var configuration = HTTPClient.Configuration(certificateVerification: .none)
        // Limit each connection to two uses before discarding them. The test will verify that the
        // connection number indicated by the server increments every two requests.
        configuration.maximumUsesPerConnection = maximumUses

        let client = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup), configuration: configuration)
        defer { XCTAssertNoThrow(try client.syncShutdown()) }

        let request = try HTTPClient.Request(url: bin.baseURL + "stats")
        let decoder = JSONDecoder()

        // Do two requests per batch. Both should report the same connection number.
        for requestNumber in stride(from: 0, to: requests, by: maximumUses) {
            var responses = [RequestInfo]()

            for _ in 0..<maximumUses {
                let response = try client.execute(request: request).wait()
                let body = try XCTUnwrap(response.body)
                let info = try decoder.decode(RequestInfo.self, from: body)
                responses.append(info)
            }

            for response in responses {
                // Connection numbers should be the same as the batch size is the same as the per connection limit.
                XCTAssertEqual(responses[0].connectionNumber, response.connectionNumber)
            }

            XCTAssertEqual(responses[0].connectionNumber, requestNumber / maximumUses)
        }
    }

    func testMaxConnectionReusesHTTP1() throws {
        try self.testMaxConnectionReuses(mode: .http1_1(), maximumUses: 5, requests: 100)
    }

    func testMaxConnectionReusesHTTP2() throws {
        try self.testMaxConnectionReuses(mode: .http2(), maximumUses: 5, requests: 100)
    }

    func testMaxConnectionReusesExceedsMaxConcurrentStreamsForHTTP2() throws {
        try self.testMaxConnectionReuses(
            mode: .http2(settings: [.init(parameter: .maxConcurrentStreams, value: 100)]),
            maximumUses: 150,
            requests: 300
        )
    }

    func testClientWithDefaultSingletonELG() throws {
        let client = HTTPClient()
        defer {
            XCTAssertNoThrow(try client.shutdown().wait())
        }
        let response = try client.get(url: self.defaultHTTPBinURLPrefix + "get").wait()
        XCTAssertEqual(.ok, response.status)
    }

    func testClientWithELGInit() throws {
        let client = HTTPClient(eventLoopGroup: MultiThreadedEventLoopGroup.singleton)
        defer {
            XCTAssertNoThrow(try client.shutdown().wait())
        }
        let response = try client.get(url: self.defaultHTTPBinURLPrefix + "get").wait()
        XCTAssertEqual(.ok, response.status)
    }

    func testClientWithMultipath() throws {
        do {
            var conf = HTTPClient.Configuration()
            conf.enableMultipath = true
            let client = HTTPClient(configuration: conf)
            defer {
                XCTAssertNoThrow(try client.shutdown().wait())
            }
            let response = try client.get(url: self.defaultHTTPBinURLPrefix + "get").wait()
            XCTAssertEqual(.ok, response.status)
        } catch let error as IOError
            where error.errnoCode == EINVAL || error.errnoCode == EPROTONOSUPPORT || error.errnoCode == ENOPROTOOPT
        {
            // some old Linux kernels don't support MPTCP, skip this test in this case
            // see https://www.mptcp.dev/implementation.html for details about each type
            // of error
            throw XCTSkip()
        }
    }

    func testSingletonClientWorks() throws {
        let response = try HTTPClient.shared.get(url: self.defaultHTTPBinURLPrefix + "get").wait()
        XCTAssertEqual(.ok, response.status)
    }

    func testSingletonClientCannotBeShutDown() {
        XCTAssertThrowsError(try HTTPClient.shared.shutdown().wait()) { error in
            XCTAssertEqual(.shutdownUnsupported, error as? HTTPClientError)
        }
    }

    @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
    func testAsyncExecuteWithCustomTLS() async throws {
        let httpsBin = HTTPBin(.http1_1(ssl: true))
        defer {
            XCTAssertNoThrow(try httpsBin.shutdown())
        }

        // A client with default TLS settings, i.e. it won't accept `httpsBin`'s fake self-signed cert
        let client = HTTPClient(eventLoopGroup: MultiThreadedEventLoopGroup.singleton)
        defer {
            XCTAssertNoThrow(try client.shutdown().wait())
        }

        var request = HTTPClientRequest(url: "https://localhost:\(httpsBin.port)/get")

        // For now, let's allow bad TLS certs
        request.tlsConfiguration = TLSConfiguration.clientDefault
        // ! is safe, assigned above
        request.tlsConfiguration!.certificateVerification = .none

        let response1 = try await client.execute(request, timeout: .hours(99))  // 99h ~= infinity
        XCTAssertEqual(.ok, response1.status)

        // For the second request, we reset the TLS config
        request.tlsConfiguration = nil
        do {
            let response2 = try await client.execute(request, timeout: .hours(99))  // 99h ~= infinity
            XCTFail("shouldn't succeed, self-signed cert: \(response2)")
        } catch {
            switch error as? NIOSSLError {
            case .some(.handshakeFailed(_)):
                ()  // ok
            default:
                XCTFail("unexpected error: \(error)")
            }
        }

        // And finally we allow it again.
        request.tlsConfiguration = TLSConfiguration.clientDefault
        // ! is safe, assigned above
        request.tlsConfiguration!.certificateVerification = .none

        let response3 = try await client.execute(request, timeout: .hours(99))  // 99h ~= infinity
        XCTAssertEqual(.ok, response3.status)
    }

    @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
    func testRequestBasicAuth() async throws {
        var request = try HTTPClient.Request(url: self.defaultHTTPBinURLPrefix)
        request.setBasicAuth(username: "foo", password: "bar")
        XCTAssertEqual(request.headers.first(name: "Authorization"), "Basic Zm9vOmJhcg==")
    }

    func runBaseTestForHTTP1ConnectionDebugInitializer(ssl: Bool) {
        let connectionDebugInitializerUtil = CountingDebugInitializerUtil()

        // Initializing even with just `http1_1ConnectionDebugInitializer` (rather than manually
        // modifying `config`) to ensure that the matching `init` actually wires up this argument
        // with the respective property. This is necessary as these parameters are defaulted and can
        // be easy to miss.
        var config = HTTPClient.Configuration(
            http1_1ConnectionDebugInitializer: { channel in
                connectionDebugInitializerUtil.initialize(channel: channel)
            }
        )
        config.httpVersion = .http1Only

        if ssl {
            config.tlsConfiguration = .clientDefault
            config.tlsConfiguration?.certificateVerification = .none
        }

        let higherConnectTimeout = CountingDebugInitializerUtil.duration + .milliseconds(100)
        var configWithHigherTimeout = config
        configWithHigherTimeout.timeout = .init(connect: higherConnectTimeout)

        let clientWithHigherTimeout = HTTPClient(
            eventLoopGroupProvider: .singleton,
            configuration: configWithHigherTimeout,
            backgroundActivityLogger: Logger(
                label: "HTTPClient",
                factory: StreamLogHandler.standardOutput(label:)
            )
        )
        defer { XCTAssertNoThrow(try clientWithHigherTimeout.syncShutdown()) }

        let bin = HTTPBin(.http1_1(ssl: ssl, compress: false))
        defer { XCTAssertNoThrow(try bin.shutdown()) }

        let scheme = ssl ? "https" : "http"

        for _ in 0..<3 {
            XCTAssertNoThrow(
                try clientWithHigherTimeout.get(url: "\(scheme)://localhost:\(bin.port)/get").wait()
            )
        }

        // Even though multiple requests were made, the connection debug initializer must be called
        // only once.
        XCTAssertEqual(connectionDebugInitializerUtil.executionCount, 1)

        let lowerConnectTimeout = CountingDebugInitializerUtil.duration - .milliseconds(100)
        var configWithLowerTimeout = config
        configWithLowerTimeout.timeout = .init(connect: lowerConnectTimeout)

        let clientWithLowerTimeout = HTTPClient(
            eventLoopGroupProvider: .singleton,
            configuration: configWithLowerTimeout,
            backgroundActivityLogger: Logger(
                label: "HTTPClient",
                factory: StreamLogHandler.standardOutput(label:)
            )
        )
        defer { XCTAssertNoThrow(try clientWithLowerTimeout.syncShutdown()) }

        XCTAssertThrowsError(
            try clientWithLowerTimeout.get(url: "\(scheme)://localhost:\(bin.port)/get").wait()
        ) {
            XCTAssertEqual($0 as? HTTPClientError, .connectTimeout)
        }
    }

    func testHTTP1PlainTextConnectionDebugInitializer() {
        runBaseTestForHTTP1ConnectionDebugInitializer(ssl: false)
    }

    func testHTTP1EncryptedConnectionDebugInitializer() {
        runBaseTestForHTTP1ConnectionDebugInitializer(ssl: true)
    }

    func testHTTP2ConnectionAndStreamChannelDebugInitializers() {
        let connectionDebugInitializerUtil = CountingDebugInitializerUtil()
        let streamChannelDebugInitializerUtil = CountingDebugInitializerUtil()

        // Initializing even with just `http2ConnectionDebugInitializer` and
        // `http2StreamChannelDebugInitializer` (rather than manually modifying `config`) to ensure
        // that the matching `init` actually wires up these arguments with the respective
        // properties. This is necessary as these parameters are defaulted and can be easy to miss.
        var config = HTTPClient.Configuration(
            http2ConnectionDebugInitializer: { channel in
                connectionDebugInitializerUtil.initialize(channel: channel)
            },
            http2StreamChannelDebugInitializer: { channel in
                streamChannelDebugInitializerUtil.initialize(channel: channel)
            }
        )
        config.tlsConfiguration = .clientDefault
        config.tlsConfiguration?.certificateVerification = .none
        config.httpVersion = .automatic

        let higherConnectTimeout = CountingDebugInitializerUtil.duration + .milliseconds(100)
        var configWithHigherTimeout = config
        configWithHigherTimeout.timeout = .init(connect: higherConnectTimeout)

        let clientWithHigherTimeout = HTTPClient(
            eventLoopGroupProvider: .singleton,
            configuration: configWithHigherTimeout,
            backgroundActivityLogger: Logger(
                label: "HTTPClient",
                factory: StreamLogHandler.standardOutput(label:)
            )
        )
        defer { XCTAssertNoThrow(try clientWithHigherTimeout.syncShutdown()) }

        let bin = HTTPBin(.http2(compress: false))
        defer { XCTAssertNoThrow(try bin.shutdown()) }

        let numberOfRequests = 3

        for _ in 0..<numberOfRequests {
            XCTAssertNoThrow(
                try clientWithHigherTimeout.get(url: "https://localhost:\(bin.port)/get").wait()
            )
        }

        // Even though multiple requests were made, the connection debug initializer must be called
        // only once.
        XCTAssertEqual(connectionDebugInitializerUtil.executionCount, 1)

        // The stream channel debug initializer must be called only as much as the number of
        // requests made.
        XCTAssertEqual(streamChannelDebugInitializerUtil.executionCount, numberOfRequests)

        let lowerConnectTimeout = CountingDebugInitializerUtil.duration - .milliseconds(100)
        var configWithLowerTimeout = config
        configWithLowerTimeout.timeout = .init(connect: lowerConnectTimeout)

        let clientWithLowerTimeout = HTTPClient(
            eventLoopGroupProvider: .singleton,
            configuration: configWithLowerTimeout,
            backgroundActivityLogger: Logger(
                label: "HTTPClient",
                factory: StreamLogHandler.standardOutput(label:)
            )
        )
        defer { XCTAssertNoThrow(try clientWithLowerTimeout.syncShutdown()) }

        XCTAssertThrowsError(
            try clientWithLowerTimeout.get(url: "https://localhost:\(bin.port)/get").wait()
        ) {
            XCTAssertEqual($0 as? HTTPClientError, .connectTimeout)
        }
    }
}

final class CountingDebugInitializerUtil: Sendable {
    private let _executionCount = NIOLockedValueBox<Int>(0)
    var executionCount: Int { self._executionCount.withLockedValue { $0 } }

    /// The minimum time to spend running the debug initializer.
    static let duration: TimeAmount = .milliseconds(300)

    /// The actual debug initializer.
    func initialize(channel: Channel) -> EventLoopFuture<Void> {
        self._executionCount.withLockedValue { $0 += 1 }

        let someScheduledTask = channel.eventLoop.scheduleTask(in: Self.duration) {
            channel.eventLoop.makeSucceededVoidFuture()
        }

        return someScheduledTask.futureResult.flatMap { $0 }
    }
}
