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
            XCTAssertNoThrow(
                maybeRequestBag = try RequestBag(
                    request: XCTUnwrap(maybeRequest),
                    eventLoopPreference: .indifferent,
                    task: .init(eventLoop: eventLoop, logger: .init(label: "test")),
                    redirectHandler: nil,
                    connectionDeadline: .distantFuture,
                    requestOptions: .forTests(),
                    delegate: ResponseAccumulator(request: XCTUnwrap(maybeRequest))
                )
            )

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
            // Since we would migrate from h2 -> h1, which creates a general purpose connection
            // for every connection in .starting state, after the first request which will
            // be serviced by an overflow connection, the rest of requests will use the general
            // purpose connection since they are all on the same event loop.
            // Hence we will only create 1 overflow connection and 1 general purpose connection.
            XCTAssertEqual(httpBin.createdConnections, 2)
        }

        XCTAssertEqual(httpBin.createdConnections, 0)

        for _ in 0..<10 {
            var maybeRequest: HTTPClient.Request?
            var maybeRequestBag: RequestBag<ResponseAccumulator>?
            XCTAssertNoThrow(maybeRequest = try HTTPClient.Request(url: "https://localhost:\(httpBin.port)"))
            XCTAssertNoThrow(
                maybeRequestBag = try RequestBag(
                    request: XCTUnwrap(maybeRequest),
                    eventLoopPreference: .init(
                        .testOnly_exact(channelOn: eventLoopGroup.next(), delegateOn: eventLoopGroup.next())
                    ),
                    task: .init(eventLoop: eventLoop, logger: .init(label: "test")),
                    redirectHandler: nil,
                    connectionDeadline: .distantFuture,
                    requestOptions: .forTests(),
                    delegate: ResponseAccumulator(request: XCTUnwrap(maybeRequest))
                )
            )

            guard let requestBag = maybeRequestBag else { return XCTFail("Expected to get a request") }

            pool.executeRequest(requestBag)
            XCTAssertNoThrow(try requestBag.task.futureResult.wait())

            // Flakiness Alert: We check <= and >= instead of ==
            // While migration from h2 -> h1, one general purpose and one over flow connection
            // will be created, there's no guarantee as to whether the request is executed
            // after both are created.
            XCTAssertGreaterThanOrEqual(httpBin.createdConnections, 1)
            XCTAssertLessThanOrEqual(httpBin.createdConnections, 2)
        }
    }

    func testConnectionsForEventLoopRequirementsAreClosedH1Only() {
        let httpBin = HTTPBin()
        defer { XCTAssertNoThrow(try httpBin.shutdown()) }
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let eventLoop = eventLoopGroup.next()
        defer { XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully()) }

        let request = try! HTTPClient.Request(url: "http://localhost:\(httpBin.port)")
        let poolDelegate = TestDelegate(eventLoop: eventLoop)
        var configuration = HTTPClient.Configuration()
        configuration.httpVersion = .http1Only
        let pool = HTTPConnectionPool(
            eventLoopGroup: eventLoopGroup,
            sslContextCache: .init(),
            tlsConfiguration: .none,
            clientConfiguration: configuration,
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
            XCTAssertNoThrow(
                maybeRequestBag = try RequestBag(
                    request: XCTUnwrap(maybeRequest),
                    eventLoopPreference: .init(
                        .testOnly_exact(channelOn: eventLoopGroup.next(), delegateOn: eventLoopGroup.next())
                    ),
                    task: .init(eventLoop: eventLoop, logger: .init(label: "test")),
                    redirectHandler: nil,
                    connectionDeadline: .distantFuture,
                    requestOptions: .forTests(),
                    delegate: ResponseAccumulator(request: XCTUnwrap(maybeRequest))
                )
            )

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
            XCTAssertNoThrow(
                maybeRequestBag = try RequestBag(
                    request: XCTUnwrap(maybeRequest),
                    eventLoopPreference: .indifferent,
                    task: .init(eventLoop: eventLoopGroup.next(), logger: .init(label: "test")),
                    redirectHandler: nil,
                    connectionDeadline: .distantFuture,
                    requestOptions: .forTests(),
                    delegate: ResponseAccumulator(request: XCTUnwrap(maybeRequest))
                )
            )

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

        pool.executeRequest(requestBag)
        XCTAssertNoThrow(try eventLoop.scheduleTask(in: .seconds(1)) {}.futureResult.wait())
        requestBag.fail(HTTPClientError.cancelled)

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

    func testConnectionPoolStressResistanceHTTP1() {
        let numberOfRequestsPerThread = 1000
        let numberOfParallelWorkers = 8

        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 8)
        defer { XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully()) }

        let httpBin = HTTPBin()
        defer { XCTAssertNoThrow(try httpBin.shutdown()) }

        let logger = Logger(label: "Test")
        let request = try! HTTPClient.Request(url: "http://localhost:\(httpBin.port)")
        let poolDelegate = TestDelegate(eventLoop: eventLoopGroup.next())

        let pool = HTTPConnectionPool(
            eventLoopGroup: eventLoopGroup,
            sslContextCache: .init(),
            tlsConfiguration: nil,
            clientConfiguration: .init(),
            key: .init(request),
            delegate: poolDelegate,
            idGenerator: .init(),
            backgroundActivityLogger: logger
        )

        let dispatchGroup = DispatchGroup()
        for workerID in 0..<numberOfParallelWorkers {
            DispatchQueue(label: "\(#filePath):\(#line):worker-\(workerID)").async(group: dispatchGroup) {
                func makeRequest() {
                    let url = "http://localhost:\(httpBin.port)"
                    var maybeRequest: HTTPClient.Request?
                    var maybeRequestBag: RequestBag<ResponseAccumulator>?

                    XCTAssertNoThrow(maybeRequest = try HTTPClient.Request(url: url))
                    XCTAssertNoThrow(
                        maybeRequestBag = try RequestBag(
                            request: XCTUnwrap(maybeRequest),
                            eventLoopPreference: .indifferent,
                            task: .init(eventLoop: eventLoopGroup.next(), logger: logger),
                            redirectHandler: nil,
                            connectionDeadline: .now() + .seconds(5),
                            requestOptions: .forTests(),
                            delegate: ResponseAccumulator(request: XCTUnwrap(maybeRequest))
                        )
                    )

                    guard let requestBag = maybeRequestBag else { return XCTFail("Expected to get a request") }
                    pool.executeRequest(requestBag)

                    XCTAssertNoThrow(try requestBag.task.futureResult.wait())
                }

                for _ in 0..<numberOfRequestsPerThread {
                    makeRequest()
                }
            }
        }

        let timeout = DispatchTime.now() + .seconds(180)
        XCTAssertEqual(dispatchGroup.wait(timeout: timeout), .success)
        pool.shutdown()
        XCTAssertNoThrow(try poolDelegate.future.wait())
    }

    func testBackoffBehavesSensibly() throws {
        var backoff = HTTPConnectionPool.calculateBackoff(failedAttempt: 1)

        // The value should be 100ms±3ms
        XCTAssertLessThanOrEqual(
            (backoff - .milliseconds(100)).nanoseconds.magnitude,
            TimeAmount.milliseconds(3).nanoseconds.magnitude
        )

        // Should always increase
        // We stop when we get within the jitter of 60s, which is 1.8s
        var attempt = 1
        while backoff < (.seconds(60) - .milliseconds(1800)) {
            attempt += 1
            let newBackoff = HTTPConnectionPool.calculateBackoff(failedAttempt: attempt)

            XCTAssertGreaterThan(newBackoff, backoff)
            backoff = newBackoff
        }

        // Ok, now we should be able to do a hundred increments, and always hit 60s, plus or minus 1.8s of jitter.
        for offset in 0..<100 {
            XCTAssertLessThanOrEqual(
                (HTTPConnectionPool.calculateBackoff(failedAttempt: attempt + offset) - .seconds(60)).nanoseconds
                    .magnitude,
                TimeAmount.milliseconds(1800).nanoseconds.magnitude
            )
        }
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
