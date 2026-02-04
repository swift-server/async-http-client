//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2021 Apple Inc. and the AsyncHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Crypto
import XCTest
import NIOSSL
import NIOTLS
import Logging
import NIOCore
import NIOEmbedded

@testable import AsyncHTTPClient

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
        XCTAssertTrue((error as? SPKIPinningHandlerError)?.description.contains("SSL handler not found:") == true)
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
        XCTAssertTrue((error as? SPKIPinningHandlerError)?.description.contains("SSL handler not found:") == true)
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
                XCTAssertTrue(error.description.contains("SSL handler not found:"))
            }
        }
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
}

final class MockSPKIPinningExecutor: SPKIPinningExecutor {

    var propagateCallCount = 0
    var lastPropagatedEvent: TLSUserEvent?
    var auditWarningLogged = false
    var lastLoggedError: Error?
    var closeCallCount = 0

    func propagateHandshakeEvent(context: ChannelHandlerContext, event: TLSUserEvent) {
        propagateCallCount += 1
        lastPropagatedEvent = event
    }

    func logAuditWarning(logger: Logger, error: Error, policy: SPKIPinningPolicy) {
        auditWarningLogged = true
        lastLoggedError = error
    }

    func logErrorAndClose(context: ChannelHandlerContext, logger: Logger, error: Error, tlsPinning: SPKIPinningConfiguration) {
        closeCallCount += 1
        lastLoggedError = error
    }
}
