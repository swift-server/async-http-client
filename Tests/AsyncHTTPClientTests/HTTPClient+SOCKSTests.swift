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

/* NOT @testable */ import AsyncHTTPClient // Tests that need @testable go into HTTPClientInternalTests.swift
import Logging
import NIOCore
import NIOPosix
import NIOSOCKS
import XCTest

class HTTPClientSOCKSTests: XCTestCase {
    typealias Request = HTTPClient.Request

    var clientGroup: EventLoopGroup!
    var serverGroup: EventLoopGroup!
    var defaultHTTPBin: HTTPBin<HTTPBinHandler>!
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

    func testProxySOCKS() throws {
        let socksBin = try MockSOCKSServer(expectedURL: "/socks/test", expectedResponse: "it works!")
        let localClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup),
                                     configuration: .init(proxy: .socksServer(host: "localhost", port: socksBin.port)))

        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            XCTAssertNoThrow(try socksBin.shutdown())
        }

        var response: HTTPClient.Response?
        XCTAssertNoThrow(response = try localClient.get(url: "http://localhost/socks/test").wait())
        XCTAssertEqual(.ok, response?.status)
        XCTAssertEqual(ByteBuffer(string: "it works!"), response?.body)
    }

    func testProxySOCKSBogusAddress() throws {
        let localClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup),
                                     configuration: .init(proxy: .socksServer(host: "127.0..")))

        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
        }
        XCTAssertThrowsError(try localClient.get(url: "http://localhost/socks/test").wait())
    }

    // there is no socks server, so we should fail
    func testProxySOCKSFailureNoServer() throws {
        let localHTTPBin = HTTPBin()
        let localClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup),
                                     configuration: .init(proxy: .socksServer(host: "localhost", port: localHTTPBin.port)))
        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            XCTAssertNoThrow(try localHTTPBin.shutdown())
        }
        XCTAssertThrowsError(try localClient.get(url: "http://localhost/socks/test").wait())
    }

    // speak to a server that doesn't speak SOCKS
    func testProxySOCKSFailureInvalidServer() throws {
        let localClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup),
                                     configuration: .init(proxy: .socksServer(host: "localhost")))
        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
        }
        XCTAssertThrowsError(try localClient.get(url: "http://localhost/socks/test").wait())
    }

    // test a handshake failure with a misbehaving server
    func testProxySOCKSMisbehavingServer() throws {
        let socksBin = try MockSOCKSServer(expectedURL: "/socks/test", expectedResponse: "it works!", misbehave: true)
        let localClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup),
                                     configuration: .init(proxy: .socksServer(host: "localhost", port: socksBin.port)))

        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            XCTAssertNoThrow(try socksBin.shutdown())
        }

        // the server will send a bogus message in response to the clients greeting
        // this will be first picked up as an invalid protocol
        XCTAssertThrowsError(try localClient.get(url: "http://localhost/socks/test").wait()) { e in
            XCTAssertTrue(e is SOCKSError.InvalidProtocolVersion)
        }
    }
}
