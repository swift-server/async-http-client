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

import NIOConcurrencyHelpers
import NIOCore
import NIOSSL
import XCTest

@testable import AsyncHTTPClient

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

#if canImport(Network)
import Network
import Security
#endif

/// Tests for `HTTPClient.Configuration.tlsLocalIdentityNetworkFramework` — the mTLS client-identity
/// hook for direct (non-proxied) connections that use Network.framework instead of NIOSSL.
final class LocalIdentityNetworkFrameworkTests: XCTestCase {
    var clientGroup: EventLoopGroup!

    override func setUp() {
        XCTAssertNil(self.clientGroup)
        self.clientGroup = getDefaultEventLoopGroup(numberOfThreads: 3)
    }

    override func tearDown() {
        XCTAssertNotNil(self.clientGroup)
        XCTAssertNoThrow(try self.clientGroup.syncShutdownGracefully())
        self.clientGroup = nil
    }

    #if canImport(Network)
    func testClientCertificateIsPresentedOverNetworkFramework() throws {
        guard isTestingNIOTS() else { return }

        // Synthesizing a Keychain-backed SecIdentity from raw bytes inside an unsigned `swift test`
        // process is itself unreliable — the same reason RequestDL's own RawBytesIdentityBuilder test
        // suite only unit-tests its DER-parsing halves and never exercises the actual Keychain
        // round-trip end-to-end. Skip rather than flake/fail when that round-trip itself can't
        // complete in this environment; it says nothing about tlsLocalIdentityNetworkFramework or
        // sec_protocol_options_set_local_identity, which take a SecIdentity as a given.
        let handle: TestIdentityBuilder.Handle
        do {
            handle = try TestIdentityBuilder.makeIdentity(
                certificateDER: Data(TestTLS.certificateDER),
                privateKeyPKCS8DER: Data(TestTLS.privateKeyPKCS8DER)
            )
        } catch {
            throw XCTSkip(
                "Could not synthesize a Keychain-backed SecIdentity in this environment: \(error)"
            )
        }
        defer { TestIdentityBuilder.remove(handle) }

        // The server requires and validates a client certificate, trusting only TestTLS.certificate
        // itself (it's self-signed, so it is its own trust anchor).
        var serverConfig = TestTLS.serverConfiguration
        serverConfig.certificateVerification = .noHostnameVerification
        serverConfig.trustRoots = .certificates([TestTLS.certificate])

        var config = HTTPClient.Configuration()
        config.tlsLocalIdentityNetworkFramework = handle.identity

        let httpBin = HTTPBin(.http1_1(tlsConfiguration: serverConfig))
        let httpClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup), configuration: config)
        defer {
            XCTAssertNoThrow(try httpClient.syncShutdown())
            XCTAssertNoThrow(try httpBin.shutdown())
        }

        // If the client failed to present its certificate, the server would reject the handshake
        // and this would throw instead of succeeding.
        XCTAssertNoThrow(try httpClient.get(url: "https://localhost:\(httpBin.port)/get").wait())
    }

    func testConnectionFailsWithoutClientCertificateWhenServerRequiresOne() throws {
        guard isTestingNIOTS() else { return }

        var serverConfig = TestTLS.serverConfiguration
        serverConfig.certificateVerification = .noHostnameVerification
        serverConfig.trustRoots = .certificates([TestTLS.certificate])

        // No tlsLocalIdentityNetworkFramework configured — the negative control proving the server
        // above genuinely enforces mTLS, so the positive test isn't a false pass.
        let config = HTTPClient.Configuration().enableFastFailureModeForTesting()

        let httpBin = HTTPBin(.http1_1(tlsConfiguration: serverConfig))
        let httpClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup), configuration: config)
        defer {
            XCTAssertNoThrow(try httpClient.syncShutdown())
            XCTAssertNoThrow(try httpBin.shutdown())
        }

        XCTAssertThrowsError(try httpClient.get(url: "https://localhost:\(httpBin.port)/get").wait())
    }
    #endif
}

#if canImport(Network)
/// Minimal, test-only "raw bytes -> SecIdentity via a Keychain round-trip" builder for RSA/PKCS#8
/// keys only — there is no public API on Apple platforms to pair a certificate and private key into
/// a `SecIdentity` purely in memory, so this mirrors (in miniature) the same technique RequestDL's
/// own `Internals.RawBytesIdentityBuilder` uses for its `.urlSession` executor.
enum TestIdentityBuilder {
    struct Handle {
        let identity: SecIdentity
        fileprivate let label: String
    }

    enum Error: Swift.Error {
        case keychainOperationFailed(OSStatus, operation: String)
        case identityLookupReturnedWrongType
        case malformedDER
    }

    static func makeIdentity(certificateDER: Data, privateKeyPKCS8DER: Data) throws -> Handle {
        guard let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData) else {
            throw Error.malformedDER
        }
        let pkcs1DER = try unwrapPKCS8(privateKeyPKCS8DER)

        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
        ]
        var creationError: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(pkcs1DER as CFData, attributes as CFDictionary, &creationError) else {
            throw Error.keychainOperationFailed(errSecParam, operation: "SecKeyCreateWithData")
        }

        let label = "AsyncHTTPClientTests.mtls." + UUID().uuidString

        // `swift test` has no `keychain-access-groups` entitlement, which the data-protection
        // keychain requires on macOS — forcing the legacy file-based keychain sidesteps that.
        let useDataProtectionKeychain = false

        try addToKeychain(
            query: [
                kSecClass: kSecClassKey,
                kSecValueRef: secKey,
                kSecAttrLabel: label,
                kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                kSecUseDataProtectionKeychain: useDataProtectionKeychain,
            ],
            operation: "SecItemAdd(key)"
        )
        try addToKeychain(
            query: [
                kSecClass: kSecClassCertificate,
                kSecValueRef: certificate,
                kSecAttrLabel: label,
                kSecUseDataProtectionKeychain: useDataProtectionKeychain,
            ],
            operation: "SecItemAdd(certificate)"
        )

        // macOS-only shortcut (deliberately avoided by RequestDL's own RawBytesIdentityBuilder, which
        // needs to generalize to iOS/tvOS/watchOS): pairs the certificate with a private key already
        // in the keychain directly, instead of listing every identity and matching by certificate
        // bytes. Test-only code, macOS being the only platform `swift test` runs on for this fork.
        var matchingIdentity: SecIdentity?
        let identityStatus = SecIdentityCreateWithCertificate(nil, certificate, &matchingIdentity)
        guard identityStatus == errSecSuccess, let matchingIdentity else {
            throw Error.keychainOperationFailed(identityStatus, operation: "SecIdentityCreateWithCertificate")
        }

        return Handle(identity: matchingIdentity, label: label)
    }

    static func remove(_ handle: Handle) {
        for itemClass in [kSecClassKey, kSecClassCertificate] {
            let query: [CFString: Any] = [
                kSecClass: itemClass,
                kSecAttrLabel: handle.label,
                kSecUseDataProtectionKeychain: false,
            ]
            SecItemDelete(query as CFDictionary)
        }
    }

    /// Unwraps PKCS#8's `PrivateKeyInfo ::= SEQUENCE { version INTEGER, algorithm SEQUENCE,
    /// privateKey OCTET STRING, ... }` down to its inner PKCS#1 `privateKey` field, which is what
    /// `SecKeyCreateWithData` wants for RSA (it has no direct entry point for PKCS#8).
    private static func unwrapPKCS8(_ der: Data) throws -> Data {
        var reader = DERReader(Array(der))
        var envelope = DERReader(try reader.readSequence())
        _ = try envelope.read(tag: 0x02)  // version INTEGER, value unused
        _ = try envelope.readSequence()  // algorithm identifier, OID unused
        return Data(try envelope.read(tag: 0x04))  // privateKey OCTET STRING
    }

    private static func addToKeychain(query: [CFString: Any], operation: String) throws {
        var result: CFTypeRef?
        let status = SecItemAdd(query as CFDictionary, &result)
        // A previous run leaving this exact certificate/key behind (content-derived duplicate
        // detection, not label-based) already reached the state this call wants — treat as success.
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw Error.keychainOperationFailed(status, operation: operation)
        }
    }
}

/// Minimal DER TLV (tag-length-value) reader — only as much as unwrapping a PKCS#8 envelope needs.
private struct DERReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func readSequence() throws -> [UInt8] {
        try read(tag: 0x30)
    }

    mutating func read(tag: UInt8) throws -> [UInt8] {
        guard offset < bytes.count, bytes[offset] == tag else {
            throw TestIdentityBuilder.Error.malformedDER
        }
        offset += 1

        guard offset < bytes.count else { throw TestIdentityBuilder.Error.malformedDER }
        var length = Int(bytes[offset])
        offset += 1

        if length & 0x80 != 0 {
            let lengthByteCount = length & 0x7F
            guard lengthByteCount > 0, lengthByteCount <= 4, offset + lengthByteCount <= bytes.count else {
                throw TestIdentityBuilder.Error.malformedDER
            }
            length = 0
            for _ in 0..<lengthByteCount {
                length = (length << 8) | Int(bytes[offset])
                offset += 1
            }
        }

        guard offset + length <= bytes.count else { throw TestIdentityBuilder.Error.malformedDER }
        defer { offset += length }
        return Array(bytes[offset..<(offset + length)])
    }
}
#endif
