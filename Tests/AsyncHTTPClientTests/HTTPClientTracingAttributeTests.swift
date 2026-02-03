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
import OTelSemanticConventions
import Tracing
import XCTest

#if canImport(Network)
import Network
#endif

final class HTTPClientTracingAttributeTests: XCTestCaseHTTPClientTestsBaseClass {

    func testTraceAttributes_url() async throws {
        let tracer = InMemoryTracer()
        var config = HTTPClient.Configuration()
        config.httpVersion = .automatic
        config.tracing.tracer = tracer

        let client = HTTPClient(
            eventLoopGroupProvider: .singleton,
            configuration: config
        )

        let url = self.defaultHTTPBinURLPrefix + "echo-method?foo=bar&Signature=secretSignature"
        var request = HTTPClientRequest(url: url)

        request.headers.add(name: "Authorization", value: "Bearer secret")
        request.headers.add(name: "Password", value: "SuperSecretPassword")

        let _ = try await client.execute(request, deadline: .distantFuture)

        guard tracer.activeSpans.isEmpty else {
            XCTFail("Still active spans which were not finished (\(tracer.activeSpans.count))! \(tracer.activeSpans)")
            return
        }
        guard let span = tracer.finishedSpans.first else {
            XCTFail("No span was recorded!")
            return
        }

        XCTAssertEqual(span.attributes.get(OTelAttribute.url.path), "/echo-method")
        XCTAssertEqual(span.attributes.get(OTelAttribute.url.scheme), "http")
        XCTAssertEqual(span.attributes.get(OTelAttribute.url.query), "foo=bar&Signature=REDACTED")

        XCTAssertNoThrow(try client.syncShutdown()) 
    }

    func testTraceAttributes_server() async throws {
        let tracer = InMemoryTracer()
        var config = HTTPClient.Configuration()
        config.httpVersion = .automatic
        config.tracing.tracer = tracer

        let client = HTTPClient(
            eventLoopGroupProvider: .singleton,
            configuration: config
        )

        let url = self.defaultHTTPBinURLPrefix + "echo-method?foo=bar&Signature=secretSignature"
        var request = HTTPClientRequest(url: url)

        request.headers.add(name: "Authorization", value: "Bearer secret")
        request.headers.add(name: "Password", value: "SuperSecretPassword")

        let _ = try await client.execute(request, deadline: .distantFuture)

        guard tracer.activeSpans.isEmpty else {
            XCTFail("Still active spans which were not finished (\(tracer.activeSpans.count))! \(tracer.activeSpans)")
            return
        }
        guard let span = tracer.finishedSpans.first else {
            XCTFail("No span was recorded!")
            return
        }
        guard let defaultHTTPBinPort = self.defaultHTTPBin.socketAddress.port, let defaultHTTPBinAddress = self.defaultHTTPBin.socketAddress.ipAddress else {
            XCTFail("Default HTTPBin ip address or port is not set!")
            return
        }

        XCTAssertEqual(span.attributes.get(OTelAttribute.server.address), .string(defaultHTTPBinAddress.description))
        XCTAssertEqual(span.attributes.get(OTelAttribute.server.port), .int64(Int64(defaultHTTPBinPort)))

        XCTAssertNoThrow(try client.syncShutdown()) 
    }

    func testTraceAttributes_http() async throws {
        let tracer = InMemoryTracer()
        var config = HTTPClient.Configuration()

        // By default no headers are allowed to be traced
        config.tracing.allowedHeaders = ["Authorization"]
        config.httpVersion = .automatic
        config.tracing.tracer = tracer

        let client = HTTPClient(
            eventLoopGroupProvider: .singleton,
            configuration: config
        )

        let url = self.defaultHTTPBinURLPrefix + "echo-method?foo=bar&Signature=secretSignature"
        var request = HTTPClientRequest(url: url)

        request.headers.add(name: "Authorization", value: "Bearer secret")
        request.headers.add(name: "Password", value: "SuperSecretPassword")

        let _ = try await client.execute(request, deadline: .distantFuture)

        guard tracer.activeSpans.isEmpty else {
            XCTFail("Still active spans which were not finished (\(tracer.activeSpans.count))! \(tracer.activeSpans)")
            return
        }
        guard let span = tracer.finishedSpans.first else {
            XCTFail("No span was recorded!")
            return
        }

        XCTAssertEqual(span.attributes.get(OTelAttribute.http.request.method), "GET")
        XCTAssertEqual(span.attributes.get("\(OTelAttribute.http.request.header).authorization"), .stringArray(["Bearer secret"]))
        XCTAssertNil(span.attributes.get("\(OTelAttribute.http.request.header).password"))
        XCTAssertEqual(span.attributes.get(OTelAttribute.http.response.statusCode), 200)

        XCTAssertNoThrow(try client.syncShutdown()) 
    }

    func testTraceAttributes_pathRedaction() async throws {
        let tracer = InMemoryTracer()
        var config = HTTPClient.Configuration()
        config.httpVersion = .automatic
        config.tracing.sensitivePathComponents = ["nested-path"]
        config.tracing.tracer = tracer

        let client = HTTPClient(
            eventLoopGroupProvider: .singleton,
            configuration: config
        )

        let url = self.defaultHTTPBinURLPrefix + "echo-method/nested-path"
        var request = HTTPClientRequest(url: url)

        request.headers.add(name: "Authorization", value: "Bearer secret")
        request.headers.add(name: "Password", value: "SuperSecretPassword")

        let _ = try await client.execute(request, deadline: .distantFuture)

        guard tracer.activeSpans.isEmpty else {
            XCTFail("Still active spans which were not finished (\(tracer.activeSpans.count))! \(tracer.activeSpans)")
            return
        }
        guard let span = tracer.finishedSpans.first else {
            XCTFail("No span was recorded!")
            return
        }

        XCTAssertEqual(span.attributes.get(OTelAttribute.url.path), "/echo-method/REDACTED")

        XCTAssertNoThrow(try client.syncShutdown()) 
    }

    func testTraceAttributes_queryRedaction() async throws {
        let tracer = InMemoryTracer()
        var config = HTTPClient.Configuration()
        config.httpVersion = .automatic

        // Add foo to sensitive query components
        config.tracing.sensitiveQueryComponents.insert("foo")
        config.tracing.tracer = tracer

        let client = HTTPClient(
            eventLoopGroupProvider: .singleton,
            configuration: config
        )

        let url = self.defaultHTTPBinURLPrefix + "echo-method?foo=bar&Signature=secretSignature&bar=bar"
        var request = HTTPClientRequest(url: url)

        request.headers.add(name: "Authorization", value: "Bearer secret")
        request.headers.add(name: "Password", value: "SuperSecretPassword")

        let _ = try await client.execute(request, deadline: .distantFuture)

        guard tracer.activeSpans.isEmpty else {
            XCTFail("Still active spans which were not finished (\(tracer.activeSpans.count))! \(tracer.activeSpans)")
            return
        }
        guard let span = tracer.finishedSpans.first else {
            XCTFail("No span was recorded!")
            return
        }

        XCTAssertEqual(span.attributes.get(OTelAttribute.url.query), "foo=REDACTED&Signature=REDACTED&bar=bar")

        XCTAssertNoThrow(try client.syncShutdown()) 
    }

    func testTraceAttributes_httpHeadersDisallowedByDefault() async throws {
        let tracer = InMemoryTracer()
        var config = HTTPClient.Configuration()

        config.httpVersion = .automatic
        config.tracing.tracer = tracer

        let client = HTTPClient(
            eventLoopGroupProvider: .singleton,
            configuration: config
        )

        let url = self.defaultHTTPBinURLPrefix + "echo-method?foo=bar&Signature=secretSignature"
        var request = HTTPClientRequest(url: url)

        request.headers.add(name: "Authorization", value: "Bearer secret")
        request.headers.add(name: "Password", value: "SuperSecretPassword")

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

        XCTAssertNil(span.attributes.get("\(OTelAttribute.http.request.header).authorization"))
        XCTAssertNil(span.attributes.get("\(OTelAttribute.http.request.header).password"))

        XCTAssertNoThrow(try client.syncShutdown()) 
    }

    func testTraceAttributes_httpHeaders() async throws {
        let tracer = InMemoryTracer()
        var config = HTTPClient.Configuration()

        config.tracing.allowedHeaders = ["Authorization", "Password", "X-Method-Used"]

        config.httpVersion = .automatic
        config.tracing.tracer = tracer

        let client = HTTPClient(
            eventLoopGroupProvider: .singleton,
            configuration: config
        )

        let url = self.defaultHTTPBinURLPrefix + "echo-method?foo=bar&Signature=secretSignature"
        var request = HTTPClientRequest(url: url)

        request.headers.add(name: "Authorization", value: "Bearer secret")
        request.headers.add(name: "Password", value: "SuperSecretPassword")

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
        XCTAssertEqual(span.attributes.get("\(OTelAttribute.http.request.header).authorization"), .stringArray(["Bearer secret"]))
        XCTAssertEqual(span.attributes.get("\(OTelAttribute.http.request.header).password"), .stringArray(["SuperSecretPassword"]))
        XCTAssertEqual(span.attributes.get("\(OTelAttribute.http.response.header).x_method_used"), .stringArray(["GET"]))

        XCTAssertNoThrow(try client.syncShutdown()) 
    }
}
