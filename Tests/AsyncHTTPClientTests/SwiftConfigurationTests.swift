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

#if compiler(>=6.2)
import Configuration
import Foundation
import NIOCore
import Testing

@testable import AsyncHTTPClient

struct HTTPClientConfigurationPropsTests {
    @Test
    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    func allPropertiesAreSetFromConfig() throws {
        let testProvider = InMemoryProvider(values: [
            "dnsOverrides": .init(.stringArray(["localhost:127.0.0.1", "example.com:192.168.1.1"]), isSecret: false),
            "redirect.mode": "follow",
            "redirect.maxRedirects": 10,
            "redirect.allowCycles": true,
            "redirect.retainHTTPMethodAndBodyOn301": true,
            "redirect.retainHTTPMethodAndBodyOn302": true,

            "timeout.connectionMs": 5000,
            "timeout.readMs": 30000,
            "timeout.writeMs": 15000,

            "connectionPool.idleTimeoutMs": 120_000,
            "connectionPool.concurrentHTTP1ConnectionsPerHostSoftLimit": 16,
            "connectionPool.retryConnectionEstablishment": false,
            "connectionPool.preWarmedHTTP1ConnectionCount": 5,

            "httpVersion": "http1Only",
            "maximumUsesPerConnection": 100,

            "proxy.enabled": true,
            "proxy.host": "proxy.example.com",
            "proxy.port": 8080,
            "proxy.type": "http",
            "proxy.authorization.scheme": "basic",
            "proxy.authorization.username": "user",
            "proxy.authorization.password": "pass",
        ])

        let configReader = ConfigReader(provider: testProvider)

        let config = try HTTPClient.Configuration(configReader: configReader)

        #expect(config.dnsOverride["localhost"] == "127.0.0.1")
        #expect(config.dnsOverride["example.com"] == "192.168.1.1")

        switch config.redirectConfiguration.mode {
        case .follow(let follow):
            #expect(follow.max == 10)
            #expect(follow.allowCycles)
            #expect(follow.retainHTTPMethodAndBodyOn301)
            #expect(follow.retainHTTPMethodAndBodyOn302)
        case .disallow:
            Issue.record("Unexpected value")
        }

        #expect(config.timeout.connect == .milliseconds(5000))
        #expect(config.timeout.read == .milliseconds(30000))
        #expect(config.timeout.write == .milliseconds(15000))

        #expect(config.connectionPool.idleTimeout == .milliseconds(120000))
        #expect(config.connectionPool.concurrentHTTP1ConnectionsPerHostSoftLimit == 16)
        #expect(config.connectionPool.retryConnectionEstablishment == false)
        #expect(config.connectionPool.preWarmedHTTP1ConnectionCount == 5)

        #expect(config.httpVersion == .http1Only)

        #expect(config.maximumUsesPerConnection == 100)

        #expect(
            config.proxy
                == .server(
                    host: "proxy.example.com",
                    port: 8080,
                    authorization: .basic(username: "user", password: "pass")
                )
        )
    }

    @Test
    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    func defaultsAreUsedWhenConfigIsEmpty() throws {
        let testProvider = InMemoryProvider(values: [:])
        let configReader = ConfigReader(provider: testProvider)

        let config = try HTTPClient.Configuration(configReader: configReader)

        #expect(config.dnsOverride.isEmpty)

        #expect(config.timeout.connect == nil)
        #expect(config.timeout.read == nil)
        #expect(config.timeout.write == nil)

        #expect(config.connectionPool.idleTimeout == .seconds(60))
        #expect(config.connectionPool.concurrentHTTP1ConnectionsPerHostSoftLimit == 8)
        #expect(config.connectionPool.retryConnectionEstablishment == true)
        #expect(config.connectionPool.preWarmedHTTP1ConnectionCount == 0)

        #expect(config.httpVersion == .automatic)

        #expect(config.maximumUsesPerConnection == nil)

        #expect(config.proxy == nil)
    }

    @Test
    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    func redirectConfigurationDisallow() throws {
        let testProvider = InMemoryProvider(values: ["redirect.mode": "disallow"])
        let configReader = ConfigReader(provider: testProvider)

        let config = try HTTPClient.Configuration(configReader: configReader)
        switch config.redirectConfiguration.mode {
        case .disallow:
            break
        case .follow:
            Issue.record("Unexpected value")
        }
    }

    @Test
    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    func redirectConfigurationInvalidModeThrowsError() throws {
        let testProvider = InMemoryProvider(values: ["redirect.mode": "invalid"])
        let configReader = ConfigReader(provider: testProvider)
        #expect(throws: HTTPClientError.invalidRedirectConfiguration) {
            _ = try HTTPClient.Configuration(configReader: configReader)
        }
    }

    @Test
    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    func httpVersionAutomatic() throws {
        let testProvider = InMemoryProvider(values: ["httpVersion": "automatic"])
        let configReader = ConfigReader(provider: testProvider)

        let config = try HTTPClient.Configuration(configReader: configReader)

        #expect(config.httpVersion == .automatic)
    }

    @Test
    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    func httpVersionInvalidThrowsError() throws {
        let testProvider = InMemoryProvider(values: ["httpVersion": "http3"])
        let configReader = ConfigReader(provider: testProvider)
        #expect(throws: HTTPClientError.invalidHTTPVersionConfiguration) {
            try HTTPClient.Configuration(configReader: configReader)
        }
    }

    @Test
    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    func dnsOverridesWithIPv6() throws {
        let testProvider = InMemoryProvider(values: [
            "dnsOverrides": .init(.stringArray(["localhost:::1", "example.com:2001:db8::1"]), isSecret: false)
        ])
        let configReader = ConfigReader(provider: testProvider)

        let config = try HTTPClient.Configuration(configReader: configReader)

        #expect(config.dnsOverride["localhost"] == "::1")
        #expect(config.dnsOverride["example.com"] == "2001:db8::1")
    }

    @Test
    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    func dnsOverridesWithInvalidFormat() throws {
        let testProvider = InMemoryProvider(values: [
            "dnsOverrides": .init(.stringArray(["invalidentry", "localhost:127.0.0.1"]), isSecret: false)
        ])
        let configReader = ConfigReader(provider: testProvider)
        #expect(throws: HTTPClientError.invalidDNSOverridesConfiguration) {
            _ = try HTTPClient.Configuration(configReader: configReader)
        }
    }

    @Test
    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    func dnsOverridesWithBlankValue() throws {
        let testProvider = InMemoryProvider(values: [
            "dnsOverrides": .init(.stringArray(["localhost:"]), isSecret: false)
        ])
        let configReader = ConfigReader(provider: testProvider)
        #expect(throws: HTTPClientError.invalidDNSOverridesConfiguration) {
            _ = try HTTPClient.Configuration(configReader: configReader)
        }
    }

    @Test
    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    func dnsOverridesWithBlankKey() throws {
        let testProvider = InMemoryProvider(values: [
            "dnsOverrides": .init(.stringArray([":127.0.0.1"]), isSecret: false)
        ])
        let configReader = ConfigReader(provider: testProvider)
        #expect(throws: HTTPClientError.invalidDNSOverridesConfiguration) {
            _ = try HTTPClient.Configuration(configReader: configReader)
        }
    }

    @Test
    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    func dnsOverridesWithSpaces() throws {
        let testProvider = InMemoryProvider(values: [
            "dnsOverrides": .init(.stringArray(["test.com: 127.0.0.1"]), isSecret: false)
        ])
        let configReader = ConfigReader(provider: testProvider)
        let config = try HTTPClient.Configuration(configReader: configReader)
        #expect(config.dnsOverride == ["test.com": "127.0.0.1"])
    }

    @Test
    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    func timeoutConfigurationPartial() throws {
        let testProvider = InMemoryProvider(values: [
            "timeout.connectionMs": 1000,
            "timeout.readMs": 2000,
        ])
        let configReader = ConfigReader(provider: testProvider)
        let config = try HTTPClient.Configuration(configReader: configReader)

        #expect(config.timeout.connect == .milliseconds(1000))
        #expect(config.timeout.read == .milliseconds(2000))
        #expect(config.timeout.write == nil)
    }

    @Test
    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    func connectionPoolConfigurationPartial() throws {
        let testProvider = InMemoryProvider(values: [
            "connectionPool.idleTimeoutMs": 90000,
            "connectionPool.concurrentHTTP1ConnectionsPerHostSoftLimit": 12,
        ])

        let configReader = ConfigReader(provider: testProvider)
        let config = try HTTPClient.Configuration(configReader: configReader)

        #expect(config.connectionPool.idleTimeout == .milliseconds(90000))
        #expect(config.connectionPool.concurrentHTTP1ConnectionsPerHostSoftLimit == 12)
        // These should use defaults
        #expect(config.connectionPool.retryConnectionEstablishment)
        #expect(config.connectionPool.preWarmedHTTP1ConnectionCount == 0)
    }

    @Test
    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    func redirectConfigurationWithDefaults() throws {
        let testProvider = InMemoryProvider(values: [
            "redirect.mode": "follow"
        ])

        let configReader = ConfigReader(provider: testProvider)
        let config = try HTTPClient.Configuration(configReader: configReader)
        #expect(
            config.redirectConfiguration.mode
                == .follow(
                    .init(
                        max: 5,
                        allowCycles: false,
                        retainHTTPMethodAndBodyOn301: false,
                        retainHTTPMethodAndBodyOn302: false
                    )
                )
        )
    }

    @Test
    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    func redirectConfigurationCustomValues() throws {
        let testProvider = InMemoryProvider(values: [
            "redirect.mode": "follow",
            "redirect.maxRedirects": 3,
            "redirect.allowCycles": true,
            "redirect.retainHTTPMethodAndBodyOn301": true,
            "redirect.retainHTTPMethodAndBodyOn302": false,
        ])

        let configReader = ConfigReader(provider: testProvider)

        let config = try HTTPClient.Configuration(configReader: configReader)

        #expect(
            config.redirectConfiguration.mode
                == .follow(
                    .init(
                        max: 3,
                        allowCycles: true,
                        retainHTTPMethodAndBodyOn301: true,
                        retainHTTPMethodAndBodyOn302: false
                    )
                )
        )
    }

    @Test
    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    func emptyDnsOverridesArray() throws {
        let testProvider = InMemoryProvider(values: [
            "dnsOverrides": "[]"
        ])
        let configReader = ConfigReader(provider: testProvider)
        let config = try HTTPClient.Configuration(configReader: configReader)

        #expect(config.dnsOverride.isEmpty)
    }

    @Test
    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    func proxyHTTPWithoutAuthorization() throws {
        let testProvider = InMemoryProvider(values: [
            "proxy.enabled": true,
            "proxy.host": "proxy.example.com",
            "proxy.port": 8080,
        ])
        let configReader = ConfigReader(provider: testProvider)
        let config = try HTTPClient.Configuration(configReader: configReader)

        #expect(config.proxy == .server(host: "proxy.example.com", port: 8080))
        #expect(config.proxy?.authorization == nil)
    }

    @Test
    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    func proxyHTTPWithBasicAuthCredentials() throws {
        let testProvider = InMemoryProvider(values: [
            "proxy.enabled": true,
            "proxy.host": "proxy.example.com",
            "proxy.port": 8080,
            "proxy.authorization.scheme": "basic",
            "proxy.authorization.credentials": "dXNlcjpwYXNz",
        ])
        let configReader = ConfigReader(provider: testProvider)
        let config = try HTTPClient.Configuration(configReader: configReader)

        #expect(
            config.proxy
                == .server(host: "proxy.example.com", port: 8080, authorization: .basic(credentials: "dXNlcjpwYXNz"))
        )
    }

    @Test
    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    func proxyHTTPWithBearerAuth() throws {
        let testProvider = InMemoryProvider(values: [
            "proxy.enabled": true,
            "proxy.host": "proxy.example.com",
            "proxy.port": 8080,
            "proxy.type": "http",
            "proxy.authorization.scheme": "bearer",
            "proxy.authorization.token": "abc123",
        ])
        let configReader = ConfigReader(provider: testProvider)
        let config = try HTTPClient.Configuration(configReader: configReader)

        #expect(
            config.proxy
                == .server(host: "proxy.example.com", port: 8080, authorization: .bearer(tokens: "abc123"))
        )
    }

    @Test
    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    func proxySOCKSWithDefaultPort() throws {
        let testProvider = InMemoryProvider(values: [
            "proxy.enabled": true,
            "proxy.host": "socks.example.com",
            "proxy.type": "socks",
        ])
        let configReader = ConfigReader(provider: testProvider)
        let config = try HTTPClient.Configuration(configReader: configReader)

        #expect(config.proxy == .socksServer(host: "socks.example.com"))
        #expect(config.proxy?.port == 1080)
    }

    @Test
    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    func proxySOCKSWithCustomPort() throws {
        let testProvider = InMemoryProvider(values: [
            "proxy.enabled": true,
            "proxy.host": "socks.example.com",
            "proxy.port": 9050,
            "proxy.type": "socks",
        ])
        let configReader = ConfigReader(provider: testProvider)
        let config = try HTTPClient.Configuration(configReader: configReader)

        #expect(config.proxy == .socksServer(host: "socks.example.com", port: 9050))
    }

    @Test
    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    func proxyDisabledIgnoresOtherKeys() throws {
        let testProvider = InMemoryProvider(values: [
            "proxy.enabled": false,
            "proxy.host": "proxy.example.com",
            "proxy.port": 8080,
        ])
        let configReader = ConfigReader(provider: testProvider)
        let config = try HTTPClient.Configuration(configReader: configReader)

        #expect(config.proxy == nil)
    }

    @Test
    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    func proxyEnabledWithoutHostThrowsError() throws {
        let testProvider = InMemoryProvider(values: [
            "proxy.enabled": true,
            "proxy.port": 8080,
        ])
        let configReader = ConfigReader(provider: testProvider)
        #expect(throws: (any Error).self) {
            _ = try HTTPClient.Configuration(configReader: configReader)
        }
    }

    @Test
    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    func proxyHTTPMissingPortThrowsError() throws {
        let testProvider = InMemoryProvider(values: [
            "proxy.enabled": true,
            "proxy.host": "proxy.example.com",
        ])
        let configReader = ConfigReader(provider: testProvider)
        #expect(throws: (any Error).self) {
            _ = try HTTPClient.Configuration(configReader: configReader)
        }
    }

    @Test
    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    func proxyUnknownTypeThrowsError() throws {
        let testProvider = InMemoryProvider(values: [
            "proxy.enabled": true,
            "proxy.host": "proxy.example.com",
            "proxy.port": 8080,
            "proxy.type": "unknown",
        ])
        let configReader = ConfigReader(provider: testProvider)
        #expect(throws: (any Error).self) {
            _ = try HTTPClient.Configuration(configReader: configReader)
        }
    }

    @Test
    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    func proxySOCKSWithAuthorizationThrowsError() throws {
        let testProvider = InMemoryProvider(values: [
            "proxy.enabled": true,
            "proxy.host": "socks.example.com",
            "proxy.type": "socks",
            "proxy.authorization.scheme": "basic",
            "proxy.authorization.username": "user",
            "proxy.authorization.password": "pass",
        ])
        let configReader = ConfigReader(provider: testProvider)
        #expect(throws: HTTPClientError.invalidProxyConfiguration) {
            _ = try HTTPClient.Configuration(configReader: configReader)
        }
    }

    @Test
    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    func proxyBasicAuthWithoutCredentialsThrowsError() throws {
        let testProvider = InMemoryProvider(values: [
            "proxy.enabled": true,
            "proxy.host": "proxy.example.com",
            "proxy.port": 8080,
            "proxy.authorization.scheme": "basic",
        ])
        let configReader = ConfigReader(provider: testProvider)
        #expect(throws: HTTPClientError.invalidProxyConfiguration) {
            _ = try HTTPClient.Configuration(configReader: configReader)
        }
    }

    @Test
    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    func proxyBearerAuthWithoutTokenThrowsError() throws {
        let testProvider = InMemoryProvider(values: [
            "proxy.enabled": true,
            "proxy.host": "proxy.example.com",
            "proxy.port": 8080,
            "proxy.authorization.scheme": "bearer",
        ])
        let configReader = ConfigReader(provider: testProvider)
        #expect(throws: HTTPClientError.invalidProxyConfiguration) {
            _ = try HTTPClient.Configuration(configReader: configReader)
        }
    }

    @Test
    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    func proxyUnknownAuthSchemeThrowsError() throws {
        let testProvider = InMemoryProvider(values: [
            "proxy.enabled": true,
            "proxy.host": "proxy.example.com",
            "proxy.port": 8080,
            "proxy.authorization.scheme": "digest",
        ])
        let configReader = ConfigReader(provider: testProvider)
        #expect(throws: HTTPClientError.invalidProxyConfiguration) {
            _ = try HTTPClient.Configuration(configReader: configReader)
        }
    }
}
#endif
