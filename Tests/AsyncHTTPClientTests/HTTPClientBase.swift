//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2022 Apple Inc. and the AsyncHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import AsyncHTTPClient
import Atomics
import InMemoryLogging
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOFoundationCompat
import NIOHTTP1
import NIOHTTPCompression
import NIOPosix
import NIOSSL
import NIOTestUtils
import NIOTransportServices
import XCTest

#if canImport(Network)
import Network
#endif

class XCTestCaseHTTPClientTestsBaseClass: XCTestCase {
    typealias Request = HTTPClient.Request

    var clientGroup: EventLoopGroup!
    var serverGroup: EventLoopGroup!
    var defaultHTTPBin: HTTPBin<HTTPBinHandler>!
    var defaultClient: HTTPClient!
    var backgroundLogStore: InMemoryLogHandler!

    var defaultHTTPBinURLPrefix: String {
        self.defaultHTTPBin.baseURL
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
        let (backgroundLogStore, backgroundLogger) = InMemoryLogHandler.makeLogger(logLevel: .trace)
        self.backgroundLogStore = backgroundLogStore

        self.defaultClient = HTTPClient(
            eventLoopGroupProvider: .shared(self.clientGroup),
            configuration: HTTPClient.Configuration().enableFastFailureModeForTesting(),
            backgroundActivityLogger: backgroundLogger
        )
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
}
