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

@testable import AsyncHTTPClient
#if canImport(Network)
import Network
#endif
import NIOCore
import NIOPosix
import NIOSSL
import NIOTransportServices
import XCTest

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
        let httpClient = HTTPClient(eventLoopGroupProvider: .createNew)
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
        let httpClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup))
        defer {
            XCTAssertNoThrow(try httpClient.syncShutdown(requiresCleanClose: true))
            XCTAssertNoThrow(try httpBin.shutdown())
        }

        #if canImport(Network)
        do {
            _ = try httpClient.get(url: "https://localhost:\(httpBin.port)/get").wait()
            XCTFail("This should have failed")
        } catch let error as HTTPClient.NWTLSError {
            XCTAssert(error.status == errSSLHandshakeFail || error.status == errSSLBadCert,
                      "unexpected NWTLSError with status \(error.status)")
        } catch {
            XCTFail("Error should have been NWTLSError not \(type(of: error))")
        }
        #else
        XCTFail("wrong OS")
        #endif
    }

    func testConnectionFailError() {
        guard isTestingNIOTS() else { return }
        let httpBin = HTTPBin(.http1_1(ssl: true))
        let httpClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup),
                                    configuration: .init(timeout: .init(connect: .milliseconds(100),
                                                                        read: .milliseconds(100))))

        defer {
            XCTAssertNoThrow(try httpClient.syncShutdown(requiresCleanClose: true))
        }

        let port = httpBin.port
        XCTAssertNoThrow(try httpBin.shutdown())

        XCTAssertThrowsError(try httpClient.get(url: "https://localhost:\(port)/get").wait()) {
            XCTAssertEqual($0 as? HTTPClientError, .connectTimeout)
        }
    }

    func testTLSVersionError() {
        guard isTestingNIOTS() else { return }
        #if canImport(Network)
        let httpBin = HTTPBin(.http1_1(ssl: true))
        var tlsConfig = TLSConfiguration.makeClientConfiguration()
        tlsConfig.certificateVerification = .none
        tlsConfig.minimumTLSVersion = .tlsv11
        tlsConfig.maximumTLSVersion = .tlsv1
        let httpClient = HTTPClient(
            eventLoopGroupProvider: .shared(self.clientGroup),
            configuration: .init(tlsConfiguration: tlsConfig)
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

            XCTAssertThrowsError(try tlsConfig.getNWProtocolTLSOptions()) { error in
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
