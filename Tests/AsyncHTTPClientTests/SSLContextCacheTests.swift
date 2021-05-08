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

@testable import AsyncHTTPClient
import NIO
import NIOSSL
import XCTest

final class SSLContextCacheTests: XCTestCase {
    func testJustStartingAndStoppingAContextCacheWorks() {
        SSLContextCache().shutdown()
    }

    func testRequestingSSLContextWorks() {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = group.next()
        let cache = SSLContextCache()
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
            cache.shutdown()
        }

        XCTAssertNoThrow(try cache.sslContext(tlsConfiguration: .forClient(),
                                              eventLoop: eventLoop,
                                              logger: HTTPClient.loggingDisabled).wait())
    }

    func testRequestingSSLContextAfterShutdownThrows() {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = group.next()
        let cache = SSLContextCache()
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        cache.shutdown()
        XCTAssertThrowsError(try cache.sslContext(tlsConfiguration: .forClient(),
                                                  eventLoop: eventLoop,
                                                  logger: HTTPClient.loggingDisabled).wait())
    }

    func testCacheWorks() {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = group.next()
        let cache = SSLContextCache()
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
            cache.shutdown()
        }

        var firstContext: NIOSSLContext?
        var secondContext: NIOSSLContext?

        XCTAssertNoThrow(firstContext = try cache.sslContext(tlsConfiguration: .forClient(),
                                                             eventLoop: eventLoop,
                                                             logger: HTTPClient.loggingDisabled).wait())
        XCTAssertNoThrow(secondContext = try cache.sslContext(tlsConfiguration: .forClient(),
                                                              eventLoop: eventLoop,
                                                              logger: HTTPClient.loggingDisabled).wait())
        XCTAssertNotNil(firstContext)
        XCTAssertNotNil(secondContext)
        XCTAssert(firstContext === secondContext)
    }
}
