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

#if canImport(Network)

@testable import AsyncHTTPClient
import Network
import NIO
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
        if #available(macOS 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *) {
            XCTAssertTrue(httpClient.eventLoopGroup is NIOTSEventLoopGroup)
            return
        }
        XCTAssertTrue(httpClient.eventLoopGroup is MultiThreadedEventLoopGroup)
    }

    func testDNSFailError() {
        guard isTestingNIOTS() else { return }
        let httpClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup))
        defer {
            XCTAssertNoThrow(try httpClient.syncShutdown(requiresCleanClose: true))
        }

        do {
            _ = try httpClient.get(url: "http://dnsfail/").wait()
            XCTFail("This should have failed")
        } catch NWDNSError.noSuchRecord {
        } catch {
            XCTFail("Error should have been NWDSNError.noSuchRecord not \(error)")
        }
    }
    
    func testTLSFailError() {
        guard isTestingNIOTS() else { return }
        let httpBin = HTTPBin(ssl: true)
        let httpClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup))
        defer {
            XCTAssertNoThrow(try httpClient.syncShutdown(requiresCleanClose: true))
            XCTAssertNoThrow(try httpBin.shutdown())
        }

        do {
            _ = try httpClient.get(url: "https://localhost:\(httpBin.port)/get").wait()
            XCTFail("This should have failed")
        } catch let error as NWTLSError {
            XCTAssertEqual(error.status, errSSLHandshakeFail)
        } catch {
            XCTFail("Error should have been NWTLSError not \(type(of:error))")
        }
    }
    
    func testConnectionFailError() {
        guard isTestingNIOTS() else { return }
        let httpBin = HTTPBin(ssl: true)
        let httpClient = HTTPClient(eventLoopGroupProvider: .shared(self.clientGroup))
        defer {
            XCTAssertNoThrow(try httpClient.syncShutdown(requiresCleanClose: true))
        }
        let port = httpBin.port
        XCTAssertNoThrow(try httpBin.shutdown())

        do {
            _ = try httpClient.get(url: "https://localhost:\(port)/get").wait()
            XCTFail("This should have failed")
        } catch let error as NWPOSIXError {
            XCTAssertEqual(error.errorCode, .ECONNREFUSED)
        } catch {
            XCTFail("Error should have been NWPOSIXError not \(type(of:error))")
        }
    }
    
    func testTLSVersionError() {
        guard isTestingNIOTS() else { return }
        let httpBin = HTTPBin(ssl: true)
        let httpClient = HTTPClient(
            eventLoopGroupProvider: .shared(self.clientGroup),
            configuration: .init(tlsConfiguration: TLSConfiguration.forClient(minimumTLSVersion: .tlsv11, maximumTLSVersion: .tlsv1, certificateVerification: .none))
        )
        defer {
            XCTAssertNoThrow(try httpClient.syncShutdown(requiresCleanClose: true))
            XCTAssertNoThrow(try httpBin.shutdown())
        }

        do {
            _ = try httpClient.get(url: "https://localhost:\(httpBin.port)/get").wait()
            XCTFail("This should have failed")
        } catch let error as NWTLSError {
            XCTAssertEqual(error.status, errSSLHandshakeFail)
        } catch {
            XCTFail("Error should have been NWTLSError not \(type(of:error))")
        }
    }
}

#endif
