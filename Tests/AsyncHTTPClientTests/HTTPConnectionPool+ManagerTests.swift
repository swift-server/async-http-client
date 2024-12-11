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

import Logging
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest

@testable import AsyncHTTPClient

class HTTPConnectionPool_ManagerTests: XCTestCase {
    func testManagerHappyPath() {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 4)
        defer { XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully()) }

        let httpBin1 = HTTPBin()
        defer { XCTAssertNoThrow(try httpBin1.shutdown()) }

        let httpBin2 = HTTPBin()
        defer { XCTAssertNoThrow(try httpBin2.shutdown()) }

        let server = [httpBin1, httpBin2]

        let poolManager = HTTPConnectionPool.Manager(
            eventLoopGroup: eventLoopGroup,
            configuration: .init(),
            backgroundActivityLogger: .init(label: "test")
        )

        defer {
            let promise = eventLoopGroup.next().makePromise(of: Bool.self)
            poolManager.shutdown(promise: promise)
            XCTAssertNoThrow(try promise.futureResult.wait())
        }

        for i in 0..<9 {
            let httpBin = server[i % 2]

            var maybeRequest: HTTPClient.Request?
            var maybeRequestBag: RequestBag<ResponseAccumulator>?
            XCTAssertNoThrow(maybeRequest = try HTTPClient.Request(url: "http://localhost:\(httpBin.port)"))
            XCTAssertNoThrow(
                maybeRequestBag = try RequestBag(
                    request: XCTUnwrap(maybeRequest),
                    eventLoopPreference: .indifferent,
                    task: .init(eventLoop: eventLoopGroup.next(), logger: .init(label: "test")),
                    redirectHandler: nil,
                    connectionDeadline: .now() + .seconds(5),
                    requestOptions: .forTests(),
                    delegate: ResponseAccumulator(request: XCTUnwrap(maybeRequest))
                )
            )

            guard let requestBag = maybeRequestBag else { return XCTFail("Expected to get a request") }

            poolManager.executeRequest(requestBag)

            XCTAssertNoThrow(try requestBag.task.futureResult.wait())
            XCTAssertEqual(httpBin.activeConnections, 1)
        }
    }

    func testShutdownManagerThatHasSeenNoConnections() {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully()) }

        let poolManager = HTTPConnectionPool.Manager(
            eventLoopGroup: eventLoopGroup,
            configuration: .init(),
            backgroundActivityLogger: .init(label: "test")
        )

        let eventLoop = eventLoopGroup.next()
        let promise = eventLoop.makePromise(of: Bool.self)
        poolManager.shutdown(promise: promise)
        XCTAssertFalse(try promise.futureResult.wait())
    }

    func testExecutingARequestOnAShutdownPoolManager() {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully()) }

        let httpBin = HTTPBin()
        defer { XCTAssertNoThrow(try httpBin.shutdown()) }

        let poolManager = HTTPConnectionPool.Manager(
            eventLoopGroup: eventLoopGroup,
            configuration: .init(),
            backgroundActivityLogger: .init(label: "test")
        )

        let eventLoop = eventLoopGroup.next()
        let promise = eventLoop.makePromise(of: Bool.self)
        poolManager.shutdown(promise: promise)
        XCTAssertFalse(try promise.futureResult.wait())

        var maybeRequest: HTTPClient.Request?
        var maybeRequestBag: RequestBag<ResponseAccumulator>?
        XCTAssertNoThrow(maybeRequest = try HTTPClient.Request(url: "http://localhost:\(httpBin.port)"))
        XCTAssertNoThrow(
            maybeRequestBag = try RequestBag(
                request: XCTUnwrap(maybeRequest),
                eventLoopPreference: .indifferent,
                task: .init(eventLoop: eventLoopGroup.next(), logger: .init(label: "test")),
                redirectHandler: nil,
                connectionDeadline: .now() + .seconds(5),
                requestOptions: .forTests(),
                delegate: ResponseAccumulator(request: XCTUnwrap(maybeRequest))
            )
        )

        guard let requestBag = maybeRequestBag else { return XCTFail("Expected to get a request") }

        poolManager.executeRequest(requestBag)

        XCTAssertThrowsError(try requestBag.task.futureResult.wait()) {
            XCTAssertEqual($0 as? HTTPClientError, .alreadyShutdown)
        }
    }
}
