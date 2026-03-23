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
}
