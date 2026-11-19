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

#if canImport(Network)
import Network
import Security
#endif

/// Tests for `HTTPClient.Configuration.tlsCustomVerification` (NIOSSL backend) and
/// `HTTPClient.Configuration.tlsCustomVerificationNetworkFramework` (Network.framework backend) — the
/// hooks that let a caller fully replace certificate verification, on whichever TLS backend is actually
/// negotiating the connection.
final class TrustCustomVerificationTests: XCTestCase {
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

    // MARK: - NIOSSL backend

    func testNIOSSLCustomVerificationIsInvokedAndCanAcceptAnUntrustedChain() throws {
        // This only exercises the NIOSSL backend.
        guard !isTestingNIOTS() else { return }

        let invocationCount = NIOLockedValueBox(0)

        // tlsCustomVerification only overrides trust-chain verification — hostname/SNI matching is a
        // separate NIOSSL gate tied to certificateVerification (see the property's doc comment), and the
        // HTTPBin test certificate isn't issued for "localhost". Disabling it here isolates the behavior
        // this test actually cares about: that the callback, not the default chain check, decides trust.
        var tlsConfig = TLSConfiguration.makeClientConfiguration()
        tlsConfig.certificateVerification = .noHostnameVerification

        var config = HTTPClient.Configuration(tlsConfiguration: tlsConfig)
        config.tlsCustomVerification = { certificates, promise in
            invocationCount.withLockedValue { $0 += 1 }
            // The self-signed leaf HTTPBin presents would fail default trust-root validation — proving
            // this callback fully replaces it, not merely supplements it.
            XCTAssertFalse(certificates.isEmpty)
            promise.succeed(.certificateVerified)
        }

        let httpBin = HTTPBin(.http1_1(ssl: true))
        let httpClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup), configuration: config)
        defer {
            XCTAssertNoThrow(try httpClient.syncShutdown())
            XCTAssertNoThrow(try httpBin.shutdown())
        }

        XCTAssertNoThrow(try httpClient.get(url: "https://localhost:\(httpBin.port)/get").wait())
        XCTAssertEqual(invocationCount.withLockedValue { $0 }, 1)
    }

    func testNIOSSLCustomVerificationCanRejectAnOtherwiseTrustedConnection() throws {
        guard !isTestingNIOTS() else { return }

        var config = HTTPClient.Configuration(timeout: .init(connect: .milliseconds(200)))
        config.tlsCustomVerification = { _, promise in
            promise.succeed(.failed)
        }

        let httpBin = HTTPBin(.http1_1(ssl: true))
        let httpClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup), configuration: config)
        defer {
            XCTAssertNoThrow(try httpClient.syncShutdown())
            XCTAssertNoThrow(try httpBin.shutdown())
        }

        XCTAssertThrowsError(try httpClient.get(url: "https://localhost:\(httpBin.port)/get").wait()) { error in
            guard let sslError = error as? NIOSSLError, case .handshakeFailed = sslError else {
                XCTFail("Expected NIOSSLError.handshakeFailed, got \(error)")
                return
            }
        }
    }

    func testMTLSClientCertificateStillPresentedAlongsideNIOSSLCustomVerification() throws {
        // This only exercises the NIOSSL backend — client certificates aren't supported over
        // Network.framework at all (see the preconditionFailure in getNWProtocolTLSOptions).
        guard !isTestingNIOTS() else { return }

        // The server requires and validates a client certificate, trusting only TestTLS.certificate
        // itself (it's self-signed, so it is its own trust anchor) — this is mTLS, orthogonal to the
        // question this test actually asks: does presenting a client identity still work once the
        // client also installs a custom server-trust-verification callback?
        var serverConfig = TestTLS.serverConfiguration
        serverConfig.certificateVerification = .noHostnameVerification
        serverConfig.trustRoots = .certificates([TestTLS.certificate])

        var clientTLSConfig = TLSConfiguration.makeClientConfiguration()
        clientTLSConfig.certificateVerification = .noHostnameVerification
        clientTLSConfig.certificateChain = [.certificate(TestTLS.certificate)]
        clientTLSConfig.privateKey = .privateKey(TestTLS.privateKey)

        let invocationCount = NIOLockedValueBox(0)
        var config = HTTPClient.Configuration(tlsConfiguration: clientTLSConfig)
        config.tlsCustomVerification = { certificates, promise in
            invocationCount.withLockedValue { $0 += 1 }
            XCTAssertFalse(certificates.isEmpty)
            promise.succeed(.certificateVerified)
        }

        let httpBin = HTTPBin(.http1_1(tlsConfiguration: serverConfig))
        let httpClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup), configuration: config)
        defer {
            XCTAssertNoThrow(try httpClient.syncShutdown())
            XCTAssertNoThrow(try httpBin.shutdown())
        }

        // If the client failed to present its certificate, the server would reject the handshake
        // (SSL_VERIFY_FAIL_IF_NO_PEER_CERT) and this would throw instead of succeeding.
        XCTAssertNoThrow(try httpClient.get(url: "https://localhost:\(httpBin.port)/get").wait())
        XCTAssertEqual(invocationCount.withLockedValue { $0 }, 1)
    }

    // MARK: - Network.framework backend

    func testNetworkFrameworkCustomVerificationIsInvokedAndCanAcceptAnUntrustedChain() throws {
        guard isTestingNIOTS() else { return }
        #if canImport(Network)
        let invocationCount = NIOLockedValueBox(0)

        var config = HTTPClient.Configuration()
        config.tlsCustomVerificationNetworkFramework = { trust, complete in
            invocationCount.withLockedValue { $0 += 1 }
            XCTAssertFalse((SecTrustCopyCertificateChain(trust) as? [SecCertificate] ?? []).isEmpty)
            complete(true)
        }

        let httpBin = HTTPBin(.http1_1(ssl: true))
        let httpClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup), configuration: config)
        defer {
            XCTAssertNoThrow(try httpClient.syncShutdown())
            XCTAssertNoThrow(try httpBin.shutdown())
        }

        XCTAssertNoThrow(try httpClient.get(url: "https://localhost:\(httpBin.port)/get").wait())
        XCTAssertEqual(invocationCount.withLockedValue { $0 }, 1)
        #endif
    }

    func testNetworkFrameworkCustomVerificationCanRejectAnOtherwiseTrustedConnection() throws {
        guard isTestingNIOTS() else { return }
        #if canImport(Network)
        var config = HTTPClient.Configuration()
        config.tlsCustomVerificationNetworkFramework = { _, complete in
            complete(false)
        }
        config = config.enableFastFailureModeForTesting()

        let httpBin = HTTPBin(.http1_1(ssl: true))
        let httpClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup), configuration: config)
        defer {
            XCTAssertNoThrow(try httpClient.syncShutdown())
            XCTAssertNoThrow(try httpBin.shutdown())
        }

        XCTAssertThrowsError(try httpClient.get(url: "https://localhost:\(httpBin.port)/get").wait()) { error in
            XCTAssertTrue(
                error is HTTPClient.NWTLSError,
                "Expected HTTPClient.NWTLSError, got \(type(of: error))"
            )
        }
        #endif
    }

    // MARK: - Plumbing (no network I/O)

    func testGetNWProtocolTLSOptionsInstallsCustomVerifyBlockWhenProvided() throws {
        #if canImport(Network)
        guard #available(macOS 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *) else {
            throw XCTSkip("Network.framework not available")
        }
        let tlsConfig = TLSConfiguration.makeClientConfiguration()
        // Installing a callback must not throw, and must take precedence over the default trust-root
        // verify block that would otherwise be installed since certificateVerification is unchanged.
        XCTAssertNoThrow(
            try tlsConfig.getNWProtocolTLSOptions(
                serverNameIndicatorOverride: nil,
                customVerification: { _, complete in complete(true) }
            )
        )
        #else
        throw XCTSkip("Network.framework not available")
        #endif
    }
}
