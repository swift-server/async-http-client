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

// TODO: remove @testable once we officially support HTTP/2
@testable import AsyncHTTPClient // Tests that really need @testable go into HTTP2ClientInternalTests.swift
#if canImport(Network)
    import Network
#endif
import Logging
import NIOCore
import NIOPosix
import NIOSSL
import XCTest

class HTTP2ClientTests: XCTestCase {
    func makeDefaultHTTPClient() -> HTTPClient {
        var tlsConfig = TLSConfiguration.makeClientConfiguration()
        tlsConfig.certificateVerification = .none
        return HTTPClient(
            eventLoopGroupProvider: .createNew,
            configuration: HTTPClient.Configuration(
                tlsConfiguration: tlsConfig,
                httpVersion: .automatic
            ),
            backgroundActivityLogger: Logger(label: "HTTPClient", factory: StreamLogHandler.standardOutput(label:))
        )
    }

    func testSimpleGet() {
        let bin = HTTPBin(.http2(compress: false))
        defer { XCTAssertNoThrow(try bin.shutdown()) }
        let client = self.makeDefaultHTTPClient()
        defer { XCTAssertNoThrow(try client.syncShutdown()) }
        var response: HTTPClient.Response?
        XCTAssertNoThrow(response = try client.get(url: "https://localhost:\(bin.port)/get").wait())

        XCTAssertEqual(.ok, response?.status)
        XCTAssertEqual(response?.version, .http2)
    }

    func testConcurrentRequests() {
        let bin = HTTPBin(.http2(compress: false))
        defer { XCTAssertNoThrow(try bin.shutdown()) }
        let client = self.makeDefaultHTTPClient()
        defer { XCTAssertNoThrow(try client.syncShutdown()) }
        let el = client.eventLoopGroup.next()
        let requestPromises = (0..<1000).map { _ in
            client.get(url: "https://localhost:\(bin.port)/get")
                .map { result -> Void in
                    XCTAssertEqual(result.version, .http2)
                }
        }
        XCTAssertNoThrow(try EventLoopFuture.whenAllComplete(requestPromises, on: el).wait())
    }

    func testConcurrentRequestsFromDifferentThreads() {
        let bin = HTTPBin(.http2(compress: false))
        defer { XCTAssertNoThrow(try bin.shutdown()) }
        let client = self.makeDefaultHTTPClient()
        defer { XCTAssertNoThrow(try client.syncShutdown()) }
        let numberOfWorkers = 20
        let numberOfRequestsPerWorkers = 20
        let allWorkersReady = DispatchSemaphore(value: 0)
        let allWorkersGo = DispatchSemaphore(value: 0)
        let allDone = DispatchGroup()

        let url = "https://localhost:\(bin.port)/get"

        var response: HTTPClient.Response?
        XCTAssertNoThrow(response = try client.get(url: url).wait())

        XCTAssertEqual(.ok, response?.status)
        XCTAssertEqual(response?.version, .http2)

        for w in 0..<numberOfWorkers {
            let q = DispatchQueue(label: "worker \(w)")
            q.async(group: allDone) {
                func go() {
                    allWorkersReady.signal() // tell the driver we're ready
                    allWorkersGo.wait() // wait for the driver to let us go

                    for _ in 0..<numberOfRequestsPerWorkers {
                        var response: HTTPClient.Response?
                        XCTAssertNoThrow(response = try client.get(url: url).wait())

                        XCTAssertEqual(.ok, response?.status)
                        XCTAssertEqual(response?.version, .http2)
                    }
                }
                go()
            }
        }

        for _ in 0..<numberOfWorkers {
            allWorkersReady.wait()
        }
        // now all workers should be waiting for the go signal

        for _ in 0..<numberOfWorkers {
            allWorkersGo.signal()
        }
        // all workers should be running, let's wait for them to finish
        allDone.wait()
    }

    func testConcurrentRequestsWorkWithRequiredEventLoop() {
        let numberOfWorkers = 20
        let numberOfRequestsPerWorkers = 20
        let allWorkersReady = DispatchSemaphore(value: 0)
        let allWorkersGo = DispatchSemaphore(value: 0)
        let allDone = DispatchGroup()

        let localHTTPBin = HTTPBin(.http2(compress: false))
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: numberOfWorkers)
        var tlsConfig = TLSConfiguration.makeClientConfiguration()
        tlsConfig.certificateVerification = .none
        let localClient = HTTPClient(
            eventLoopGroupProvider: .shared(elg),
            configuration: HTTPClient.Configuration(
                tlsConfiguration: tlsConfig,
                httpVersion: .automatic
            ),
            backgroundActivityLogger: Logger(label: "HTTPClient", factory: StreamLogHandler.standardOutput(label:))
        )
        defer {
            XCTAssertNoThrow(try localClient.syncShutdown())
            XCTAssertNoThrow(try localHTTPBin.shutdown())
        }

        let url = "https://localhost:\(localHTTPBin.port)/get"

        var response: HTTPClient.Response?
        XCTAssertNoThrow(response = try localClient.get(url: url).wait())

        XCTAssertEqual(.ok, response?.status)
        XCTAssertEqual(response?.version, .http2)

        for w in 0..<numberOfWorkers {
            let q = DispatchQueue(label: "worker \(w)")
            let el = elg.next()
            q.async(group: allDone) {
                func go() {
                    allWorkersReady.signal() // tell the driver we're ready
                    allWorkersGo.wait() // wait for the driver to let us go

                    for _ in 0..<numberOfRequestsPerWorkers {
                        var response: HTTPClient.Response?
                        let request = try! HTTPClient.Request(url: url)
                        let requestPromise = localClient
                            .execute(
                                request: request,
                                eventLoop: .delegateAndChannel(on: el)
                            )
                            .map { response -> HTTPClient.Response in
                                XCTAssertTrue(el.inEventLoop)
                                return response
                            }
                        XCTAssertNoThrow(response = try requestPromise.wait())

                        XCTAssertEqual(.ok, response?.status)
                        XCTAssertEqual(response?.version, .http2)
                    }
                }
                go()
            }
        }

        for _ in 0..<numberOfWorkers {
            allWorkersReady.wait()
        }
        // now all workers should be waiting for the go signal

        for _ in 0..<numberOfWorkers {
            allWorkersGo.signal()
        }
        // all workers should be running, let's wait for them to finish
        allDone.wait()
    }
}
