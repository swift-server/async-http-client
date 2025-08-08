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

final class ConnectionPoolSizeConfigValueIsRespectedTests: XCTestCaseHTTPClientTestsBaseClass {
    func testConnectionPoolSizeConfigValueIsRespected() {
        let numberOfRequestsPerThread = 1000
        let numberOfParallelWorkers = 16
        let poolSize = 12

        let httpBin = HTTPBin()
        defer { XCTAssertNoThrow(try httpBin.shutdown()) }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 4)
        defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }

        let configuration = HTTPClient.Configuration(
            connectionPool: .init(
                idleTimeout: .seconds(30),
                concurrentHTTP1ConnectionsPerHostSoftLimit: poolSize
            )
        )
        let client = HTTPClient(eventLoopGroupProvider: .shared(group), configuration: configuration)
        defer { XCTAssertNoThrow(try client.syncShutdown()) }

        let g = DispatchGroup()
        for workerID in 0..<numberOfParallelWorkers {
            DispatchQueue(label: "\(#fileID):\(#line):worker-\(workerID)").async(group: g) {
                func makeRequest() {
                    let url = "http://127.0.0.1:\(httpBin.port)"
                    XCTAssertNoThrow(try client.get(url: url).wait())
                }
                for _ in 0..<numberOfRequestsPerThread {
                    makeRequest()
                }
            }
        }
        let timeout = DispatchTime.now() + .seconds(60)
        switch g.wait(timeout: timeout) {
        case .success:
            break
        case .timedOut:
            XCTFail("Timed out")
        }

        XCTAssertEqual(httpBin.createdConnections, poolSize)
    }
}
