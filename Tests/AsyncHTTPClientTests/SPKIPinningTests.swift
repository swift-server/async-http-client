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

import Crypto
import InMemoryLogging
import Logging
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOPosix
import NIOSSL
import NIOTLS
import XCTest

@testable import AsyncHTTPClient

#if canImport(Network)
import Network
import NIOTransportServices
#endif

class SPKIPinningTests: XCTestCase {

    // MARK: - SPKIPinningConfiguration.contains(spkiBytes:)

    func testContains_WithMatchingPin_ReturnsTrue() throws {
        let (certificate, spkiHash) = try Self.testCertificateAndSPKIHash()
        let pin = try SPKIHash(algorithm: SHA256.self, bytes: Data(spkiHash))
        let config = SPKIPinningConfiguration(
            pins: [pin],
            policy: .strict
        )

        let publicKey = try certificate.extractPublicKey()
        let spkiBytes = try publicKey.toSPKIBytes()

        XCTAssertTrue(config.contains(spkiBytes: spkiBytes))
    }

    func testContains_WithMismatchedPin_ReturnsFalse() throws {
        let (certificate, _) = try Self.testCertificateAndSPKIHash()
        let mismatchedPin = try SPKIHash(algorithm: SHA256.self, base64: "9uO07DlRgCzpXEaC2+ZiqB0VFcjdn43d6h+U2lUHORo=")
        let config = SPKIPinningConfiguration(
            pins: [mismatchedPin],
            policy: .strict
        )

        let publicKey = try certificate.extractPublicKey()
        let spkiBytes = try publicKey.toSPKIBytes()

        XCTAssertFalse(config.contains(spkiBytes: spkiBytes))
    }

    func testContains_WithEmptyInput_ReturnsFalse() throws {
        let pin = try SPKIHash(algorithm: SHA256.self, base64: "9uO07DlRgCzpXEaC2+ZiqB0VFcjdn43d6h+U2lUHORo=")
        let config = SPKIPinningConfiguration(
            pins: [pin],
            policy: .strict
        )

        XCTAssertFalse(config.contains(spkiBytes: []))
    }

    // MARK: - SPKIPinningHandler.validatePinning(for:)

    func testValidatePinning_WithValidPin_InStrictMode_ReturnsAccepted() throws {
        let (certificate, spkiHash) = try Self.testCertificateAndSPKIHash()
        let pin = try SPKIHash(algorithm: SHA256.self, bytes: Data(spkiHash))
        let config = SPKIPinningConfiguration(
            pins: [pin],
            policy: .strict
        )
        let handler = try makeHandler(config: config)

        let result = handler.validatePinning(for: .success(certificate))

        if case .accepted = result {
            return
        }

        XCTFail("Expected validation to succeed")
    }

    func testValidatePinning_WithValidPin_InAuditMode_ReturnsAccepted() throws {
        let (certificate, spkiHash) = try Self.testCertificateAndSPKIHash()
        let pin = try SPKIHash(algorithm: SHA256.self, bytes: Data(spkiHash))
        let config = SPKIPinningConfiguration(
            pins: [pin],
            policy: .audit
        )
        let handler = try makeHandler(config: config)

        let result = handler.validatePinning(for: .success(certificate))

        if case .accepted = result {
            return
        }

        XCTFail("Expected validation to succeed, got \(result)")
    }

    func testValidatePinning_WithMismatchedPin_InStrictMode_ReturnsRejected() throws {
        let (certificate, _) = try Self.testCertificateAndSPKIHash()
        let mismatchedPin = try SPKIHash(algorithm: SHA256.self, base64: "9uO07DlRgCzpXEaC2+ZiqB0VFcjdn43d6h+U2lUHORo=")
        let config = SPKIPinningConfiguration(
            pins: [mismatchedPin],
            policy: .strict
        )
        let handler = try makeHandler(config: config)

        let result = handler.validatePinning(for: .success(certificate))

        guard case .rejected(let error) = result else {
            XCTFail("Expected .rejected, got \(result)")
            return
        }

        if case .pinMismatch = error as? SPKIPinningHandlerError {
            return
        }

        XCTFail("Expected .pinMismatch, got \(error)")
    }

    func testValidatePinning_WithMismatchedPin_InAuditMode_ReturnsAuditWarning() throws {
        let (certificate, _) = try Self.testCertificateAndSPKIHash()
        let mismatchedPin = try SPKIHash(algorithm: SHA256.self, base64: "9uO07DlRgCzpXEaC2+ZiqB0VFcjdn43d6h+U2lUHORo=")
        let config = SPKIPinningConfiguration(
            pins: [mismatchedPin],
            policy: .audit
        )
        let handler = try makeHandler(config: config)

        let result = handler.validatePinning(for: .success(certificate))

        guard case .auditWarning(let error) = result else {
            XCTFail("Expected .auditWarning, got \(result)")
            return
        }

        if case .pinMismatch = error as? SPKIPinningHandlerError {
            return
        }

        XCTFail("Expected .pinMismatch, got \(error)")
    }

    func testValidatePinning_WithNilCertificate_InStrictMode_ReturnsRejected() throws {
        let pin = try SPKIHash(algorithm: SHA256.self, base64: "9uO07DlRgCzpXEaC2+ZiqB0VFcjdn43d6h+U2lUHORo=")
        let config = SPKIPinningConfiguration(
            pins: [pin],
            policy: .strict
        )
        let handler = try makeHandler(config: config)

        let result = handler.validatePinning(for: .success(nil))

        guard case .rejected(let error) = result else {
            XCTFail("Expected .rejected, got \(result)")
            return
        }

        if case .emptyCertificateChain = error as? SPKIPinningHandlerError {
            return
        }

        XCTFail("Expected .emptyCertificateChain, got \(error)")
    }

    func testValidatePinning_WithNilCertificate_InAuditMode_ReturnsAuditWarning() throws {
        let pin = try SPKIHash(algorithm: SHA256.self, base64: "9uO07DlRgCzpXEaC2+ZiqB0VFcjdn43d6h+U2lUHORo=")
        let config = SPKIPinningConfiguration(
            pins: [pin],
            policy: .audit
        )
        let handler = try makeHandler(config: config)

        let result = handler.validatePinning(for: .success(nil))

        guard case .auditWarning(let error) = result else {
            XCTFail("Expected .auditWarning, got \(result)")
            return
        }

        if case .emptyCertificateChain = error as? SPKIPinningHandlerError {
            return
        }

        XCTFail("Expected .emptyCertificateChain, got \(error)")
    }

    func testValidatePinning_WithExtractionFailure_InStrictMode_ReturnsRejected() throws {
        let pin = try SPKIHash(algorithm: SHA256.self, base64: "9uO07DlRgCzpXEaC2+ZiqB0VFcjdn43d6h+U2lUHORo=")
        let config = SPKIPinningConfiguration(
            pins: [pin],
            policy: .strict
        )
        let handler = try makeHandler(config: config)
        let extractionError = NSError(domain: "TestError", code: 1, userInfo: nil)

        let result = handler.validatePinning(for: .failure(extractionError))

        guard case .rejected(let error) = result else {
            XCTFail("Expected .rejected, got \(result)")
            return
        }
        XCTAssertTrue((error as? SPKIPinningHandlerError)?.description.contains("SSL handler not found: ") == true)
    }

    func testValidatePinning_WithExtractionFailure_InAuditMode_ReturnsAuditWarning() throws {
        let pin = try SPKIHash(algorithm: SHA256.self, base64: "9uO07DlRgCzpXEaC2+ZiqB0VFcjdn43d6h+U2lUHORo=")
        let config = SPKIPinningConfiguration(
            pins: [pin],
            policy: .audit
        )
        let handler = try makeHandler(config: config)
        let extractionError = NSError(domain: "TestError", code: 1, userInfo: nil)

        let result = handler.validatePinning(for: .failure(extractionError))

        guard case .auditWarning(let error) = result else {
            XCTFail("Expected .auditWarning, got \(result)")
            return
        }
        XCTAssertTrue((error as? SPKIPinningHandlerError)?.description.contains("SSL handler not found: ") == true)
    }

    // MARK: - SPKIPinningHandler.userInboundEventTriggered(...)

    func testUserInboundEventTriggered_IgnoresNonHandshakeEvents() throws {
        let config = SPKIPinningConfiguration(
            pins: [],
            policy: .strict
        )
        let handler = try makeHandler(config: config)
        let event = TLSUserEvent.shutdownCompleted

        let embedded = EmbeddedChannel(handlers: [handler])
        embedded.pipeline.fireUserInboundEventTriggered(event)
        try embedded.throwIfErrorCaught()
    }

    func testUserInboundEventTriggered_OnHandshakeInitiatesValidation() throws {
        let config = SPKIPinningConfiguration(
            pins: [],
            policy: .strict
        )
        let handler = try makeHandler(config: config)
        let event = TLSUserEvent.handshakeCompleted(negotiatedProtocol: nil)

        let embedded = EmbeddedChannel(handlers: [handler])
        embedded.pipeline.fireUserInboundEventTriggered(event)

        XCTAssertThrowsError(try embedded.throwIfErrorCaught()) {
            if let error = $0 as? HTTPClientError {
                XCTAssertTrue(error.description.contains("SSL handler not found: "))
            }
        }
    }

    // MARK: - End-to-End Tests: HTTP/2

    func testSPKIPinning_HTTP2_ValidPin_AllowsConnection() async throws {
        try await runSPKIPinningTest(
            useValidPin: true,
            policy: .strict,
            mode: .http2(tlsConfiguration: TestTLS.serverConfiguration)
        )
    }

    func testSPKIPinning_HTTP2_InvalidPin_RejectsConnection() async throws {
        try await runSPKIPinningTest(
            useValidPin: false,
            policy: .strict,
            mode: .http2(tlsConfiguration: TestTLS.serverConfiguration)
        )
    }

    func testSPKIPinning_HTTP2_ValidPin_AuditMode_AllowsConnection() async throws {
        try await runSPKIPinningTest(
            useValidPin: true,
            policy: .audit,
            mode: .http2(tlsConfiguration: TestTLS.serverConfiguration)
        )
    }

    func testSPKIPinning_HTTP2_InvalidPin_AuditMode_AllowsConnection() async throws {
        try await runSPKIPinningTest(
            useValidPin: false,
            policy: .audit,
            mode: .http2(tlsConfiguration: TestTLS.serverConfiguration)
        )
    }

    // MARK: - End-to-End Tests: HTTP/1.1

    func testSPKIPinning_HTTP1_ValidPin_AllowsConnection() async throws {
        try await runSPKIPinningTest(
            useValidPin: true,
            policy: .strict,
            mode: .http1_1(tlsConfiguration: TestTLS.serverConfiguration)
        )
    }

    func testSPKIPinning_HTTP1_InvalidPin_RejectsConnection() async throws {
        try await runSPKIPinningTest(
            useValidPin: false,
            policy: .strict,
            mode: .http1_1(tlsConfiguration: TestTLS.serverConfiguration)
        )
    }

    func testSPKIPinning_HTTP1_ValidPin_AuditMode_AllowsConnection() async throws {
        try await runSPKIPinningTest(
            useValidPin: true,
            policy: .audit,
            mode: .http1_1(tlsConfiguration: TestTLS.serverConfiguration)
        )
    }

    func testSPKIPinning_HTTP1_InvalidPin_AuditMode_AllowsConnection() async throws {
        try await runSPKIPinningTest(
            useValidPin: false,
            policy: .audit,
            mode: .http1_1(tlsConfiguration: TestTLS.serverConfiguration)
        )
    }

    // MARK: - End-to-End Tests: Network.framework

    #if canImport(Network)
    func testSPKIPinning_NetworkFramework_ThrowsUnsupportedError() async throws {
        try XCTSkipUnless(isTestingNIOTS(), "Network.framework tests disabled")

        let certificate = TestTLS.certificate
        let spkiHash = SHA256.hash(data: Data(UUID().uuidString.utf8))
        let pinBase64 = Data(spkiHash).base64EncodedString()

        let tlsConfig = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(certificate)],
            privateKey: .privateKey(TestTLS.privateKey)
        )

        let bin = HTTPBin(.http2(tlsConfiguration: tlsConfig))
        defer { XCTAssertNoThrow(try bin.shutdown()) }

        var config = HTTPClient.Configuration().enableFastFailureModeForTesting()
        config.tlsConfiguration = TLSConfiguration.makeClientConfiguration()
        config.tlsConfiguration?.trustRoots = .certificates([certificate])

        config.tlsPinning = SPKIPinningConfiguration(
            pins: [try SPKIHash(algorithm: SHA256.self, base64: pinBase64)],
            policy: .strict
        )

        let eventLoopGroup = NIOTSEventLoopGroup(loopCount: 1, defaultQoS: .default)
        defer { XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully()) }

        let localClient = HTTPClient(
            eventLoopGroupProvider: .shared(eventLoopGroup),
            configuration: config
        )
        defer { XCTAssertNoThrow(try localClient.syncShutdown()) }

        let request = HTTPClientRequest(url: "https://localhost:\(bin.port)/get")

        do {
            _ = try await localClient.execute(request, deadline: .now() + .seconds(10))
            XCTFail("Expected error but request succeeded")
        } catch let error as SPKIPinningHandlerError {
            XCTAssertEqual(error, .networkFrameworkNotSupported)
        } catch {
            XCTFail("Expected SPKIPinningHandlerError.networkFrameworkNotSupported, received: \(type(of: error))")
        }
    }
    #endif

    // MARK: - Weak Pinning Warning

    /// Regression test: the weak-pinning warning used to be logged once per physical
    /// connection created by the pool, which spammed logs under connection churn. It must now
    /// be logged at most once per connection pool, regardless of how many connections it opens.
    func testSPKIPinning_WeakConfigWarning_LogsOnlyOncePerPool() async throws {
        let bin = HTTPBin(.http1_1(tlsConfiguration: TestTLS.serverConfiguration))
        defer { XCTAssertNoThrow(try bin.shutdown()) }

        let publicKey = try TestTLS.certificate.extractPublicKey()
        let spkiBytes = try publicKey.toSPKIBytes()
        let spkiHash = SHA256.hash(data: Data(spkiBytes))
        let pinBase64 = Data(spkiHash).base64EncodedString()

        var config = HTTPClient.Configuration().enableFastFailureModeForTesting()
        config.tlsConfiguration = TLSConfiguration.makeClientConfiguration()
        config.tlsConfiguration?.trustRoots = .certificates([TestTLS.certificate])
        config.tlsConfiguration?.certificateVerification = .noHostnameVerification
        // A single pin in `.strict` mode is what triggers the weak-pinning warning.
        config.tlsPinning = SPKIPinningConfiguration(
            pins: [try SPKIHash(algorithm: SHA256.self, base64: pinBase64)],
            policy: .strict
        )

        let (logStore, backgroundLogger) = InMemoryLogHandler.makeLogger(logLevel: .trace)

        let localClient = HTTPClient(
            eventLoopGroupProvider: .shared(MultiThreadedEventLoopGroup.singleton),
            configuration: config,
            backgroundActivityLogger: backgroundLogger
        )
        defer { XCTAssertNoThrow(try localClient.syncShutdown()) }

        // Two concurrent requests force the pool to open two separate physical connections,
        // each of which used to log the weak-pinning warning independently.
        async let first = localClient.execute(
            HTTPClientRequest(url: "https://localhost:\(bin.port)/get"),
            deadline: .now() + .seconds(10)
        )
        async let second = localClient.execute(
            HTTPClientRequest(url: "https://localhost:\(bin.port)/get"),
            deadline: .now() + .seconds(10)
        )
        _ = try await (first, second)

        let warnings = logStore.entries.filter { "\($0.message)".contains("catastrophic lockout") }
        XCTAssertEqual(warnings.count, 1, "Expected exactly one warning, got \(warnings.count): \(warnings)")
    }

    // MARK: - End-to-End Tests: HTTP Proxy

    func testSPKIPinning_HTTPProxy_ValidPin_AllowsConnection() throws {
        try runSPKIPinningProxyTest(useValidPin: true, policy: .strict)
    }

    func testSPKIPinning_HTTPProxy_InvalidPin_RejectsConnection() throws {
        try runSPKIPinningProxyTest(useValidPin: false, policy: .strict)
    }

    func testSPKIPinning_HTTPProxy_ValidPin_AuditMode_AllowsConnection() throws {
        try runSPKIPinningProxyTest(useValidPin: true, policy: .audit)
    }

    func testSPKIPinning_HTTPProxy_InvalidPin_AuditMode_AllowsConnection() throws {
        try runSPKIPinningProxyTest(useValidPin: false, policy: .audit)
    }

    // MARK: - End-to-End Tests: SOCKS Proxy

    func testSPKIPinning_SOCKSProxy_ValidPin_AllowsConnection() throws {
        try runSPKIPinningSOCKSProxyTest(useValidPin: true, policy: .strict)
    }

    func testSPKIPinning_SOCKSProxy_InvalidPin_RejectsConnection() throws {
        try runSPKIPinningSOCKSProxyTest(useValidPin: false, policy: .strict)
    }

    func testSPKIPinning_SOCKSProxy_ValidPin_AuditMode_AllowsConnection() throws {
        try runSPKIPinningSOCKSProxyTest(useValidPin: true, policy: .audit)
    }

    func testSPKIPinning_SOCKSProxy_InvalidPin_AuditMode_AllowsConnection() throws {
        try runSPKIPinningSOCKSProxyTest(useValidPin: false, policy: .audit)
    }

    // MARK: - Helpers

    private func makeHandler(config: SPKIPinningConfiguration) throws -> SPKIPinningHandler {
        let logger = Logger(label: "test", factory: SwiftLogNoOpLogHandler.init)
        return SPKIPinningHandler(tlsPinning: config, logger: logger)
    }

    private static func testCertificateAndSPKIHash() throws -> (NIOSSLCertificate, SHA256Digest) {
        let certificate = TestTLS.certificate
        let publicKey = try certificate.extractPublicKey()
        let spkiBytes = try publicKey.toSPKIBytes()
        let spkiHash = SHA256.hash(data: Data(spkiBytes))
        return (certificate, spkiHash)
    }

    private func runSPKIPinningTest(
        useValidPin: Bool,
        policy: SPKIPinningPolicy,
        mode: HTTPBin<HTTPBinHandler>.Mode,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let bin = HTTPBin(mode)
        defer { XCTAssertNoThrow(try bin.shutdown()) }

        let pinBase64: String
        if useValidPin {
            let publicKey = try TestTLS.certificate.extractPublicKey()
            let spkiBytes = try publicKey.toSPKIBytes()
            let spkiHash = SHA256.hash(data: Data(spkiBytes))
            pinBase64 = Data(spkiHash).base64EncodedString()
        } else {
            let spkiHash = SHA256.hash(data: Data(UUID().uuidString.utf8))
            pinBase64 = Data(spkiHash).base64EncodedString()
        }

        var config = HTTPClient.Configuration().enableFastFailureModeForTesting()
        config.tlsConfiguration = TLSConfiguration.makeClientConfiguration()
        config.tlsConfiguration?.trustRoots = .certificates([TestTLS.certificate])
        config.tlsConfiguration?.certificateVerification = .noHostnameVerification
        config.httpVersion = .automatic

        config.tlsPinning = SPKIPinningConfiguration(
            pins: [try SPKIHash(algorithm: SHA256.self, base64: pinBase64)],
            policy: policy
        )

        let localClient = HTTPClient(
            eventLoopGroupProvider: .shared(MultiThreadedEventLoopGroup.singleton),
            configuration: config
        )
        defer { XCTAssertNoThrow(try localClient.syncShutdown()) }

        let request = HTTPClientRequest(url: "https://localhost:\(bin.port)/get")

        let expectedVersion: HTTPVersion = {
            switch mode {
            case .http2:
                return .http2
            case .http1_1:
                return .http1_1
            case .refuse:
                return .http1_1
            }
        }()

        if useValidPin || policy == .audit {
            do {
                let response = try await localClient.execute(request, deadline: .now() + .seconds(10))
                XCTAssertEqual(response.status, .ok, file: file, line: line)
                XCTAssertEqual(response.version, expectedVersion, file: file, line: line)
            } catch {
                XCTFail("Unexpected error: \(error)", file: file, line: line)
            }
        } else {
            do {
                _ = try await localClient.execute(request, deadline: .now() + .seconds(10))
                XCTFail("Expected error but request succeeded", file: file, line: line)
            } catch let error as HTTPClientError {
                XCTAssertTrue(
                    error.description.contains("pinning") || error.description.contains("SPKI"),
                    "Unexpected error: \(error.description)",
                    file: file,
                    line: line
                )
            } catch {
                XCTFail("Expecting HTTPClientError, received: \(type(of: error))", file: file, line: line)
            }
        }
    }

    /// Exercises SPKI pinning for an HTTPS target reached through an HTTP proxy (`CONNECT` tunnel).
    ///
    /// The actual TLS handshake to the origin in this path is always performed by NIOSSL — even
    /// when the surrounding plain-text connection to the proxy itself is bootstrapped via
    /// Network.framework (the default transport on Apple platforms) — so pinning must succeed here
    /// exactly as it does for a direct, non-proxied HTTPS connection.
    private func runSPKIPinningProxyTest(
        useValidPin: Bool,
        policy: SPKIPinningPolicy,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let bin = HTTPBin(.http1_1(ssl: true), proxy: .simulate(authorization: nil))
        defer { XCTAssertNoThrow(try bin.shutdown()) }

        let pinBase64: String
        if useValidPin {
            let publicKey = try TestTLS.certificate.extractPublicKey()
            let spkiBytes = try publicKey.toSPKIBytes()
            let spkiHash = SHA256.hash(data: Data(spkiBytes))
            pinBase64 = Data(spkiHash).base64EncodedString()
        } else {
            let spkiHash = SHA256.hash(data: Data(UUID().uuidString.utf8))
            pinBase64 = Data(spkiHash).base64EncodedString()
        }

        var config = HTTPClient.Configuration(
            proxy: .server(host: "localhost", port: bin.port)
        ).enableFastFailureModeForTesting()
        config.tlsConfiguration = TLSConfiguration.makeClientConfiguration()
        config.tlsConfiguration?.trustRoots = .certificates([TestTLS.certificate])
        config.tlsConfiguration?.certificateVerification = .noHostnameVerification

        config.tlsPinning = SPKIPinningConfiguration(
            pins: [try SPKIHash(algorithm: SHA256.self, base64: pinBase64)],
            policy: policy
        )

        // Uses the platform default event loop group (NIOTS on Apple platforms) to exercise the
        // exact transport that previously caused proxied SPKI-pinned requests to fail spuriously.
        let eventLoopGroup = getDefaultEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully()) }

        let localClient = HTTPClient(
            eventLoopGroupProvider: .shared(eventLoopGroup),
            configuration: config
        )
        defer { XCTAssertNoThrow(try localClient.syncShutdown()) }

        if useValidPin || policy == .audit {
            var response: HTTPClient.Response?
            XCTAssertNoThrow(
                response = try localClient.get(url: "https://test/ok").wait(),
                file: file,
                line: line
            )
            XCTAssertEqual(response?.status, .ok, file: file, line: line)
        } else {
            XCTAssertThrowsError(try localClient.get(url: "https://test/ok").wait(), file: file, line: line) {
                error in
                guard let clientError = error as? HTTPClientError else {
                    XCTFail("Unexpected error: \(error)", file: file, line: line)
                    return
                }
                XCTAssertTrue(
                    clientError.description.contains("pinning") || clientError.description.contains("SPKI"),
                    "Unexpected error: \(clientError.description)",
                    file: file,
                    line: line
                )
            }
        }
    }

    /// Exercises SPKI pinning for an HTTPS target reached through a SOCKS proxy.
    ///
    /// Just like the HTTP `CONNECT` path, the TLS handshake to the origin here is always
    /// performed by NIOSSL regardless of which transport carries the plain-text tunnel to the
    /// SOCKS proxy, so pinning must succeed exactly as it does without a proxy.
    private func runSPKIPinningSOCKSProxyTest(
        useValidPin: Bool,
        policy: SPKIPinningPolicy,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let socksBin = try MockSOCKSServer(
            expectedURL: "/ok",
            expectedResponse: "it works!",
            tlsConfiguration: TestTLS.serverConfiguration
        )
        defer { XCTAssertNoThrow(try socksBin.shutdown()) }

        let pinBase64: String
        if useValidPin {
            let publicKey = try TestTLS.certificate.extractPublicKey()
            let spkiBytes = try publicKey.toSPKIBytes()
            let spkiHash = SHA256.hash(data: Data(spkiBytes))
            pinBase64 = Data(spkiHash).base64EncodedString()
        } else {
            let spkiHash = SHA256.hash(data: Data(UUID().uuidString.utf8))
            pinBase64 = Data(spkiHash).base64EncodedString()
        }

        var config = HTTPClient.Configuration(
            proxy: .socksServer(host: "localhost", port: socksBin.port)
        ).enableFastFailureModeForTesting()
        config.tlsConfiguration = TLSConfiguration.makeClientConfiguration()
        config.tlsConfiguration?.trustRoots = .certificates([TestTLS.certificate])
        config.tlsConfiguration?.certificateVerification = .noHostnameVerification

        config.tlsPinning = SPKIPinningConfiguration(
            pins: [try SPKIHash(algorithm: SHA256.self, base64: pinBase64)],
            policy: policy
        )

        // Uses the platform default event loop group (NIOTS on Apple platforms) to exercise the
        // exact transport that previously caused proxied SPKI-pinned requests to fail spuriously.
        let eventLoopGroup = getDefaultEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully()) }

        let localClient = HTTPClient(
            eventLoopGroupProvider: .shared(eventLoopGroup),
            configuration: config
        )
        defer { XCTAssertNoThrow(try localClient.syncShutdown()) }

        if useValidPin || policy == .audit {
            var response: HTTPClient.Response?
            XCTAssertNoThrow(
                response = try localClient.get(url: "https://test/ok").wait(),
                file: file,
                line: line
            )
            XCTAssertEqual(response?.status, .ok, file: file, line: line)
        } else {
            XCTAssertThrowsError(try localClient.get(url: "https://test/ok").wait(), file: file, line: line) {
                error in
                guard let clientError = error as? HTTPClientError else {
                    XCTFail("Unexpected error: \(error)", file: file, line: line)
                    return
                }
                XCTAssertTrue(
                    clientError.description.contains("pinning") || clientError.description.contains("SPKI"),
                    "Unexpected error: \(clientError.description)",
                    file: file,
                    line: line
                )
            }
        }
    }
}
