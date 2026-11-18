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

import NIOHTTP1
import Testing

import struct Foundation.URL

@testable import AsyncHTTPClient

struct LocalAddressOverrideTests {
    // MARK: - Pool Key with localAddress

    @Test func poolKeysWithDifferentLocalAddressesAreNotEqual() {
        let key1 = ConnectionPool.Key(
            scheme: .https,
            connectionTarget: .domain(name: "example.com", port: 443),
            serverNameIndicatorOverride: nil,
            localAddress: "192.168.1.10"
        )
        let key2 = ConnectionPool.Key(
            scheme: .https,
            connectionTarget: .domain(name: "example.com", port: 443),
            serverNameIndicatorOverride: nil,
            localAddress: "10.0.0.1"
        )
        let keyNil = ConnectionPool.Key(
            scheme: .https,
            connectionTarget: .domain(name: "example.com", port: 443),
            serverNameIndicatorOverride: nil,
            localAddress: nil
        )
        #expect(key1 != key2)
        #expect(key1 != keyNil)
        #expect(key2 != keyNil)
    }

    @Test func poolKeysWithSameLocalAddressAreEqual() {
        let key1 = ConnectionPool.Key(
            scheme: .https,
            connectionTarget: .domain(name: "example.com", port: 443),
            serverNameIndicatorOverride: nil,
            localAddress: "192.168.1.10"
        )
        let key2 = ConnectionPool.Key(
            scheme: .https,
            connectionTarget: .domain(name: "example.com", port: 443),
            serverNameIndicatorOverride: nil,
            localAddress: "192.168.1.10"
        )
        #expect(key1 == key2)
    }

    @Test func poolKeyWithNilLocalAddressMatchesDefault() {
        let key1 = ConnectionPool.Key(
            scheme: .https,
            connectionTarget: .domain(name: "example.com", port: 443),
            serverNameIndicatorOverride: nil
        )
        let key2 = ConnectionPool.Key(
            scheme: .https,
            connectionTarget: .domain(name: "example.com", port: 443),
            serverNameIndicatorOverride: nil,
            localAddress: nil
        )
        #expect(key1 == key2)
    }

    // MARK: - Per-request localAddress override

    @Test func perRequestLocalAddressOverridesConfig() throws {
        var request = HTTPClientRequest(url: "https://example.com/get")
        request.localAddress = "10.0.0.1"

        let prepared = try HTTPClientRequest.Prepared(
            request,
            localAddress: "192.168.1.10"
        )

        #expect(prepared.poolKey.localAddress == "10.0.0.1")
    }

    @Test func configLocalAddressUsedWhenRequestHasNone() throws {
        let request = HTTPClientRequest(url: "https://example.com/get")

        let prepared = try HTTPClientRequest.Prepared(
            request,
            localAddress: "192.168.1.10"
        )

        #expect(prepared.poolKey.localAddress == "192.168.1.10")
    }

    @Test func noLocalAddressWhenNeitherSet() throws {
        let request = HTTPClientRequest(url: "https://example.com/get")

        let prepared = try HTTPClientRequest.Prepared(request)

        #expect(prepared.poolKey.localAddress == nil)
    }

    // MARK: - Redirect preserves localAddress

    @Test func redirectPreservesLocalAddress() {
        var request = HTTPClientRequest(url: "https://example.com/redirect/301")
        request.localAddress = "192.168.1.10"

        let redirected = request.followingRedirect(
            from: URL(string: "https://example.com/redirect/301")!,
            to: URL(string: "https://other.com/ok")!,
            status: .movedPermanently,
            config: .init(
                max: 5,
                allowCycles: false,
                retainHTTPMethodAndBodyOn301: false,
                retainHTTPMethodAndBodyOn302: false
            )
        )

        #expect(redirected.localAddress == "192.168.1.10")
    }

    // MARK: - Pool Key with localPort

    @Test func poolKeysWithDifferentLocalPortsAreNotEqual() {
        let key1 = ConnectionPool.Key(
            scheme: .https,
            connectionTarget: .domain(name: "example.com", port: 443),
            serverNameIndicatorOverride: nil,
            localAddress: "192.168.1.10",
            localPort: 12345
        )
        let key2 = ConnectionPool.Key(
            scheme: .https,
            connectionTarget: .domain(name: "example.com", port: 443),
            serverNameIndicatorOverride: nil,
            localAddress: "192.168.1.10",
            localPort: 12346
        )
        let keyEphemeral = ConnectionPool.Key(
            scheme: .https,
            connectionTarget: .domain(name: "example.com", port: 443),
            serverNameIndicatorOverride: nil,
            localAddress: "192.168.1.10"
        )
        #expect(key1 != key2)
        #expect(key1 != keyEphemeral)
        #expect(key2 != keyEphemeral)
    }

    @Test func poolKeysWithSameLocalPortAreEqual() {
        let key1 = ConnectionPool.Key(
            scheme: .https,
            connectionTarget: .domain(name: "example.com", port: 443),
            serverNameIndicatorOverride: nil,
            localAddress: "192.168.1.10",
            localPort: 12345
        )
        let key2 = ConnectionPool.Key(
            scheme: .https,
            connectionTarget: .domain(name: "example.com", port: 443),
            serverNameIndicatorOverride: nil,
            localAddress: "192.168.1.10",
            localPort: 12345
        )
        #expect(key1 == key2)
    }

    @Test func poolKeyLocalPortDefaultsToEphemeral() {
        let key = ConnectionPool.Key(
            scheme: .https,
            connectionTarget: .domain(name: "example.com", port: 443),
            serverNameIndicatorOverride: nil,
            localAddress: "192.168.1.10"
        )
        #expect(key.localPort == 0)
    }

    @Test func poolKeyDescriptionContainsBoundAddressAndPort() {
        let withPort = ConnectionPool.Key(
            scheme: .https,
            connectionTarget: .domain(name: "example.com", port: 443),
            serverNameIndicatorOverride: nil,
            localAddress: "192.168.1.10",
            localPort: 12345
        )
        let withoutPort = ConnectionPool.Key(
            scheme: .https,
            connectionTarget: .domain(name: "example.com", port: 443),
            serverNameIndicatorOverride: nil,
            localAddress: "192.168.1.10"
        )
        #expect(withPort.description.contains("bind: 192.168.1.10:12345"))
        #expect(withoutPort.description.contains("bind: 192.168.1.10"))
        #expect(!withoutPort.description.contains("192.168.1.10:"))
    }

    // MARK: - Per-request localPort override

    @Test func perRequestLocalPortOverridesConfig() throws {
        var request = HTTPClientRequest(url: "https://example.com/get")
        request.localPort = 12345

        let prepared = try HTTPClientRequest.Prepared(
            request,
            localAddress: "192.168.1.10",
            localPort: 54321
        )

        #expect(prepared.poolKey.localPort == 12345)
        #expect(prepared.poolKey.localAddress == "192.168.1.10")
    }

    @Test func configLocalPortUsedWhenRequestHasNone() throws {
        let request = HTTPClientRequest(url: "https://example.com/get")

        let prepared = try HTTPClientRequest.Prepared(
            request,
            localAddress: "192.168.1.10",
            localPort: 54321
        )

        #expect(prepared.poolKey.localPort == 54321)
    }

    @Test func perRequestLocalPortZeroOverridesNonZeroConfig() throws {
        var request = HTTPClientRequest(url: "https://example.com/get")
        request.localPort = 0

        let prepared = try HTTPClientRequest.Prepared(
            request,
            localAddress: "192.168.1.10",
            localPort: 54321
        )

        #expect(prepared.poolKey.localPort == 0)
    }

    @Test func noLocalPortWhenNeitherSet() throws {
        let request = HTTPClientRequest(url: "https://example.com/get")

        let prepared = try HTTPClientRequest.Prepared(request)

        #expect(prepared.poolKey.localPort == 0)
    }

    // MARK: - Redirect preserves localPort

    @Test func redirectPreservesLocalPort() {
        var request = HTTPClientRequest(url: "https://example.com/redirect/301")
        request.localAddress = "192.168.1.10"
        request.localPort = 12345

        let redirected = request.followingRedirect(
            from: URL(string: "https://example.com/redirect/301")!,
            to: URL(string: "https://other.com/ok")!,
            status: .movedPermanently,
            config: .init(
                max: 5,
                allowCycles: false,
                retainHTTPMethodAndBodyOn301: false,
                retainHTTPMethodAndBodyOn302: false
            )
        )

        #expect(redirected.localAddress == "192.168.1.10")
        #expect(redirected.localPort == 12345)
    }
}
