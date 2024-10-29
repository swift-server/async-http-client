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

final class StressGetHttpsTests: XCTestCaseHTTPClientTestsBaseClass {
    func testStressGetHttps() throws {
        let localHTTPBin = HTTPBin(.http1_1(ssl: true))
        let localClient = HTTPClient(
            eventLoopGroupProvider: .shared(self.clientGroup),
            configuration: HTTPClient.Configuration(certificateVerification: .none)
        )
        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            XCTAssertNoThrow(try localHTTPBin.shutdown())
        }

        let eventLoop = localClient.eventLoopGroup.next()
        let requestCount = 200
        var futureResults = [EventLoopFuture<HTTPClient.Response>]()
        for _ in 1...requestCount {
            let req = try HTTPClient.Request(
                url: "https://localhost:\(localHTTPBin.port)/get",
                method: .GET,
                headers: ["X-internal-delay": "100"]
            )
            futureResults.append(localClient.execute(request: req))
        }
        XCTAssertNoThrow(try EventLoopFuture<HTTPClient.Response>.andAllSucceed(futureResults, on: eventLoop).wait())
    }
}
