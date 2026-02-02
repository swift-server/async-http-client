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

/// A hash of a SubjectPublicKeyInfo (SPKI) structure for certificate pinning.
///
/// Validates server identity by hashing the DER-encoded public key structure
/// (RFC 5280, Section 4.1) rather than the full certificate. This approach:
/// - Survives legitimate certificate rotations (same key, new expiration)
/// - Prevents algorithm downgrade attacks
/// - Provides stronger security guarantees than full-certificate pinning
///
/// Equality considers both digest bytes and hash algorithm — hashes with identical
/// bytes but different algorithms (e.g., SHA-256 vs SHA-384) are distinct values.
///
/// - SeeAlso: https://datatracker.ietf.org/doc/html/rfc5280#section-4.1
/// - SeeAlso: https://owasp.org/www-project-mobile-security-testing-guide/latest/0x05g-Testing-Network-Communication.html
public struct SPKIHash: Sendable, Hashable {

    /// The raw hash digest bytes of the SPKI structure.
    public let bytes: Data

    fileprivate let algorithmID: ObjectIdentifier
    private let algorithm: @Sendable (Data) -> any Sequence<UInt8>

    // MARK: - Initialization

    /// Creates an SPKI hash from a base64-encoded string using SHA-256.
    ///
    /// - Parameters:
    ///   - base64: Base64-encoded hash digest. Whitespace is automatically stripped.
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
/// Always iterates all candidates and bytes regardless of match position.
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

/// Configuration for SPKI (SubjectPublicKeyInfo) pinning.
///
/// Validates server identity by hashing the public key structure rather than the
/// full certificate. Supports multiple hash algorithms simultaneously.
///
/// - Warning: Always deploy with non-empty `backupPins` to avoid lockout during rotation.
public struct SPKIPinningConfiguration: Sendable, Hashable {
    /// Current production SPKI hashes.
    public let primaryPins: [SPKIHash]

    /// SPKI hashes for upcoming certificate rotations.
    public let backupPins: [SPKIHash]

    /// Failure behavior policy on pin mismatch.
    public let verification: SPKIPinningVerification

    private let pinsByAlgorithm: [ObjectIdentifier: [SPKIHash]]

    /// Creates an SPKI pinning configuration with primary and backup pins.
    ///
    /// - Parameters:
    ///   - primaryPins: Hashes of current production certificates.
    ///   - backupPins: Hashes for certificates scheduled for future deployment.
    ///                 Required in production to prevent service disruption during rotation.
    ///   - verification: Policy for handling pin validation failures.
    ///
    /// - Warning: Deploying with empty `backupPins` in `.failRequest` mode risks
    ///   catastrophic lockout when certificates rotate.
    public init(
        primaryPins: [SPKIHash],
        backupPins: [SPKIHash],
        verification: SPKIPinningVerification = .failRequest
    ) {
        self.primaryPins = primaryPins
        self.backupPins = backupPins
        self.pinsByAlgorithm = Dictionary(grouping: Set(primaryPins + backupPins), by: \.algorithmID)
        self.verification = verification
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

/// Behavior when SPKI pin validation fails.
public enum SPKIPinningVerification: Sendable, Hashable {
    /// Immediately terminate the connection on pin validation failure.
    case failRequest

    /// Allow the connection to proceed but log a warning.
    case logAndProceed
}

/// ChannelHandler that implements certificate pinning using SPKI hashes.
///
/// Validates the server's leaf certificate public key against pre-configured hashes
/// after TLS handshake completion.
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

        if tlsPinning.backupPins.isEmpty && tlsPinning.verification == .failRequest {
            logger.warning(
                "SPKIPinningHandler deployed without backup pins in failRequest mode - catastrophic lockout risk!",
                metadata: [
                    "recommendation": .string("Deploy backup pins 30+ days before certificate expiration")
                ]
            )
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        guard let tlsEvent = event as? TLSUserEvent,
              case .handshakeCompleted = tlsEvent else {
            context.fireUserInboundEventTriggered(event)
            return
        }

        validateSPKI(context: context, event: tlsEvent)
    }

    private func validateSPKI(context: ChannelHandlerContext, event: TLSUserEvent) {
        context.channel.pipeline.handler(type: NIOSSLHandler.self).assumeIsolated().whenComplete { result in
            switch result {
            case .success(let sslHandler):
                guard let leaf = sslHandler.peerCertificate else {
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
    }

    private func handlePinningFailure(
        context: ChannelHandlerContext,
        reason: String,
        event: TLSUserEvent
    ) {
        let metadata: Logger.Metadata = [
            "pinning_action": .string(tlsPinning.verification == .failRequest ? "blocked" : "allowed_with_warning"),
            "expected_primary_pins": .string(tlsPinning.primaryPins.map { $0.bytes.base64EncodedString() }.joined(separator: ", ")),
            "expected_backup_pins": .string(tlsPinning.backupPins.map { $0.bytes.base64EncodedString() }.joined(separator: ", "))
        ]

        switch tlsPinning.verification {
        case .failRequest:
            logger.error("SPKI pinning failed — connection blocked", metadata: metadata)

            let error = HTTPClientError.invalidCertificatePinning(reason)
            context.fireErrorCaught(error)

            context.close(mode: .all, promise: nil)

        case .logAndProceed:
            logger.warning("SPKI pinning failed — connection allowed (staging mode)", metadata: metadata)
            context.fireUserInboundEventTriggered(event)
        }
    }
}
