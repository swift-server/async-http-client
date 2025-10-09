//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2025 Apple Inc. and the AsyncHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Atomics
import InMemoryTracing
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import NIOFoundationCompat
import NIOHTTP1
import NIOHTTPCompression
import NIOPosix
import NIOSSL
import NIOTestUtils
import NIOTransportServices
import Tracing
import XCTest

@testable @_spi(Tracing) import AsyncHTTPClient

#if canImport(Network)
import Network
#endif

private func makeTracedHTTPClient(tracer: InMemoryTracer) -> HTTPClient {
    var config = HTTPClient.Configuration()
    config.httpVersion = .automatic
    config.tracing.tracer = tracer
    return HTTPClient(
        eventLoopGroupProvider: .singleton,
        configuration: config
    )
}

final class HTTPClientTracingInternalTests: XCTestCaseHTTPClientTestsBaseClass {

    var tracer: InMemoryTracer!
    var client: HTTPClient!

    override func setUp() {
        super.setUp()
        self.tracer = InMemoryTracer()
        self.client = makeTracedHTTPClient(tracer: tracer)
    }

    override func tearDown() {
        if let client = self.client {
            XCTAssertNoThrow(try client.syncShutdown())
            self.client = nil
        }
        tracer = nil
    }

    func testTrace_preparedHeaders_include_fromSpan() async throws {
        let url = self.defaultHTTPBinURLPrefix + "404-does-not-exist"
        let request = HTTPClientRequest(url: url)

        try tracer.withSpan("operation") { span in
            let prepared = try HTTPClientRequest.Prepared(request, tracing: self.client.tracing)
            XCTAssertTrue(prepared.head.headers.count > 2)
            XCTAssertTrue(prepared.head.headers.contains(name: "in-memory-trace-id"))
            XCTAssertTrue(prepared.head.headers.contains(name: "in-memory-span-id"))
        }
    }
}
