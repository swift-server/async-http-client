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

    func testContains_WithMatchingActivePin_ReturnsTrue() throws {
        let (certificate, spkiHash) = try Self.testCertificateAndSPKIHash()
        let pin = try SPKIHash(algorithm: SHA256.self, bytes: Data(spkiHash))
        let config = SPKIPinningConfiguration(
            activePins: [pin],
            backupPins: [],
            policy: .strict
        )

        let publicKey = try certificate.extractPublicKey()
        let spkiBytes = try publicKey.toSPKIBytes()

        XCTAssertTrue(config.contains(spkiBytes: spkiBytes))
    }

    func testContains_WithMatchingBackupPin_ReturnsTrue() throws {
        let (certificate, spkiHash) = try Self.testCertificateAndSPKIHash()
        let pin = try SPKIHash(algorithm: SHA256.self, bytes: Data(spkiHash))
        let config = SPKIPinningConfiguration(
            activePins: [],
            backupPins: [pin],
            policy: .strict
        )

        let publicKey = try certificate.extractPublicKey()
        let spkiBytes = try publicKey.toSPKIBytes()

        XCTAssertTrue(config.contains(spkiBytes: spkiBytes))
    }

    func testContains_WithMismatchedPin_ReturnsFalse() throws {
        let (certificate, _) = try Self.testCertificateAndSPKIHash()
        let mismatchedPin = try SPKIHash(base64: "9uO07DlRgCzpXEaC2+ZiqB0VFcjdn43d6h+U2lUHORo=")
        let config = SPKIPinningConfiguration(
            activePins: [mismatchedPin],
            backupPins: [],
            policy: .strict
        )

        let publicKey = try certificate.extractPublicKey()
        let spkiBytes = try publicKey.toSPKIBytes()

        XCTAssertFalse(config.contains(spkiBytes: spkiBytes))
    }

    func testContains_WithEmptyInput_ReturnsFalse() throws {
        let pin = try SPKIHash(base64: "9uO07DlRgCzpXEaC2+ZiqB0VFcjdn43d6h+U2lUHORo=")
        let config = SPKIPinningConfiguration(
            activePins: [pin],
            backupPins: [],
            policy: .strict
        )

        XCTAssertFalse(config.contains(spkiBytes: []))
    }

    // MARK: - SPKIPinningHandler.validateSPKI(...)

    func testValidateSPKI_WithValidActivePin_PropagatesEvent() throws {
        let (certificate, spkiHash) = try Self.testCertificateAndSPKIHash()
        let pin = try SPKIHash(algorithm: SHA256.self, bytes: Data(spkiHash))
        let config = SPKIPinningConfiguration(
            activePins: [pin],
            backupPins: [],
            policy: .strict
        )
        let handler = try makeHandler(config: config)
        let event = TLSUserEvent.handshakeCompleted(negotiatedProtocol: nil)

        let embedded = EmbeddedChannel(handlers: [ContextHandler { context in
            handler.validateSPKI(
                context: context,
                event: event,
                peerCertificate: .success(certificate)
            )
        }])

        embedded.pipeline.fireUserInboundEventTriggered(event)
        try embedded.throwIfErrorCaught()
    }

    func testValidateSPKI_WithValidBackupPin_PropagatesEvent() throws {
        let (certificate, spkiHash) = try Self.testCertificateAndSPKIHash()
        let pin = try SPKIHash(algorithm: SHA256.self, bytes: Data(spkiHash))
        let config = SPKIPinningConfiguration(
            activePins: [],
            backupPins: [pin],
            policy: .strict
        )
        let handler = try makeHandler(config: config)
        let event = TLSUserEvent.handshakeCompleted(negotiatedProtocol: nil)

        let embedded = EmbeddedChannel(handlers: [ContextHandler { context in
            handler.validateSPKI(
                context: context,
                event: event,
                peerCertificate: .success(certificate)
            )
        }])

        embedded.pipeline.fireUserInboundEventTriggered(event)
        try embedded.throwIfErrorCaught()
    }

    func testValidateSPKI_WithMismatchedPin_InStrictMode_ClosesConnection() throws {
        let (certificate, _) = try Self.testCertificateAndSPKIHash()
        let mismatchedPin = try SPKIHash(base64: "9uO07DlRgCzpXEaC2+ZiqB0VFcjdn43d6h+U2lUHORo=")
        let config = SPKIPinningConfiguration(
            activePins: [mismatchedPin],
            backupPins: [],
            policy: .strict
        )
        let handler = try makeHandler(config: config)
        let event = TLSUserEvent.handshakeCompleted(negotiatedProtocol: nil)

        let embedded = EmbeddedChannel(handlers: [ContextHandler { context in
            handler.validateSPKI(
                context: context,
                event: event,
                peerCertificate: .success(certificate)
            )
        }])

        embedded.pipeline.fireUserInboundEventTriggered(event)

        XCTAssertThrowsError(try embedded.throwIfErrorCaught()) {
            if let error = $0 as? HTTPClientError {
                XCTAssertTrue(error.description.contains("SPKI pin mismatch"))
            }
        }
    }

    func testValidateSPKI_WithMismatchedPin_InAuditMode_PropagatesEvent() throws {
        let (certificate, _) = try Self.testCertificateAndSPKIHash()
        let mismatchedPin = try SPKIHash(base64: "9uO07DlRgCzpXEaC2+ZiqB0VFcjdn43d6h+U2lUHORo=")
        let config = SPKIPinningConfiguration(
            activePins: [mismatchedPin],
            backupPins: [],
            policy: .audit
        )
        let handler = try makeHandler(config: config)
        let event = TLSUserEvent.handshakeCompleted(negotiatedProtocol: nil)

        let embedded = EmbeddedChannel(handlers: [ContextHandler { context in
            handler.validateSPKI(
                context: context,
                event: event,
                peerCertificate: .success(certificate)
            )
        }])

        embedded.pipeline.fireUserInboundEventTriggered(event)
        try embedded.throwIfErrorCaught()
    }

    func testValidateSPKI_WithNilCertificate_InStrictMode_ClosesConnection() throws {
        let pin = try SPKIHash(base64: "9uO07DlRgCzpXEaC2+ZiqB0VFcjdn43d6h+U2lUHORo=")
        let config = SPKIPinningConfiguration(
            activePins: [pin],
            backupPins: [],
            policy: .strict
        )
        let handler = try makeHandler(config: config)
        let event = TLSUserEvent.handshakeCompleted(negotiatedProtocol: nil)

        let embedded = EmbeddedChannel(handlers: [ContextHandler { context in
            handler.validateSPKI(
                context: context,
                event: event,
                peerCertificate: .success(nil)
            )
        }])

        embedded.pipeline.fireUserInboundEventTriggered(event)

        XCTAssertThrowsError(try embedded.throwIfErrorCaught()) {
            if let error = $0 as? HTTPClientError {
                XCTAssertTrue(error.description.contains("Empty certificate chain"))
            }
        }
    }

    func testValidateSPKI_WithNilCertificate_InAuditMode_PropagatesEvent() throws {
        let pin = try SPKIHash(base64: "9uO07DlRgCzpXEaC2+ZiqB0VFcjdn43d6h+U2lUHORo=")
        let config = SPKIPinningConfiguration(
            activePins: [pin],
            backupPins: [],
            policy: .audit
        )
        let handler = try makeHandler(config: config)
        let event = TLSUserEvent.handshakeCompleted(negotiatedProtocol: nil)

        let embedded = EmbeddedChannel(handlers: [ContextHandler { context in
            handler.validateSPKI(
                context: context,
                event: event,
                peerCertificate: .success(nil)
            )
        }])

        embedded.pipeline.fireUserInboundEventTriggered(event)
        try embedded.throwIfErrorCaught()
    }

    func testValidateSPKI_WithHandlerLookupFailure_InStrictMode_ClosesConnection() throws {
        let pin = try SPKIHash(base64: "9uO07DlRgCzpXEaC2+ZiqB0VFcjdn43d6h+U2lUHORo=")
        let config = SPKIPinningConfiguration(
            activePins: [pin],
            backupPins: [],
            policy: .strict
        )
        let handler = try makeHandler(config: config)
        let event = TLSUserEvent.handshakeCompleted(negotiatedProtocol: nil)
        let extractionError = NSError(domain: "TestError", code: 1, userInfo: nil)

        let embedded = EmbeddedChannel(handlers: [ContextHandler { context in
            handler.validateSPKI(
                context: context,
                event: event,
                peerCertificate: .failure(extractionError)
            )
        }])

        embedded.pipeline.fireUserInboundEventTriggered(event)

        XCTAssertThrowsError(try embedded.throwIfErrorCaught()) {
            if let error = $0 as? HTTPClientError {
                XCTAssertTrue(error.description.contains("SSL handler not found:"))
            }
        }
    }

    // MARK: - SPKIPinningHandler.userInboundEventTriggered(...)

    func testUserInboundEventTriggered_IgnoresNonHandshakeEvents() throws {
        let config = SPKIPinningConfiguration(
            activePins: [],
            backupPins: [],
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
            activePins: [],
            backupPins: [],
            policy: .strict
        )
        let handler = try makeHandler(config: config)
        let event = TLSUserEvent.handshakeCompleted(negotiatedProtocol: nil)

        let embedded = EmbeddedChannel(handlers: [handler])
        embedded.pipeline.fireUserInboundEventTriggered(event)

        XCTAssertThrowsError(try embedded.throwIfErrorCaught()) {
            if let error = $0 as? HTTPClientError {
                XCTAssertTrue(error.description.contains("SSL handler not found: notFound"))
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

private final class ContextHandler: ChannelInboundHandler {
    typealias InboundIn = NIOAny
    let context: (ChannelHandlerContext) -> Void

    init(context: @escaping (ChannelHandlerContext) -> Void) {
        self.context = context
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        self.context(context)
    }
}
