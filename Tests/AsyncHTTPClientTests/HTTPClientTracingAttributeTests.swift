//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2026 Apple Inc. and the AsyncHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

@_spi(Tracing) import AsyncHTTPClient  // NOT @testable - tests that need @testable go into HTTPClientTracingInternalTests.swift
import InMemoryTracing
import NIOCore
import NIOHTTP1
import Testing
import Tracing

@Suite("HTTPClient tracing attributes")
struct HTTPClientTracingAttributeTests {
    @Test func traceAttributesURL() async throws {
        let httpBin = HTTPBin()
        defer { #expect(throws: Never.self) { try httpBin.shutdown() } }

        let tracer = InMemoryTracer()
        let httpClient = HTTPClient(
            eventLoopGroupProvider: .singleton,
            configuration: makeConfiguration(tracer: tracer)
        )
        defer { #expect(throws: Never.self) { try httpClient.syncShutdown() } }

        let request = makeRequest(url: httpBin.baseURL + "echo-method?foo=bar&Signature=secretSignature")
        _ = try await httpClient.execute(request, deadline: .distantFuture)

        #expect(
            tracer.activeSpans.isEmpty,
            "Still active spans which were not finished (\(tracer.activeSpans.count))! \(tracer.activeSpans)"
        )
        let span = try #require(tracer.finishedSpans.first)
        let keys = HTTPClient.TracingConfiguration.AttributeKeys()

        #expect(span.attributes.get(keys.urlPath) == "/echo-method")
        #expect(span.attributes.get(keys.urlScheme) == "http")
        #expect(span.attributes.get(keys.urlQuery) == "foo=bar&Signature=REDACTED")
    }

    @Test func traceAttributesServer() async throws {
        let httpBin = HTTPBin()
        defer { #expect(throws: Never.self) { try httpBin.shutdown() } }

        let tracer = InMemoryTracer()
        let httpClient = HTTPClient(
            eventLoopGroupProvider: .singleton,
            configuration: makeConfiguration(tracer: tracer)
        )
        defer { #expect(throws: Never.self) { try httpClient.syncShutdown() } }

        let request = makeRequest(url: httpBin.baseURL + "echo-method?foo=bar&Signature=secretSignature")
        _ = try await httpClient.execute(request, deadline: .distantFuture)

        #expect(
            tracer.activeSpans.isEmpty,
            "Still active spans which were not finished (\(tracer.activeSpans.count))! \(tracer.activeSpans)"
        )
        let span = try #require(tracer.finishedSpans.first)
        let defaultHTTPBinPort = try #require(httpBin.socketAddress.port)
        let defaultHTTPBinAddress = try #require(httpBin.socketAddress.ipAddress)
        let keys = HTTPClient.TracingConfiguration.AttributeKeys()

        #expect(span.attributes.get(keys.serverHostname) == .string(defaultHTTPBinAddress.description))
        #expect(span.attributes.get(keys.serverPort) == .int64(Int64(defaultHTTPBinPort)))
    }

    @Test func traceAttributesHTTP() async throws {
        let httpBin = HTTPBin()
        defer { #expect(throws: Never.self) { try httpBin.shutdown() } }

        let tracer = InMemoryTracer()
        var configuration = makeConfiguration(tracer: tracer)
        configuration.tracing.allowedHeaders = ["Authorization"]
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton, configuration: configuration)
        defer { #expect(throws: Never.self) { try httpClient.syncShutdown() } }

        let request = makeRequest(url: httpBin.baseURL + "echo-method?foo=bar&Signature=secretSignature")
        _ = try await httpClient.execute(request, deadline: .distantFuture)

        #expect(
            tracer.activeSpans.isEmpty,
            "Still active spans which were not finished (\(tracer.activeSpans.count))! \(tracer.activeSpans)"
        )
        let span = try #require(tracer.finishedSpans.first)
        let keys = HTTPClient.TracingConfiguration.AttributeKeys()

        #expect(span.attributes.get(keys.requestMethod) == "GET")
        #expect(span.attributes.get("\(keys.requestHeader).authorization") == .stringArray(["Bearer secret"]))
        #expect(span.attributes.get("\(keys.requestHeader).password") == nil)
        #expect(span.attributes.get(keys.responseStatusCode) == 200)
    }

    @Test func traceAttributesPathRedaction() async throws {
        let httpBin = HTTPBin()
        defer { #expect(throws: Never.self) { try httpBin.shutdown() } }

        let tracer = InMemoryTracer()
        var configuration = makeConfiguration(tracer: tracer)
        configuration.tracing.sensitivePathComponents = ["nested-path"]
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton, configuration: configuration)
        defer { #expect(throws: Never.self) { try httpClient.syncShutdown() } }

        let request = makeRequest(url: httpBin.baseURL + "echo-method/nested-path")
        _ = try await httpClient.execute(request, deadline: .distantFuture)

        #expect(
            tracer.activeSpans.isEmpty,
            "Still active spans which were not finished (\(tracer.activeSpans.count))! \(tracer.activeSpans)"
        )
        let span = try #require(tracer.finishedSpans.first)
        let keys = HTTPClient.TracingConfiguration.AttributeKeys()

        #expect(span.attributes.get(keys.urlPath) == "/echo-method/REDACTED")
    }

    @Test func traceAttributesQueryRedaction() async throws {
        let httpBin = HTTPBin()
        defer { #expect(throws: Never.self) { try httpBin.shutdown() } }

        let tracer = InMemoryTracer()
        var configuration = makeConfiguration(tracer: tracer)
        configuration.tracing.sensitiveQueryComponents.insert("foo")
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton, configuration: configuration)
        defer { #expect(throws: Never.self) { try httpClient.syncShutdown() } }

        let request = makeRequest(url: httpBin.baseURL + "echo-method?foo=bar&Signature=secretSignature&bar=bar")
        _ = try await httpClient.execute(request, deadline: .distantFuture)

        #expect(
            tracer.activeSpans.isEmpty,
            "Still active spans which were not finished (\(tracer.activeSpans.count))! \(tracer.activeSpans)"
        )
        let span = try #require(tracer.finishedSpans.first)
        let keys = HTTPClient.TracingConfiguration.AttributeKeys()

        #expect(span.attributes.get(keys.urlQuery) == "foo=REDACTED&Signature=REDACTED&bar=bar")
    }

    @Test func traceAttributesHTTPHeadersDisallowedByDefault() async throws {
        let httpBin = HTTPBin()
        defer { #expect(throws: Never.self) { try httpBin.shutdown() } }

        let tracer = InMemoryTracer()
        let httpClient = HTTPClient(
            eventLoopGroupProvider: .singleton,
            configuration: makeConfiguration(tracer: tracer)
        )
        defer { #expect(throws: Never.self) { try httpClient.syncShutdown() } }

        let request = makeRequest(url: httpBin.baseURL + "echo-method?foo=bar&Signature=secretSignature")
        _ = try await httpClient.execute(request, deadline: .distantFuture)

        #expect(
            tracer.activeSpans.isEmpty,
            "Still active spans which were not finished (\(tracer.activeSpans.count))! \(tracer.activeSpans)"
        )
        let span = try #require(tracer.finishedSpans.first)

        #expect(span.operationName == "GET")
        #expect(span.attributes.get("http.request.header.authorization") == nil)
        #expect(span.attributes.get("http.request.header.password") == nil)
    }

    @Test func traceAttributesHTTPHeaders() async throws {
        let httpBin = HTTPBin()
        defer { #expect(throws: Never.self) { try httpBin.shutdown() } }

        let tracer = InMemoryTracer()
        var configuration = makeConfiguration(tracer: tracer)
        configuration.tracing.allowedHeaders = ["Authorization", "Password", "X-Method-Used"]
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton, configuration: configuration)
        defer { #expect(throws: Never.self) { try httpClient.syncShutdown() } }

        let request = makeRequest(url: httpBin.baseURL + "echo-method?foo=bar&Signature=secretSignature")
        _ = try await httpClient.execute(request, deadline: .distantFuture)

        #expect(
            tracer.activeSpans.isEmpty,
            "Still active spans which were not finished (\(tracer.activeSpans.count))! \(tracer.activeSpans)"
        )
        let span = try #require(tracer.finishedSpans.first)

        #expect(span.operationName == "GET")
        #expect(span.attributes.get("http.request.header.authorization") == .stringArray(["Bearer secret"]))
        #expect(span.attributes.get("http.request.header.password") == .stringArray(["SuperSecretPassword"]))
        #expect(span.attributes.get("http.response.header.x_method_used") == .stringArray(["GET"]))
    }

    private func makeConfiguration(tracer: InMemoryTracer) -> HTTPClient.Configuration {
        var configuration = HTTPClient.Configuration()
        configuration.httpVersion = .automatic
        configuration.tracing.tracer = tracer
        return configuration
    }

    private func makeRequest(url: String) -> HTTPClientRequest {
        var request = HTTPClientRequest(url: url)
        request.headers.add(name: "Authorization", value: "Bearer secret")
        request.headers.add(name: "Password", value: "SuperSecretPassword")
        return request
    }
}
