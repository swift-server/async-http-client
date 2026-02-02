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

import Foundation
import NIOCore
import NIOTLS
import NIOSSL
import Logging
import Crypto
import Algorithms

/// SPKI hash for certificate pinning validation.
///
/// Validates server identity using the DER-encoded public key structure (RFC 5280, Section 4.1)
/// rather than the full certificate. This approach survives legitimate certificate rotations
/// and prevents algorithm downgrade attacks.
///
/// Equality considers both digest bytes and hash algorithm — hashes with identical bytes
/// but different algorithms are distinct values.
///
/// - SeeAlso: https://datatracker.ietf.org/doc/html/rfc5280#section-4.1
/// - SeeAlso: https://owasp.org/www-project-mobile-security-testing-guide/latest/0x05g-Testing-Network-Communication.html
public struct SPKIHash: Sendable, Hashable {

    /// Raw hash digest bytes of the SPKI structure.
    public let bytes: Data

    fileprivate let algorithmID: ObjectIdentifier
    private let algorithm: @Sendable (Data) -> any Sequence<UInt8>

    // MARK: - Initialization

    /// Creates an SPKI hash from a base64-encoded SHA-256 digest.
    ///
    /// - Parameters:
    ///   - base64: Base64-encoded hash digest (whitespace is stripped).
    ///
    /// - Throws: `HTTPClientError.invalidDigestLength` if decoded data isn't 32 bytes.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public init(base64: String) throws {
        guard let data = Data(base64Encoded: base64) else {
            throw HTTPClientError.invalidDigestLength
        }
        try self.init(algorithm: SHA256.self, bytes: data)
    }

    /// Creates an SPKI hash using a custom hash algorithm and base64-encoded string.
    ///
    /// - Parameters:
    ///   - algorithm: Hash algorithm used to generate the digest.
    ///   - base64: Base64-encoded hash digest.
    ///
    /// - Throws: `HTTPClientError.invalidDigestLength` if length doesn't match algorithm.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public init<Algorithm: HashFunction>(algorithm: Algorithm.Type, base64: String) throws {
        guard let data = Data(base64Encoded: base64) else {
            throw HTTPClientError.invalidDigestLength
        }
        try self.init(algorithm: algorithm, bytes: data)
    }

    /// Creates an SPKI hash from raw SHA-256 digest bytes.
    ///
    /// - Parameters:
    ///   - bytes: Raw SHA-256 digest bytes (must be 32 bytes).
    ///
    /// - Throws: `HTTPClientError.invalidDigestLength` if byte count isn't 32.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public init(bytes: Data) throws {
        try self.init(algorithm: SHA256.self, bytes: bytes)
    }

    /// Creates an SPKI hash from raw digest bytes using a specified hash algorithm.
    ///
    /// - Parameters:
    ///   - algorithm: Hash algorithm that generated the digest bytes.
    ///   - bytes: Raw digest bytes.
    ///
    /// - Throws: `HTTPClientError.invalidDigestLength` if byte count doesn't match algorithm.
    @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
    public init<Algorithm: HashFunction>(algorithm: Algorithm.Type, bytes: Data) throws {
        guard bytes.count == Algorithm.Digest.byteCount else {
            throw HTTPClientError.invalidDigestLength
        }
        self.bytes = bytes
        self.algorithm = Algorithm.hash(data:)
        self.algorithmID = .init(algorithm)
    }

    // MARK: - Equality and Hashing

    public static func ==(lhs: Self, rhs: Self) -> Bool {
        lhs.bytes == rhs.bytes && lhs.algorithmID == rhs.algorithmID
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(bytes)
        hasher.combine(algorithmID)
    }

    fileprivate func hash(_ spkiData: Data) -> Data {
        Data(algorithm(spkiData))
    }
}

/// Constant-time comparison to prevent timing attacks.
internal func constantTimeAnyMatch(_ target: Data, _ candidates: [SPKIHash]) -> Bool {
    guard !candidates.isEmpty else { return false }

    var anyMatch: UInt8 = 0
    for candidate in candidates {
        var diff: UInt8 = 0
        for (a, b) in zip(target, candidate.bytes) {
            diff |= a ^ b
        }
        anyMatch |= (diff == 0) ? 1 : 0
    }
    return anyMatch != 0
}

/// Configuration for SPKI pinning validation.
///
/// Maintains two pin sets:
/// - `activePins`: Certificates currently deployed in production
/// - `backupPins`: Pre-deployed hashes for upcoming certificate rotations
///
/// - Warning: Always deploy non-empty `backupPins` at least 30 days before certificate
///   expiration to prevent service disruption during rotation.
public struct SPKIPinningConfiguration: Sendable, Hashable {
    /// SPKI hashes of certificates currently deployed in production.
    public let activePins: [SPKIHash]

    /// SPKI hashes pre-deployed for upcoming certificate rotations.
    public let backupPins: [SPKIHash]

    /// Policy for handling pin validation failures.
    public let policy: SPKIPinningPolicy

    private let pinsByAlgorithm: [ObjectIdentifier: [SPKIHash]]

    /// Creates an SPKI pinning configuration.
    ///
    /// - Parameters:
    ///   - activePins: Hashes of currently deployed certificates.
    ///   - backupPins: Hashes for upcoming certificate rotations (required in production).
    ///   - policy: Validation failure policy (`.strict` for production, `.audit` for debugging).
    ///
    /// - Warning: Empty `backupPins` in `.strict` mode risks catastrophic lockout during
    ///   certificate rotation.
    public init(
        activePins: [SPKIHash],
        backupPins: [SPKIHash],
        policy: SPKIPinningPolicy = .strict
    ) {
        self.activePins = activePins
        self.backupPins = backupPins
        self.pinsByAlgorithm = Dictionary(grouping: Set(activePins + backupPins), by: \.algorithmID)
        self.policy = policy
    }

    internal func contains(spkiBytes: [UInt8]) -> Bool {
        let spkiData = Data(spkiBytes)

        var anyMatch: UInt8 = 0
        for hashes in pinsByAlgorithm.values {
            guard let first = hashes.first else { continue }
            let computedHash = first.hash(spkiData)
            let isMatch = constantTimeAnyMatch(computedHash, hashes)
            anyMatch |= isMatch ? 1 : 0
        }
        return anyMatch != 0
    }
}

/// Policy for handling SPKI pin validation failures.
public enum SPKIPinningPolicy: Sendable, Hashable {
    /// Reject connections with untrusted certificates.
    case strict

    /// Permit connections with untrusted certificates for observability only.
    case audit
}

/// ChannelHandler that validates server certificates using SPKI pinning.
///
/// - Warning: Never deploy without backup pins in production environments.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
final class SPKIPinningHandler: ChannelInboundHandler, RemovableChannelHandler {

    typealias InboundIn = NIOAny

    private let tlsPinning: SPKIPinningConfiguration
    private let logger: Logger

    init(
        tlsPinning: SPKIPinningConfiguration,
        logger: Logger
    ) {
        self.tlsPinning = tlsPinning
        self.logger = logger

        if tlsPinning.backupPins.isEmpty && tlsPinning.policy == .strict {
            logger.warning(
                "SPKIPinningHandler deployed without backup pins in strict mode - catastrophic lockout risk!",
                metadata: [
                    "recommendation": .string("Deploy backup pins 30+ days before certificate expiration")
                ]
            )
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        guard
            let tlsEvent = event as? TLSUserEvent,
            case .handshakeCompleted = tlsEvent
        else {
            context.fireUserInboundEventTriggered(event)
            return
        }

        context.pipeline.handler(type: NIOSSLHandler.self).assumeIsolated().whenComplete {
            self.validateSPKI(
                context: context,
                event: tlsEvent,
                peerCertificate: $0.map(\.peerCertificate)
            )
        }
    }

    func validateSPKI(
        context: ChannelHandlerContext,
        event: TLSUserEvent,
        peerCertificate result: Result<NIOSSLCertificate?, Error>
    ) {
        switch result {
        case .success(let peerCertificate):
            guard let leaf = peerCertificate else {
                self.handlePinningFailure(
                    context: context,
                    reason: "Empty certificate chain",
                    event: event
                )
                return
            }

            do {
                let publicKey = try leaf.extractPublicKey()
                let spkiBytes = try publicKey.toSPKIBytes()

                let isValid = self.tlsPinning.contains(spkiBytes: spkiBytes)

                if isValid {
                    context.fireUserInboundEventTriggered(event)
                    self.logger.debug("SPKI pin validation succeeded")
                } else {
                    self.handlePinningFailure(
                        context: context,
                        reason: "SPKI pin mismatch",
                        event: event
                    )
                }

            } catch {
                self.handlePinningFailure(
                    context: context,
                    reason: "SPKI extraction failed: \(error)",
                    event: event
                )
            }

        case .failure(let error):
            self.handlePinningFailure(
                context: context,
                reason: "SSL handler not found: \(error)",
                event: event
            )
        }
    }

    private func handlePinningFailure(
        context: ChannelHandlerContext,
        reason: String,
        event: TLSUserEvent
    ) {
        let metadata: Logger.Metadata = [
            "pinning_action": .string(tlsPinning.policy == .strict ? "blocked" : "allowed_for_audit"),
            "expected_active_pins": .string(tlsPinning.activePins.map { $0.bytes.base64EncodedString() }.joined(separator: ", ")),
            "expected_backup_pins": .string(tlsPinning.backupPins.map { $0.bytes.base64EncodedString() }.joined(separator: ", "))
        ]

        switch tlsPinning.policy {
        case .strict:
            logger.error("SPKI pinning failed — connection blocked", metadata: metadata)

            let error = HTTPClientError.invalidCertificatePinning(reason)
            context.fireErrorCaught(error)

            context.close(promise: nil)

        case .audit:
            logger.warning("SPKI pinning failed — connection allowed for audit purposes", metadata: metadata)
            context.fireUserInboundEventTriggered(event)
        }
    }
}
