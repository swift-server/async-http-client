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

final class RacePoolIdleConnectionsAndGetTests: XCTestCaseHTTPClientTestsBaseClass {
    func testRacePoolIdleConnectionsAndGet() {
        let localClient = HTTPClient(
            eventLoopGroupProvider: .shared(self.clientGroup),
            configuration: .init(connectionPool: .init(idleTimeout: .milliseconds(10)))
        )
        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
        }
        for _ in 1...200 {
            XCTAssertNoThrow(try localClient.get(url: self.defaultHTTPBinURLPrefix + "get").wait())
            Thread.sleep(forTimeInterval: 0.01 + .random(in: -0.01...0.01))
        }
    }
}
