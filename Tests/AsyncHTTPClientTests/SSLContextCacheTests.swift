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

import NIOCore
import NIOPosix
import NIOSSL
import XCTest

@testable import AsyncHTTPClient

final class SSLContextCacheTests: XCTestCase {
    func testRequestingSSLContextWorks() {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = group.next()
        let cache = SSLContextCache()
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        XCTAssertNoThrow(
            try cache.sslContext(
                tlsConfiguration: .makeClientConfiguration(),
                eventLoop: eventLoop,
                logger: HTTPClient.loggingDisabled
            ).wait()
        )
    }

    func testCacheWorks() {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = group.next()
        let cache = SSLContextCache()
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        var firstContext: NIOSSLContext?
        var secondContext: NIOSSLContext?

        XCTAssertNoThrow(
            firstContext = try cache.sslContext(
                tlsConfiguration: .makeClientConfiguration(),
                eventLoop: eventLoop,
                logger: HTTPClient.loggingDisabled
            ).wait()
        )
        XCTAssertNoThrow(
            secondContext = try cache.sslContext(
                tlsConfiguration: .makeClientConfiguration(),
                eventLoop: eventLoop,
                logger: HTTPClient.loggingDisabled
            ).wait()
        )
        XCTAssertNotNil(firstContext)
        XCTAssertNotNil(secondContext)
        XCTAssert(firstContext === secondContext)
    }

    func testCacheDoesNotReturnWrongEntry() {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = group.next()
        let cache = SSLContextCache()
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        var firstContext: NIOSSLContext?
        var secondContext: NIOSSLContext?

        XCTAssertNoThrow(
            firstContext = try cache.sslContext(
                tlsConfiguration: .makeClientConfiguration(),
                eventLoop: eventLoop,
                logger: HTTPClient.loggingDisabled
            ).wait()
        )

        // Second one has a _different_ TLSConfiguration.
        var testTLSConfig = TLSConfiguration.makeClientConfiguration()
        testTLSConfig.certificateVerification = .none
        XCTAssertNoThrow(
            secondContext = try cache.sslContext(
                tlsConfiguration: testTLSConfig,
                eventLoop: eventLoop,
                logger: HTTPClient.loggingDisabled
            ).wait()
        )
        XCTAssertNotNil(firstContext)
        XCTAssertNotNil(secondContext)
        XCTAssert(firstContext !== secondContext)
    }
}
