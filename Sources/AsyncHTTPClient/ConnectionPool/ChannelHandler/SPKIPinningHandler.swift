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
/// Validates server identity using the DER-encoded public key structure (RFC 5280, Section 4.1).
/// Survives legitimate certificate rotations and prevents algorithm downgrade attacks.
///
/// Equality requires matching digest bytes *and* hash algorithm. Length mismatches are treated
/// as inequality — critical for constant-time security guarantees.
///
/// - SeeAlso: https://datatracker.ietf.org/doc/html/rfc5280#section-4.1
/// - SeeAlso: https://owasp.org/www-project-mobile-security-testing-guide/latest/0x05g-Testing-Network-Communication.html
public struct SPKIHash: Sendable, Hashable {

    /// Raw hash digest bytes of the SPKI structure.
    public let bytes: Data

    fileprivate let algorithmID: ObjectIdentifier
    private let algorithm: @Sendable (Data) -> any Sequence<UInt8>

    // MARK: - Initialization

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

/// Constant-time digest comparison preventing timing attacks.
///
/// Compares digests without truncation — length mismatches and byte differences are incorporated
/// into a single constant-time result. Prevents false positives from partial matches (e.g., SHA-256
/// vs SHA-1).
///
/// - Warning: Never use truncating comparisons (like `zip`) for cryptographic equality — they
///   silently accept partial matches.
internal func constantTimeAnyMatch(_ target: Data, _ candidates: [SPKIHash]) -> Bool {
    guard !candidates.isEmpty else { return false }

    var anyMatch: UInt8 = 0
    for candidate in candidates {
        var diff: UInt8 = (target.count == candidate.bytes.count) ? 0 : 1

        let maxLength = max(target.count, candidate.bytes.count)
        for i in 0 ..< maxLength {
            let a = i < target.count ? target[i] : 0
            let b = i < candidate.bytes.count ? candidate.bytes[i] : 0
            diff |= a ^ b
        }

        anyMatch |= (diff == 0) ? 1 : 0
    }
    return anyMatch != 0
}

/// Configuration for SPKI pinning validation.
///
/// - Warning: Always deploy backup pins ≥ 30 days before certificate expiration. Empty pin sets
///   in `.strict` mode will reject all connections during rotation.
public struct SPKIPinningConfiguration: Sendable, Hashable {
    /// SPKI hashes of trusted certificates.
    public let pins: [SPKIHash]

    /// Policy for handling pin validation failures.
    public let policy: SPKIPinningPolicy

    private let pinsByAlgorithm: [ObjectIdentifier: [SPKIHash]]

    /// Creates an SPKI pinning configuration.
    ///
    /// - Parameters:
    ///   - pins: Hashes of trusted certificates (must not be empty in production).
    ///   - policy: Validation failure policy (`.strict` for production, `.audit` for debugging).
    public init(
        pins: [SPKIHash],
        policy: SPKIPinningPolicy = .strict
    ) {
        self.pins = pins
        self.pinsByAlgorithm = Dictionary(grouping: Set(pins), by: \.algorithmID)
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
///
/// SPKI pinning can fail due to certificate mismatch, invalid SPKI extraction, or missing SSL handler.
/// This policy determines whether the connection proceeds or is terminated.
public struct SPKIPinningPolicy: Sendable, Hashable {

    /// Permit connections with untrusted certificates for observability only.
    public static let audit = SPKIPinningPolicy(name: "audit", rawValue: 1 << 0)

    /// Reject connections with untrusted certificates.
    public static let strict = SPKIPinningPolicy(name: "strict", rawValue: 1 << 1)

    public var description: String {
        return name
    }

    private let name: String
    private let rawValue: UInt8

    private init(name: String, rawValue: UInt8) {
        self.name = name
        self.rawValue = rawValue
    }
}

/// ChannelHandler that validates server certificates using SPKI pinning.
///
/// Performs constant-time comparison of the server's public key hash against trusted pins.
/// Rejects connections in `.strict` mode on mismatch; permits in `.audit` mode for observability.
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
final class SPKIPinningHandler: ChannelInboundHandler, RemovableChannelHandler {

    typealias InboundIn = NIOAny

    private let tlsPinning: SPKIPinningConfiguration
    private let logger: Logger
    private let executor: SPKIPinningExecutor

    init(
        tlsPinning: SPKIPinningConfiguration,
        logger: Logger,
        executor: SPKIPinningExecutor = DefaultSPKIPinningExecutor()
    ) {
        self.tlsPinning = tlsPinning
        self.logger = logger
        self.executor = executor

        if tlsPinning.pins.count < 2 && tlsPinning.policy == .strict {
            logger.warning(
                "SPKIPinningHandler deployed with < 2 pins in strict mode — catastrophic lockout risk on certificate rotation!",
                metadata: [
                    "current_pin_count": .stringConvertible(tlsPinning.pins.count),
                    "recommendation": .string("Deploy backup pins ≥ 30 days before certificate expiration")
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

        // ⚠️ Security-critical: handshake propagation is delayed until validation completes
        context.pipeline.handler(type: NIOSSLHandler.self).assumeIsolated().whenComplete {
            let result = self.validatePinning(for: $0.map(\.peerCertificate))

            switch result {
            case .accepted:
                self.executor.propagateHandshakeEvent(context: context, event: tlsEvent)

            case .auditWarning(let error):
                self.executor.logAuditWarning(logger: self.logger, error: error, policy: self.tlsPinning.policy)
                self.executor.propagateHandshakeEvent(context: context, event: tlsEvent)

            case .rejected(let error):
                self.executor.logErrorAndClose(context: context, logger: self.logger, error: error, tlsPinning: self.tlsPinning)
            }
        }
    }

    func validatePinning(for peerCertificate: Result<NIOSSLCertificate?, Error>) -> PinningValidationResult {
        switch peerCertificate {
        case .success(let peerCertificate):
            guard let leaf = peerCertificate else {
                let error = SPKIPinningHandlerError.emptyCertificateChain
                return tlsPinning.policy == .audit
                ? .auditWarning(error)
                : .rejected(error)
            }

            let spkiBytes: [UInt8]
            do {
                let publicKey = try leaf.extractPublicKey()
                spkiBytes = try publicKey.toSPKIBytes()
            } catch {
                let error = SPKIPinningHandlerError.extractionFailed(String(describing: error))
                return tlsPinning.policy == .audit
                ? .auditWarning(error)
                : .rejected(error)
            }

            if tlsPinning.contains(spkiBytes: spkiBytes) {
                return .accepted
            }

            let error = SPKIPinningHandlerError.pinMismatch
            return tlsPinning.policy == .audit
            ? .auditWarning(error)
            : .rejected(error)

        case .failure(let error):
            let handlerError = SPKIPinningHandlerError.handlerNotFound(String(describing: error))
            return tlsPinning.policy == .audit
            ? .auditWarning(handlerError)
            : .rejected(handlerError)
        }
    }
}

protocol SPKIPinningExecutor {
    func propagateHandshakeEvent(context: ChannelHandlerContext, event: TLSUserEvent)
    func logAuditWarning(logger: Logger, error: Error, policy: SPKIPinningPolicy)
    func logErrorAndClose(context: ChannelHandlerContext, logger: Logger, error: Error, tlsPinning: SPKIPinningConfiguration)
}

struct DefaultSPKIPinningExecutor: SPKIPinningExecutor {

    func propagateHandshakeEvent(context: ChannelHandlerContext, event: TLSUserEvent) {
        context.fireUserInboundEventTriggered(event)
    }

    func logAuditWarning(logger: Logger, error: Error, policy: SPKIPinningPolicy) {
        logger.warning(
            "SPKI pinning failed — connection allowed for audit purposes",
            metadata: [
                "error": .string(String(describing: error)),
                "policy": .string(policy.description)
            ]
        )
    }

    func logErrorAndClose(context: ChannelHandlerContext, logger: Logger, error: Error, tlsPinning: SPKIPinningConfiguration) {
        let metadata: Logger.Metadata = [
            "policy": .string(tlsPinning.policy.description),
            "expected_pins": .string(
                tlsPinning.pins.map { $0.bytes.base64EncodedString() }.joined(separator: ", ")
            )
        ]

        logger.error("SPKI pinning failed — connection blocked", metadata: metadata)

        let error = HTTPClientError.invalidCertificatePinning(String(describing: error))
        context.fireErrorCaught(error)
        context.close(promise: nil)
    }
}

/// Result of SPKI pinning validation — decoupled from pipeline side effects.
enum PinningValidationResult {
    /// Pin matched or audit mode allowed mismatch — propagate handshake event.
    case accepted

    /// Pin mismatch in strict mode or critical error — close connection.
    case rejected(Error)

    /// Pin mismatch in audit mode — propagate with warning (still accepted).
    case auditWarning(Error)
}

enum SPKIPinningHandlerError: Error, CustomStringConvertible {

    case emptyCertificateChain
    case pinMismatch
    case extractionFailed(String)
    case handlerNotFound(String)

    var description: String {
        switch self {
        case .emptyCertificateChain:
            return "Empty certificate chain"
        case .pinMismatch:
            return "SPKI pin mismatch"
        case .extractionFailed(let error):
            return "SPKI extraction failed: \(error)"
        case .handlerNotFound(let error):
            return "SSL handler not found: \(error)"
        }
    }
}
