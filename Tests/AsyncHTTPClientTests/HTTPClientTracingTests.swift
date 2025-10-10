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

@_spi(Tracing) import AsyncHTTPClient  // NOT @testable - tests that need @testable go into HTTPClientTracingInternalTests.swift
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

final class HTTPClientTracingTests: XCTestCaseHTTPClientTestsBaseClass {

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

    func testTrace_get_sync() throws {
        let url = self.defaultHTTPBinURLPrefix + "echo-method"
        let _ = try client.get(url: url).wait()

        guard tracer.activeSpans.isEmpty else {
            XCTFail("Still active spans which were not finished (\(tracer.activeSpans.count))! \(tracer.activeSpans)")
            return
        }
        guard let span = tracer.finishedSpans.first else {
            XCTFail("No span was recorded!")
            return
        }

        XCTAssertEqual(span.operationName, "GET")
    }

    func testTrace_post_sync() throws {
        let url = self.defaultHTTPBinURLPrefix + "echo-method"
        let _ = try client.post(url: url).wait()

        guard tracer.activeSpans.isEmpty else {
            XCTFail("Still active spans which were not finished (\(tracer.activeSpans.count))! \(tracer.activeSpans)")
            return
        }
        guard let span = tracer.finishedSpans.first else {
            XCTFail("No span was recorded!")
            return
        }

        XCTAssertEqual(span.operationName, "POST")
    }

    func testTrace_post_sync_404_error() throws {
        let url = self.defaultHTTPBinURLPrefix + "404-not-existent"
        let _ = try client.post(url: url).wait()

        guard tracer.activeSpans.isEmpty else {
            XCTFail("Still active spans which were not finished (\(tracer.activeSpans.count))! \(tracer.activeSpans)")
            return
        }
        guard let span = tracer.finishedSpans.first else {
            XCTFail("No span was recorded!")
            return
        }

        XCTAssertEqual(span.operationName, "POST")
        XCTAssertTrue(span.errors.isEmpty, "Should have recorded error")
        XCTAssertEqual(span.attributes.get(client.tracing.attributeKeys.responseStatusCode), 404)
    }

    func testTrace_execute_async() async throws {
        let url = self.defaultHTTPBinURLPrefix + "echo-method"
        let request = HTTPClientRequest(url: url)
        let _ = try await client.execute(request, deadline: .distantFuture)

        guard tracer.activeSpans.isEmpty else {
            XCTFail("Still active spans which were not finished (\(tracer.activeSpans.count))! \(tracer.activeSpans)")
            return
        }
        guard let span = tracer.finishedSpans.first else {
            XCTFail("No span was recorded!")
            return
        }

        XCTAssertEqual(span.operationName, "GET")
    }

    func testTrace_execute_async_404_error() async throws {
        let url = self.defaultHTTPBinURLPrefix + "404-does-not-exist"
        let request = HTTPClientRequest(url: url)
        let _ = try await client.execute(request, deadline: .distantFuture)

        guard tracer.activeSpans.isEmpty else {
            XCTFail("Still active spans which were not finished (\(tracer.activeSpans.count))! \(tracer.activeSpans)")
            return
        }
        guard let span = tracer.finishedSpans.first else {
            XCTFail("No span was recorded!")
            return
        }

        XCTAssertEqual(span.operationName, "GET")
        XCTAssertTrue(span.errors.isEmpty, "Should have recorded error")
        XCTAssertEqual(span.attributes.get(client.tracing.attributeKeys.responseStatusCode), 404)
    }
}
