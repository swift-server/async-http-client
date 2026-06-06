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

import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import XCTest

@testable import AsyncHTTPClient

final class RandomizedDNSResolverIntegrationTests: XCTestCase {

    func testDefaultDNSResolverIsSystem() {
        let config = HTTPClient.Configuration()
        XCTAssertEqual(config.dnsResolver, .system)
    }

    func testRandomizedDNSResolverCanBeSet() {
        var config = HTTPClient.Configuration()
        config.dnsResolver = .randomized
        XCTAssertEqual(config.dnsResolver, .randomized)
    }

    func testDNSResolverEquality() {
        XCTAssertEqual(
            HTTPClient.Configuration.DNSResolver.system,
            HTTPClient.Configuration.DNSResolver.system
        )
        XCTAssertEqual(
            HTTPClient.Configuration.DNSResolver.randomized,
            HTTPClient.Configuration.DNSResolver.randomized
        )
        XCTAssertNotEqual(
            HTTPClient.Configuration.DNSResolver.system,
            HTTPClient.Configuration.DNSResolver.randomized
        )
    }

    /// Connect over plain HTTP through the `ClientBootstrap` factory path
    /// in `HTTPConnectionPool+Factory.swift`, exercising the `dnsResolver`
    /// switch for both `.system` and `.randomized`.
    func testResolverConnectsOverPlainHTTP() async throws {
        try await self.runConnectTest(ssl: false, resolver: .system)
        try await self.runConnectTest(ssl: false, resolver: .randomized)
    }

    /// Connect over HTTPS through the TLS `ClientBootstrap` factory path
    /// in `HTTPConnectionPool+Factory.swift`, exercising the `dnsResolver`
    /// switch for both `.system` and `.randomized`.
    func testResolverConnectsOverHTTPS() async throws {
        try await self.runConnectTest(ssl: true, resolver: .system)
        try await self.runConnectTest(ssl: true, resolver: .randomized)
    }

    private func runConnectTest(
        ssl: Bool,
        resolver: HTTPClient.Configuration.DNSResolver
    ) async throws {
        let bin = HTTPBin(.http1_1(ssl: ssl, compress: false))
        defer { XCTAssertNoThrow(try bin.shutdown()) }

        var config = HTTPClient.Configuration()
        config.dnsResolver = resolver
        if ssl {
            config.tlsConfiguration = .clientDefault
            config.tlsConfiguration?.certificateVerification = .none
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }

        let client = HTTPClient(
            eventLoopGroupProvider: .shared(group),
            configuration: config
        )
        defer { XCTAssertNoThrow(try client.syncShutdown()) }

        let scheme = ssl ? "https" : "http"
        let request = HTTPClientRequest(url: "\(scheme)://localhost:\(bin.port)/get")
        let response = try await client.execute(request, deadline: .now() + .seconds(5))
        XCTAssertEqual(response.status, .ok)
    }
}
