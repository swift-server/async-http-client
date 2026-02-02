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

/// Configuration for SPKI (SubjectPublicKeyInfo) pinning.
///
/// SPKI pinning validates the cryptographic identity of the server by hashing the
/// SubjectPublicKeyInfo structure (RFC 5280, Section 4.1) rather than the entire certificate.
///
/// Why SPKI instead of certificate pinning?
/// - ✅ Survives legitimate certificate rotations (same key, new expiration)
/// - ✅ Prevents downgrade attacks (algorithm identifier is included in the hash)
/// - ❌ Certificate pinning fails on routine renewals and provides false security
///
/// - Note: Despite the industry term "certificate pinning", cryptographic best practices
///   (OWASP MSTG, NIST SP 800-52 Rev. 2) mandate SPKI-based pinning.
/// - Warning: Always deploy with non-empty `backupPins` to avoid lockout during rotation.
/// - SeeAlso: https://datatracker.ietf.org/doc/html/rfc5280#section-4.1
/// - SeeAlso: https://owasp.org/www-project-mobile-security-testing-guide/latest/0x05g-Testing-Network-Communication.html
public struct SPKIPinningConfiguration: Sendable, Hashable {
    /// Base64-encoded SHA-256 hashes of current production SPKI values.
    public var primaryPins: Set<String>

    /// Base64-encoded SHA-256 hashes for upcoming certificate rotations.
    /// Required in production to prevent catastrophic lockout.
    public var backupPins: Set<String>

    /// Failure behavior policy on pin mismatch.
    public var verification: SPKIPinningVerification

    /// Creates an SPKI pinning configuration with primary and backup pins.
    ///
    /// - Parameters:
    ///   - primaryPins: Base64-encoded SHA-256 hashes of the current production certificate's
    ///                  SubjectPublicKeyInfo. These pins are actively validated against incoming
    ///                  connections.
    ///   - backupPins: Base64-encoded SHA-256 hashes for certificates scheduled for future deployment.
    ///                 Required in production environments to prevent service disruption during
    ///                 certificate rotation. Must contain at least one pin when using
    ///                 `.failRequest` verification mode.
    ///   - verification: Policy for handling pin validation failures. Use `.failRequest` for
    ///                   production (security-critical) environments and `.logAndProceed` only for
    ///                   staging/debugging.
    ///
    /// - Warning: Deploying with empty `backupPins` in `.failRequest` mode risks catastrophic
    ///   lockout when certificates rotate. Always deploy backup pins at least 30 days before
    ///   certificate expiration.
    ///
    /// - Important: Hashes must be generated from the SPKI structure (not the full certificate)
    ///   using SHA-256 and Base64 encoding. Example OpenSSL command:
    ///   ```
    ///   openssl s_client -connect example.com:443 -servername example.com 2>/dev/null | \
    ///     openssl x509 -pubkey -noout | \
    ///     openssl pkey -pubin -outform der | \
    ///     openssl dgst -sha256 -binary | \
    ///     openssl base64 -A
    ///   ```
    public init(
        primaryPins: Set<String>,
        backupPins: Set<String>,
        verification: SPKIPinningVerification = .failRequest
    ) {
        self.primaryPins = primaryPins
        self.backupPins = backupPins
        self.verification = verification
    }
}

/// Defines the behavior when SPKI pin validation fails.
///
/// Pinning failures indicate the server presented a certificate with an unexpected public key.
/// This typically occurs during certificate rotation (expected) or MITM attacks (malicious).
/// The verification policy determines whether to block the connection or allow it with warnings.
public enum SPKIPinningVerification: Sendable, Hashable {
    /// Immediately terminate the connection on pin validation failure.
    ///
    /// Use this policy in production environments where security is paramount.
    /// Connections will fail if:
    /// - Certificate was rotated without deploying corresponding backup pins
    /// - Server presents unexpected certificate (potential MITM attack)
    /// - Network interception by corporate proxies/security appliances
    ///
    /// - Warning: Deploy only with valid backup pins to avoid service disruption during rotation.
    case failRequest

    /// Allow the connection to proceed but log a structured warning.
    ///
    /// Use this policy exclusively in staging, development, or debugging environments.
    /// Never use in production — this effectively disables pinning security guarantees.
    ///
    /// - Warning: This mode provides auditability without security enforcement.
    ///            Connections proceed even with unexpected certificates.
    case logAndProceed
}

/// A ChannelHandler that implements certificate pinning using SPKI (SubjectPublicKeyInfo) hashes.
///
/// This handler validates the server's leaf certificate public key against a set of pre-configured
/// SHA-256 hashes after TLS handshake completion. Pinning provides protection against compromised
/// Certificate Authorities by enforcing explicit trust in specific public keys.
///
/// - Warning: Never deploy without backup pins in production environments. Missing backup pins
///   risk catastrophic lockout during certificate rotation.
/// - SeeAlso: OWASP MSTG-NETWORK-4, NIST SP 800-52 Rev. 2 Section 3.4.3
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
final class SPKIPinningHandler: ChannelInboundHandler, RemovableChannelHandler {

    typealias InboundIn = NIOAny

    private let logger: Logger
    private let validPins: Set<Data>
    private let backupPins: Set<Data>
    private let verification: SPKIPinningVerification

    /// Creates a pinning handler with SHA-256 hashes of SPKI structures.
    ///
    /// - Parameters:
    ///   - primaryPins: Base64-encoded SHA-256 hashes of current production SPKI values.
    ///   - backupPins: Base64-encoded SHA-256 hashes for upcoming certificate rotations.
    ///                  Required in production to prevent lockout during certificate renewal.
    ///   - verification: Failure behavior policy:
    ///                   - `.failRequest`: Immediately terminate connections with invalid pins (production)
    ///                   - `.logAndProceed`: Allow connection but log warning (staging/debugging only)
    ///   - logger: Structured logger for audit trails and monitoring integration.
    ///
    /// - Warning: Production deployments must include non-empty backupPins. Certificate rotation
    ///   without pre-deployed backup pins will cause complete service outage.
    /// - SeeAlso: https://owasp.org/www-project-mobile-security-testing-guide/latest/0x05g-Testing-Network-Communication.html
    init(
        primaryPins: Set<String>,
        backupPins: Set<String> = [],
        verification: SPKIPinningVerification,
        logger: Logger
    ) {
        self.validPins = Set(primaryPins.compactMap {
            Data(base64Encoded: $0)
        })
        self.backupPins = Set(backupPins.compactMap {
            Data(base64Encoded: $0)
        })
        self.verification = verification
        self.logger = logger

        if backupPins.isEmpty && verification == .failRequest {
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
                        receivedSPKIHash: nil,
                        event: event
                    )
                    return
                }

                do {
                    let publicKey = try leaf.extractPublicKey()
                    let spkiBytes = try publicKey.toSPKIBytes()
                    let receivedHash = Data(SHA256.hash(data: spkiBytes))

                    self.validPins.forEach {
                        print($0.base64EncodedString())
                    }

                    let isValid = self.validPins.contains(receivedHash) ||
                                  self.backupPins.contains(receivedHash)

                    if isValid {
                        context.fireUserInboundEventTriggered(event)
                        self.logger.debug(
                            "SPKI pin validation succeeded",
                            metadata: [
                                "spki_hash": .string(receivedHash.base64EncodedString()),
                                "matched_type": .string(self.validPins.contains(receivedHash) ? "primary" : "backup")
                            ]
                        )
                    } else {
                        self.handlePinningFailure(
                            context: context,
                            reason: "SPKI pin mismatch",
                            receivedSPKIHash: receivedHash,
                            event: event
                        )
                    }

                } catch {
                    self.handlePinningFailure(
                        context: context,
                        reason: "SPKI extraction failed: \(error)",
                        receivedSPKIHash: nil,
                        event: event
                    )
                }

            case .failure(let error):
                self.handlePinningFailure(
                    context: context,
                    reason: "SSL handler not found: \(error)",
                    receivedSPKIHash: nil,
                    event: event
                )
            }
        }
    }

    private func handlePinningFailure(
        context: ChannelHandlerContext,
        reason: String,
        receivedSPKIHash: Data?,
        event: TLSUserEvent
    ) {
        let metadata: Logger.Metadata = [
            "pinning_action": .string(verification == .failRequest ? "blocked" : "allowed_with_warning"),
            "received_spki_hash": .string(receivedSPKIHash?.base64EncodedString() ?? "unknown"),
            "expected_primary_pins": .string(validPins.map { $0.base64EncodedString() }.joined(separator: ", ")),
            "expected_backup_pins": .string(backupPins.map { $0.base64EncodedString() }.joined(separator: ", "))
        ]

        switch verification {
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

private enum PinningError: Error {
    case publicKeyExtractionFailed
    case spkiSerializationFailed
}
