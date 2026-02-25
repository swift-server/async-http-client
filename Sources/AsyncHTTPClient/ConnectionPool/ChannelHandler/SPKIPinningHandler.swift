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

/// Constant-time comparison to prevent timing attacks during SPKI pin validation.
///
/// Timing attacks exploit micro-variations in execution time to infer secret values.
/// This function eliminates such leaks by:
/// 1. Iterating a fixed number of times (determined by hash algorithm)
/// 2. Processing all candidates even after a match is found
/// 3. Performing all secret-dependent operations before any conditional branches
///
/// SECURITY INVARIANT: All candidates share identical length (enforced by
/// SPKIPinningConfiguration grouping and SPKIHash validation). Length mismatches
/// are rejected early using public knowledge (algorithm-determined digest size),
/// which cannot leak secret information.
internal func constantTimeAnyMatch(_ target: Data, _ candidates: [SPKIHash]) -> Bool {
    guard !candidates.isEmpty else { return false }

    let expectedLength = candidates[0].bytes.count
    guard target.count == expectedLength else { return false }

    var anyMatch: UInt8 = 0
    for candidate in candidates {
        precondition(
            candidate.bytes.count == expectedLength,
            "Algorithm grouping invariant violated: candidates must share identical length"
        )

        var diff: UInt8 = 0
        for i in 0 ..< expectedLength {
            diff |= target[i] ^ candidate.bytes[i]
        }
        anyMatch |= (diff == 0) ? 1 : 0
    }
    return anyMatch != 0
}

/// Configuration for SPKI pinning validation.
///
/// - Warning: Always deploy multiple pins to enable safe certificate rotation.
///   Single-pin configurations in `.strict` mode risk catastrophic lockout.
public struct SPKIPinningConfiguration: Sendable, Hashable {

    /// SPKI hashes of trusted certificates.
    public let pins: [SPKIHash]

    /// Policy for handling pin validation failures.
    public let policy: SPKIPinningPolicy

    private let pinsByAlgorithm: [ObjectIdentifier: [SPKIHash]]

    /// Creates an SPKI pinning configuration.
    ///
    /// - Parameters:
    ///   - pins: Hashes of trusted certificates. For production safety, include
    ///           pins for both current and upcoming certificates to enable rotation.
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

/// Security policy for SPKI pin validation failures.
///
/// Determines the client's response when a server's certificate fails SPKI pin validation:
/// - `.audit`: Permit the connection for observability (staging/debugging only)
/// - `.strict`: Terminate the connection immediately (production environments)
///
/// - Warning: Never use `.audit` in production — it effectively disables pinning security
///   guarantees while maintaining audit visibility.
public struct SPKIPinningPolicy: Sendable, Hashable {

    private enum RawValue: Sendable, Hashable {
        case audit
        case strict
    }

    /// Permit connections with untrusted certificates for observability only.
    ///
    /// Use exclusively for debugging, testing, or migration scenarios. Never use in production.
    public static let audit = SPKIPinningPolicy(rawValue: .audit)

    /// Reject connections with untrusted certificates.
    ///
    /// Use in production environments where security is paramount.
    public static let strict = SPKIPinningPolicy(rawValue: .strict)

    public var description: String {
        switch self.rawValue {
        case .audit: return "audit"
        case .strict: return "strict"
        }
    }

    private let rawValue: RawValue

    private init(rawValue: RawValue) {
        self.rawValue = rawValue
    }

    public static func ==(lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue == rhs.rawValue
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(rawValue)
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

    init(
        tlsPinning: SPKIPinningConfiguration,
        logger: Logger
    ) {
        self.tlsPinning = tlsPinning
        self.logger = logger

        if tlsPinning.pins.count < 2 && tlsPinning.policy == .strict {
            logger.warning(
                "SPKIPinningHandler deployed with < 2 pins in strict mode — catastrophic lockout risk on certificate rotation!",
                metadata: [
                    "current_pin_count": .stringConvertible(tlsPinning.pins.count),
                    "recommendation": .string("Deploy multiple pins to enable safe certificate rotation")
                ]
            )
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        guard case .handshakeCompleted = (event as? TLSUserEvent) else {
            context.fireUserInboundEventTriggered(event)
            return
        }

        // ⚠️ Security-critical: handshake propagation is delayed until validation completes
        let result = self.validatePinning(for: Result {
            try context.pipeline.syncOperations.handler(type: NIOSSLHandler.self).peerCertificate
        })

        switch result {
        case .accepted:
            context.fireUserInboundEventTriggered(event)

        case .auditWarning(let error):
            logger.warning(
                "SPKI pinning failed — connection allowed for audit purposes",
                metadata: [
                    "error": .string(String(describing: error)),
                    "policy": .string(tlsPinning.policy.description)
                ]
            )
            context.fireUserInboundEventTriggered(event)

        case .rejected(let error):
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
