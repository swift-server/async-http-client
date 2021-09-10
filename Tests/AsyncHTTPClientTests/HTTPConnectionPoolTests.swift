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
import Logging
import NIOCore
import NIOPosix
import XCTest

class HTTPConnectionPoolTests: XCTestCase {
    func testOnlyOneConnectionIsUsedForSubSequentRequests() {
        let httpBin = HTTPBin()
        defer { XCTAssertNoThrow(try httpBin.shutdown()) }
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = eventLoopGroup.next()
        defer { XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully()) }

        let request = try! HTTPClient.Request(url: "http://localhost:\(httpBin.port)")
        let poolDelegate = TestDelegate(eventLoop: eventLoop)

        let pool = HTTPConnectionPool(
            eventLoopGroup: eventLoopGroup,
            sslContextCache: .init(),
            tlsConfiguration: .none,
            clientConfiguration: .init(),
            key: .init(request),
            delegate: poolDelegate,
            idGenerator: .init(),
            backgroundActivityLogger: .init(label: "test")
        )
        defer {
            pool.shutdown()
            XCTAssertNoThrow(try poolDelegate.future.wait())
            XCTAssertNoThrow(try eventLoop.scheduleTask(in: .seconds(1)) {}.futureResult.wait())
            XCTAssertEqual(httpBin.activeConnections, 0)
        }

        XCTAssertEqual(httpBin.createdConnections, 0)

        for _ in 0..<10 {
            var maybeRequest: HTTPClient.Request?
            var maybeRequestBag: RequestBag<ResponseAccumulator>?
            XCTAssertNoThrow(maybeRequest = try HTTPClient.Request(url: "https://localhost:\(httpBin.port)"))
            XCTAssertNoThrow(maybeRequestBag = try RequestBag(
                request: XCTUnwrap(maybeRequest),
                eventLoopPreference: .indifferent,
                task: .init(eventLoop: eventLoop, logger: .init(label: "test")),
                redirectHandler: nil,
                connectionDeadline: .distantFuture,
                idleReadTimeout: nil,
                delegate: ResponseAccumulator(request: XCTUnwrap(maybeRequest))
            ))

            guard let requestBag = maybeRequestBag else { return XCTFail("Expected to get a request") }

            pool.executeRequest(requestBag)

            XCTAssertNoThrow(try requestBag.task.futureResult.wait())
            XCTAssertEqual(httpBin.activeConnections, 1)
            XCTAssertEqual(httpBin.createdConnections, 1)
        }
    }

    func testConnectionsForEventLoopRequirementsAreClosed() {
        let httpBin = HTTPBin()
        defer { XCTAssertNoThrow(try httpBin.shutdown()) }
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let eventLoop = eventLoopGroup.next()
        defer { XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully()) }

        let request = try! HTTPClient.Request(url: "http://localhost:\(httpBin.port)")
        let poolDelegate = TestDelegate(eventLoop: eventLoop)

        let pool = HTTPConnectionPool(
            eventLoopGroup: eventLoopGroup,
            sslContextCache: .init(),
            tlsConfiguration: .none,
            clientConfiguration: .init(),
            key: .init(request),
            delegate: poolDelegate,
            idGenerator: .init(),
            backgroundActivityLogger: .init(label: "test")
        )
        defer {
            pool.shutdown()
            XCTAssertNoThrow(try poolDelegate.future.wait())
            XCTAssertNoThrow(try eventLoop.scheduleTask(in: .milliseconds(100)) {}.futureResult.wait())
            XCTAssertEqual(httpBin.activeConnections, 0)
            XCTAssertEqual(httpBin.createdConnections, 10)
        }

        XCTAssertEqual(httpBin.createdConnections, 0)

        for i in 0..<10 {
            var maybeRequest: HTTPClient.Request?
            var maybeRequestBag: RequestBag<ResponseAccumulator>?
            XCTAssertNoThrow(maybeRequest = try HTTPClient.Request(url: "https://localhost:\(httpBin.port)"))
            XCTAssertNoThrow(maybeRequestBag = try RequestBag(
                request: XCTUnwrap(maybeRequest),
                eventLoopPreference: .init(.testOnly_exact(channelOn: eventLoopGroup.next(), delegateOn: eventLoopGroup.next())),
                task: .init(eventLoop: eventLoop, logger: .init(label: "test")),
                redirectHandler: nil,
                connectionDeadline: .distantFuture,
                idleReadTimeout: nil,
                delegate: ResponseAccumulator(request: XCTUnwrap(maybeRequest))
            ))

            guard let requestBag = maybeRequestBag else { return XCTFail("Expected to get a request") }

            pool.executeRequest(requestBag)
            XCTAssertNoThrow(try requestBag.task.futureResult.wait())
            XCTAssertEqual(httpBin.createdConnections, i + 1)
        }
    }

    func testConnectionPoolGrowsToMaxConcurrentConnections() {
        let httpBin = HTTPBin()
        let maxConnections = 8
        defer { XCTAssertNoThrow(try httpBin.shutdown()) }
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let eventLoop = eventLoopGroup.next()
        defer { XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully()) }

        let request = try! HTTPClient.Request(url: "http://localhost:\(httpBin.port)")
        let poolDelegate = TestDelegate(eventLoop: eventLoop)

        let pool = HTTPConnectionPool(
            eventLoopGroup: eventLoopGroup,
            sslContextCache: .init(),
            tlsConfiguration: .none,
            clientConfiguration: .init(connectionPool: .init(idleTimeout: .milliseconds(500))),
            key: .init(request),
            delegate: poolDelegate,
            idGenerator: .init(),
            backgroundActivityLogger: .init(label: "test")
        )
        defer {
            pool.shutdown()
            XCTAssertNoThrow(try poolDelegate.future.wait())

            XCTAssertEqual(httpBin.activeConnections, 0)
            XCTAssertEqual(httpBin.createdConnections, maxConnections)
        }

        XCTAssertEqual(httpBin.createdConnections, 0)

        var tasks = [EventLoopFuture<HTTPClient.Response>]()

        for _ in 0..<1000 {
            var maybeRequest: HTTPClient.Request?
            var maybeRequestBag: RequestBag<ResponseAccumulator>?
            XCTAssertNoThrow(maybeRequest = try HTTPClient.Request(url: "https://localhost:\(httpBin.port)"))
            XCTAssertNoThrow(maybeRequestBag = try RequestBag(
                request: XCTUnwrap(maybeRequest),
                eventLoopPreference: .indifferent,
                task: .init(eventLoop: eventLoopGroup.next(), logger: .init(label: "test")),
                redirectHandler: nil,
                connectionDeadline: .distantFuture,
                idleReadTimeout: nil,
                delegate: ResponseAccumulator(request: XCTUnwrap(maybeRequest))
            ))

            guard let requestBag = maybeRequestBag else { return XCTFail("Expected to get a request") }

            pool.executeRequest(requestBag)
            tasks.append(requestBag.task.futureResult)
        }

        XCTAssertNoThrow(try EventLoopFuture.whenAllSucceed(tasks, on: eventLoopGroup.next()).wait())
        XCTAssertEqual(httpBin.activeConnections, maxConnections)
        XCTAssertNoThrow(try eventLoop.scheduleTask(in: .milliseconds(600)) {}.futureResult.wait())
        XCTAssertEqual(httpBin.activeConnections, 0)
    }

    func testConnectionCreationIsRetriedUntilRequestIsFailed() {
        let httpBin = HTTPBin(proxy: .simulate(authorization: "abc123"))
        defer { XCTAssertNoThrow(try httpBin.shutdown()) }
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let eventLoop = eventLoopGroup.next()
        defer { XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully()) }

        let request = try! HTTPClient.Request(url: "http://localhost:9000")
        let poolDelegate = TestDelegate(eventLoop: eventLoop)

        let pool = HTTPConnectionPool(
            eventLoopGroup: eventLoopGroup,
            sslContextCache: .init(),
            tlsConfiguration: .none,
            clientConfiguration: .init(
                proxy: .init(host: "localhost", port: httpBin.port, type: .http(.basic(credentials: "invalid")))
            ),
            key: .init(request),
            delegate: poolDelegate,
            idGenerator: .init(),
            backgroundActivityLogger: .init(label: "test")
        )
        defer {
            pool.shutdown()
            XCTAssertNoThrow(try poolDelegate.future.wait())
        }

        XCTAssertEqual(httpBin.createdConnections, 0)

        var maybeRequest: HTTPClient.Request?
        var maybeRequestBag: RequestBag<ResponseAccumulator>?
        XCTAssertNoThrow(maybeRequest = try HTTPClient.Request(url: "https://localhost:\(httpBin.port)"))
        XCTAssertNoThrow(maybeRequestBag = try RequestBag(
            request: XCTUnwrap(maybeRequest),
            eventLoopPreference: .indifferent,
            task: .init(eventLoop: eventLoopGroup.next(), logger: .init(label: "test")),
            redirectHandler: nil,
            connectionDeadline: .now() + .seconds(5),
            idleReadTimeout: nil,
            delegate: ResponseAccumulator(request: XCTUnwrap(maybeRequest))
        ))

        guard let requestBag = maybeRequestBag else { return XCTFail("Expected to get a request") }

        pool.executeRequest(requestBag)
        XCTAssertThrowsError(try requestBag.task.futureResult.wait()) {
            XCTAssertEqual($0 as? HTTPClientError, .proxyAuthenticationRequired)
        }
        XCTAssertGreaterThanOrEqual(httpBin.createdConnections, 8)
        XCTAssertEqual(httpBin.activeConnections, 0)
    }

    func testConnectionCreationIsRetriedUntilPoolIsShutdown() {
        let httpBin = HTTPBin(proxy: .simulate(authorization: "abc123"))
        defer { XCTAssertNoThrow(try httpBin.shutdown()) }
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let eventLoop = eventLoopGroup.next()
        defer { XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully()) }

        let request = try! HTTPClient.Request(url: "http://localhost:9000")
        let poolDelegate = TestDelegate(eventLoop: eventLoop)

        let pool = HTTPConnectionPool(
            eventLoopGroup: eventLoopGroup,
            sslContextCache: .init(),
            tlsConfiguration: .none,
            clientConfiguration: .init(
                proxy: .init(host: "localhost", port: httpBin.port, type: .http(.basic(credentials: "invalid")))
            ),
            key: .init(request),
            delegate: poolDelegate,
            idGenerator: .init(),
            backgroundActivityLogger: .init(label: "test")
        )

        XCTAssertEqual(httpBin.createdConnections, 0)

        var maybeRequest: HTTPClient.Request?
        var maybeRequestBag: RequestBag<ResponseAccumulator>?
        XCTAssertNoThrow(maybeRequest = try HTTPClient.Request(url: "https://localhost:\(httpBin.port)"))
        XCTAssertNoThrow(maybeRequestBag = try RequestBag(
            request: XCTUnwrap(maybeRequest),
            eventLoopPreference: .indifferent,
            task: .init(eventLoop: eventLoopGroup.next(), logger: .init(label: "test")),
            redirectHandler: nil,
            connectionDeadline: .now() + .seconds(5),
            idleReadTimeout: nil,
            delegate: ResponseAccumulator(request: XCTUnwrap(maybeRequest))
        ))

        guard let requestBag = maybeRequestBag else { return XCTFail("Expected to get a request") }

        pool.executeRequest(requestBag)
        XCTAssertNoThrow(try eventLoop.scheduleTask(in: .seconds(2)) {}.futureResult.wait())
        pool.shutdown()

        XCTAssertThrowsError(try requestBag.task.futureResult.wait()) {
            XCTAssertEqual($0 as? HTTPClientError, .cancelled)
        }
        XCTAssertGreaterThanOrEqual(httpBin.createdConnections, 3)
        XCTAssertNoThrow(try poolDelegate.future.wait())
        XCTAssertEqual(httpBin.activeConnections, 0)
    }

    func testConnectionCreationIsRetriedUntilRequestIsCancelled() {
        let httpBin = HTTPBin(proxy: .simulate(authorization: "abc123"))
        defer { XCTAssertNoThrow(try httpBin.shutdown()) }
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let eventLoop = eventLoopGroup.next()
        defer { XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully()) }

        let request = try! HTTPClient.Request(url: "http://localhost:\(httpBin.port)")
        let poolDelegate = TestDelegate(eventLoop: eventLoop)

        let pool = HTTPConnectionPool(
            eventLoopGroup: eventLoopGroup,
            sslContextCache: .init(),
            tlsConfiguration: .none,
            clientConfiguration: .init(
                proxy: .init(host: "localhost", port: httpBin.port, type: .http(.basic(credentials: "invalid")))
            ),
            key: .init(request),
            delegate: poolDelegate,
            idGenerator: .init(),
            backgroundActivityLogger: .init(label: "test")
        )
        defer {
            pool.shutdown()
            XCTAssertNoThrow(try poolDelegate.future.wait())
        }

        XCTAssertEqual(httpBin.createdConnections, 0)

        var maybeRequest: HTTPClient.Request?
        var maybeRequestBag: RequestBag<ResponseAccumulator>?
        XCTAssertNoThrow(maybeRequest = try HTTPClient.Request(url: "http://localhost:\(httpBin.port)"))
        XCTAssertNoThrow(maybeRequestBag = try RequestBag(
            request: XCTUnwrap(maybeRequest),
            eventLoopPreference: .indifferent,
            task: .init(eventLoop: eventLoopGroup.next(), logger: .init(label: "test")),
            redirectHandler: nil,
            connectionDeadline: .now() + .seconds(5),
            idleReadTimeout: nil,
            delegate: ResponseAccumulator(request: XCTUnwrap(maybeRequest))
        ))

        guard let requestBag = maybeRequestBag else { return XCTFail("Expected to get a request") }

        pool.executeRequest(requestBag)
        XCTAssertNoThrow(try eventLoop.scheduleTask(in: .seconds(1)) {}.futureResult.wait())
        requestBag.cancel()

        XCTAssertThrowsError(try requestBag.task.futureResult.wait()) {
            XCTAssertEqual($0 as? HTTPClientError, .cancelled)
        }
        XCTAssertGreaterThanOrEqual(httpBin.createdConnections, 3)
    }

    func testConnectionShutdownIsCalledOnActiveConnections() {
        let httpBin = HTTPBin()
        defer { XCTAssertNoThrow(try httpBin.shutdown()) }
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = eventLoopGroup.next()
        defer { XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully()) }

        let request = try! HTTPClient.Request(url: "http://localhost:\(httpBin.port)")
        let poolDelegate = TestDelegate(eventLoop: eventLoop)

        let pool = HTTPConnectionPool(
            eventLoopGroup: eventLoopGroup,
            sslContextCache: .init(),
            tlsConfiguration: .none,
            clientConfiguration: .init(),
            key: .init(request),
            delegate: poolDelegate,
            idGenerator: .init(),
            backgroundActivityLogger: .init(label: "test")
        )

        var maybeRequest: HTTPClient.Request?
        var maybeRequestBag: RequestBag<ResponseAccumulator>?
        XCTAssertNoThrow(maybeRequest = try HTTPClient.Request(url: "http://localhost:\(httpBin.port)/wait"))
        XCTAssertNoThrow(maybeRequestBag = try RequestBag(
            request: XCTUnwrap(maybeRequest),
            eventLoopPreference: .indifferent,
            task: .init(eventLoop: eventLoopGroup.next(), logger: .init(label: "test")),
            redirectHandler: nil,
            connectionDeadline: .now() + .seconds(5),
            idleReadTimeout: nil,
            delegate: ResponseAccumulator(request: XCTUnwrap(maybeRequest))
        ))

        guard let requestBag = maybeRequestBag else { return XCTFail("Expected to get a request") }

        pool.executeRequest(requestBag)
        XCTAssertNoThrow(try eventLoop.scheduleTask(in: .milliseconds(500)) {}.futureResult.wait())
        pool.shutdown()

        XCTAssertNoThrow(try poolDelegate.future.wait())

        XCTAssertThrowsError(try requestBag.task.futureResult.wait()) {
            XCTAssertEqual($0 as? HTTPClientError, .cancelled)
        }

        XCTAssertGreaterThanOrEqual(httpBin.createdConnections, 1)
        XCTAssertGreaterThanOrEqual(httpBin.activeConnections, 0)
    }
}

class TestDelegate: HTTPConnectionPoolDelegate {
    private let promise: EventLoopPromise<Bool>
    var future: EventLoopFuture<Bool> {
        self.promise.futureResult
    }

    init(eventLoop: EventLoop) {
        self.promise = eventLoop.makePromise(of: Bool.self)
    }

    func connectionPoolDidShutdown(_ pool: HTTPConnectionPool, unclean: Bool) {
        self.promise.succeed(unclean)
    }
}
