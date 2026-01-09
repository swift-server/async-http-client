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

            "timeout.connectionMs": 5000,
            "timeout.readMs": 30000,
            "timeout.writeMs": 15000,

            "connectionPool.idleTimeoutMs": 120_000,
            "connectionPool.concurrentHTTP1ConnectionsPerHostSoftLimit": 16,
            "connectionPool.retryConnectionEstablishment": false,
            "connectionPool.preWarmedHTTP1ConnectionCount": 5,

            "httpVersion": "http1Only",
            "maximumUsesPerConnection": 100,
        ])

        let configReader = ConfigReader(provider: testProvider)

        let config = try HTTPClient.Configuration(configReader: configReader)

        #expect(config.dnsOverride["localhost"] == "127.0.0.1")
        #expect(config.dnsOverride["example.com"] == "192.168.1.1")

        switch config.redirectConfiguration.mode {
        case .follow(let max, let allowCycles):
            #expect(max == 10)
            #expect(allowCycles)
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
    func dnsOverridesWithInvalidFormatIgnored() throws {
        let testProvider = InMemoryProvider(values: [
            "dnsOverrides": .init(.stringArray(["invalidentry", "localhost:127.0.0.1"]), isSecret: false)
        ])
        let configReader = ConfigReader(provider: testProvider)
        let config = try HTTPClient.Configuration(configReader: configReader)

        // Invalid entry should be ignored, valid one should be processed
        #expect(config.dnsOverride["localhost"] == "127.0.0.1")
        #expect(config.dnsOverride.count == 1)
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
        #expect(config.redirectConfiguration.mode == .follow(max: 5, allowCycles: false))
    }

    @Test
    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    func redirectConfigurationCustomValues() throws {
        let testProvider = InMemoryProvider(values: [
            "redirect.mode": "follow",
            "redirect.maxRedirects": 3,
            "redirect.allowCycles": true,
        ])

        let configReader = ConfigReader(provider: testProvider)

        let config = try HTTPClient.Configuration(configReader: configReader)

        #expect(config.redirectConfiguration.mode == .follow(max: 3, allowCycles: true))
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
    func singleDnsOverride() throws {
        let testProvider = InMemoryProvider(values: [
            "dnsOverrides": .init(.stringArray(["api.example.com:10.0.0.1"]), isSecret: false)
        ])

        let configReader = ConfigReader(provider: testProvider)
        let config = try HTTPClient.Configuration(configReader: configReader)

        #expect(config.dnsOverride["api.example.com"] == "10.0.0.1")
        #expect(config.dnsOverride.count == 1)
    }
}
