//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the AsyncHTTPClient project authors
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
import NIOPosix
import NIOSSL
import NIOTransportServices
import XCTest

@testable import AsyncHTTPClient

#if canImport(Network)
import Network
#endif

class HTTPClientNIOTSTests: XCTestCase {
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

    func testCorrectEventLoopGroup() {
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
        defer {
            XCTAssertNoThrow(try httpClient.syncShutdown())
        }
        #if canImport(Network)
        if #available(macOS 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *) {
            XCTAssertTrue(httpClient.eventLoopGroup is NIOTSEventLoopGroup)
            return
        }
        #endif
        XCTAssertTrue(httpClient.eventLoopGroup is MultiThreadedEventLoopGroup)
    }

    func testTLSFailError() {
        guard isTestingNIOTS() else { return }

        let httpBin = HTTPBin(.http1_1(ssl: true))
        let config = HTTPClient.Configuration()
            .enableFastFailureModeForTesting()
        let httpClient = HTTPClient(
            eventLoopGroupProvider: .shared(self.clientGroup),
            configuration: config
        )
        defer {
            XCTAssertNoThrow(try httpClient.syncShutdown(requiresCleanClose: true))
            XCTAssertNoThrow(try httpBin.shutdown())
        }

        #if canImport(Network)
        do {
            _ = try httpClient.get(url: "https://localhost:\(httpBin.port)/get").wait()
            XCTFail("This should have failed")
        } catch let error as HTTPClient.NWTLSError {
            XCTAssert(
                error.status == errSSLHandshakeFail || error.status == errSSLBadCert,
                "unexpected NWTLSError with status \(error.status)"
            )
        } catch {
            XCTFail("Error should have been NWTLSError not \(type(of: error))")
        }
        #else
        XCTFail("wrong OS")
        #endif
    }

    func testConnectionFailsFastError() {
        guard isTestingNIOTS() else { return }
        #if canImport(Network)
        let httpBin = HTTPBin(.http1_1(ssl: false))
        let config = HTTPClient.Configuration()
            .enableFastFailureModeForTesting()

        let httpClient = HTTPClient(
            eventLoopGroupProvider: .shared(self.clientGroup),
            configuration: config
        )

        defer {
            XCTAssertNoThrow(try httpClient.syncShutdown(requiresCleanClose: true))
        }

        let port = httpBin.port
        XCTAssertNoThrow(try httpBin.shutdown())

        XCTAssertThrowsError(try httpClient.get(url: "http://localhost:\(port)/get").wait()) {
            XCTAssertTrue($0 is NWError)
        }
        #endif
    }

    func testConnectionFailError() {
        guard isTestingNIOTS() else { return }
        #if canImport(Network)
        let httpBin = HTTPBin(.http1_1(ssl: false))
        let httpClient = HTTPClient(
            eventLoopGroupProvider: .shared(self.clientGroup),
            configuration: .init(
                timeout: .init(
                    connect: .milliseconds(100),
                    read: .milliseconds(100)
                )
            )
        )

        defer {
            XCTAssertNoThrow(try httpClient.syncShutdown(requiresCleanClose: true))
        }

        let port = httpBin.port
        XCTAssertNoThrow(try httpBin.shutdown())

        XCTAssertThrowsError(try httpClient.get(url: "http://localhost:\(port)/get").wait()) {
            if let httpClientError = $0 as? HTTPClientError {
                XCTAssertEqual(httpClientError, .connectTimeout)
            } else if let posixError = $0 as? HTTPClient.NWPOSIXError {
                XCTAssertEqual(posixError.errorCode, .ECONNREFUSED)
            } else {
                XCTFail("unexpected error \($0)")
            }
        }
        #endif
    }

    func testTLSVersionError() {
        guard isTestingNIOTS() else { return }
        #if canImport(Network)
        let httpBin = HTTPBin(.http1_1(ssl: true))
        var tlsConfig = TLSConfiguration.makeClientConfiguration()
        tlsConfig.certificateVerification = .none
        tlsConfig.minimumTLSVersion = .tlsv11
        tlsConfig.maximumTLSVersion = .tlsv1

        let clientConfig = HTTPClient.Configuration(tlsConfiguration: tlsConfig)
            .enableFastFailureModeForTesting()
        let httpClient = HTTPClient(
            eventLoopGroupProvider: .shared(self.clientGroup),
            configuration: clientConfig
        )
        defer {
            XCTAssertNoThrow(try httpClient.syncShutdown(requiresCleanClose: true))
            XCTAssertNoThrow(try httpBin.shutdown())
        }

        XCTAssertThrowsError(try httpClient.get(url: "https://localhost:\(httpBin.port)/get").wait()) { error in
            XCTAssertEqual((error as? HTTPClient.NWTLSError)?.status, errSSLHandshakeFail)
        }
        #endif
    }

    func testTrustRootCertificateLoadFail() {
        guard isTestingNIOTS() else { return }
        #if canImport(Network)
        if #available(macOS 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *) {
            var tlsConfig = TLSConfiguration.makeClientConfiguration()
            tlsConfig.trustRoots = .file("not/a/certificate")

            XCTAssertThrowsError(try tlsConfig.getNWProtocolTLSOptions(serverNameIndicatorOverride: nil)) { error in
                switch error {
                case let error as NIOSSL.NIOSSLError where error == .failedToLoadCertificate:
                    break
                default:
                    XCTFail("\(error)")
                }
            }
        } else {
            XCTFail("should be impossible")
        }
        #endif
    }
}
