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
@testable import NIO
import NIOConcurrencyHelpers
import NIOFoundationCompat
import NIOHTTP1
import NIOHTTPCompression
import NIOSSL
import NIOTestUtils
import NIOTransportServices
import XCTest

class ConnectionPoolTests: XCTestCase {
    var eventLoop: EmbeddedEventLoop!
    var http1ConnectionProvider: HTTP1ConnectionProvider!

    struct TempError: Error {}

    func testPending() {
        var state = HTTP1ConnectionProvider.ConnectionsState(eventLoop: self.eventLoop)

        var snapshot = state.testsOnly_getInternalState()
        XCTAssertEqual(0, snapshot.availableConnections.count)
        XCTAssertEqual(0, snapshot.leasedConnections.count)
        XCTAssertEqual(0, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(0, snapshot.openedConnectionsCount)

        XCTAssertTrue(state.enqueue())

        snapshot = state.testsOnly_getInternalState()
        XCTAssertEqual(0, snapshot.availableConnections.count)
        XCTAssertEqual(0, snapshot.leasedConnections.count)
        XCTAssertEqual(0, snapshot.waiters.count)
        XCTAssertEqual(1, snapshot.pending)
        XCTAssertEqual(0, snapshot.openedConnectionsCount)
    }

    // MARK: - Acquire Tests

    func testAcquireWhenEmpty() {
        var state = HTTP1ConnectionProvider.ConnectionsState(eventLoop: self.eventLoop)

        var snapshot = state.testsOnly_getInternalState()
        XCTAssertEqual(0, snapshot.availableConnections.count)
        XCTAssertEqual(0, snapshot.leasedConnections.count)
        XCTAssertEqual(0, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(0, snapshot.openedConnectionsCount)

        XCTAssertTrue(state.enqueue())
        let action = state.acquire(waiter: .init(promise: self.eventLoop.makePromise(), setupComplete: self.eventLoop.makeSucceededFuture(()), preference: .indifferent))
        switch action {
        case .create(let waiter):
            waiter.promise.fail(TempError())
        default:
            XCTFail("Unexpected action: \(action)")
        }

        snapshot = state.testsOnly_getInternalState()
        XCTAssertEqual(0, snapshot.availableConnections.count)
        XCTAssertEqual(0, snapshot.leasedConnections.count)
        XCTAssertEqual(0, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(1, snapshot.openedConnectionsCount)
    }

    func testAcquireWhenAvailable() throws {
        let channel = EmbeddedChannel()

        var snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()

        let connection = Connection(channel: channel, provider: self.http1ConnectionProvider)
        snapshot.availableConnections.append(connection)
        snapshot.openedConnectionsCount = 1

        self.http1ConnectionProvider.state.testsOnly_setInternalState(snapshot)

        snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()
        XCTAssertEqual(1, snapshot.availableConnections.count)
        XCTAssertEqual(0, snapshot.leasedConnections.count)
        XCTAssertEqual(0, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(1, snapshot.openedConnectionsCount)

        XCTAssertTrue(self.http1ConnectionProvider.enqueue())

        let action = self.http1ConnectionProvider.state.acquire(waiter: .init(promise: self.eventLoop.makePromise(), setupComplete: self.eventLoop.makeSucceededFuture(()), preference: .indifferent))
        switch action {
        case .lease(let connection, let waiter):
            waiter.promise.succeed(connection)

            snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()
            XCTAssertEqual(0, snapshot.availableConnections.count)
            XCTAssertEqual(1, snapshot.leasedConnections.count)
            XCTAssertEqual(0, snapshot.waiters.count)
            XCTAssertEqual(0, snapshot.pending)
            XCTAssertEqual(1, snapshot.openedConnectionsCount)

            // cleanup, since we don't call release
            // this cleanup code needs to go and use HTTP1ConnectionProvider's API instead
            // (https://github.com/swift-server/async-http-client/issues/234)
            snapshot.openedConnectionsCount = 0
            self.http1ConnectionProvider.state.testsOnly_setInternalState(snapshot)
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    func testAcquireWhenUnavailable() throws {
        var snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()

        snapshot.openedConnectionsCount = 8
        self.http1ConnectionProvider.state.testsOnly_setInternalState(snapshot)

        snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()
        XCTAssertEqual(0, snapshot.availableConnections.count)
        XCTAssertEqual(0, snapshot.leasedConnections.count)
        XCTAssertEqual(0, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(8, snapshot.openedConnectionsCount)

        XCTAssertTrue(self.http1ConnectionProvider.enqueue())

        let action = self.http1ConnectionProvider.state.acquire(waiter: .init(promise: self.eventLoop.makePromise(), setupComplete: self.eventLoop.makeSucceededFuture(()), preference: .indifferent))
        switch action {
        case .none:
            snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()
            XCTAssertEqual(0, snapshot.availableConnections.count)
            XCTAssertEqual(0, snapshot.leasedConnections.count)
            XCTAssertEqual(1, snapshot.waiters.count)
            XCTAssertEqual(0, snapshot.pending)
            XCTAssertEqual(8, snapshot.openedConnectionsCount)
        default:
            XCTFail("Unexpected action: \(action)")
        }

        // cleanup
        // this cleanup code needs to go and use HTTP1ConnectionProvider's API instead
        // (https://github.com/swift-server/async-http-client/issues/234)
        snapshot.openedConnectionsCount = 0
        self.http1ConnectionProvider.state.testsOnly_setInternalState(snapshot)
    }

    // MARK: - Acquire on Specific EL Tests

    func testAcquireWhenEmptySpecificEL() {
        var state = HTTP1ConnectionProvider.ConnectionsState(eventLoop: self.eventLoop)
        var snapshot = state.testsOnly_getInternalState()

        XCTAssertEqual(0, snapshot.availableConnections.count)
        XCTAssertEqual(0, snapshot.leasedConnections.count)
        XCTAssertEqual(0, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(0, snapshot.openedConnectionsCount)

        XCTAssertTrue(state.enqueue())

        let action = state.acquire(waiter: .init(promise: self.eventLoop.makePromise(), setupComplete: self.eventLoop.makeSucceededFuture(()), preference: .delegateAndChannel(on: self.eventLoop)))
        switch action {
        case .create(let waiter):
            waiter.promise.fail(TempError())
        default:
            XCTFail("Unexpected action: \(action)")
        }

        snapshot = state.testsOnly_getInternalState()
        XCTAssertEqual(0, snapshot.availableConnections.count)
        XCTAssertEqual(0, snapshot.leasedConnections.count)
        XCTAssertEqual(0, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(1, snapshot.openedConnectionsCount)
    }

    func testAcquireWhenAvailableSpecificEL() throws {
        let channel = EmbeddedChannel()

        var snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()

        let connection = Connection(channel: channel, provider: self.http1ConnectionProvider)
        snapshot.availableConnections.append(connection)
        snapshot.openedConnectionsCount = 1

        self.http1ConnectionProvider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(1, snapshot.availableConnections.count)
        XCTAssertEqual(0, snapshot.leasedConnections.count)
        XCTAssertEqual(0, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(1, snapshot.openedConnectionsCount)

        XCTAssertTrue(self.http1ConnectionProvider.enqueue())

        let action = self.http1ConnectionProvider.state.acquire(waiter: .init(promise: channel.eventLoop.makePromise(), setupComplete: channel.eventLoop.makeSucceededFuture(()), preference: .delegateAndChannel(on: channel.eventLoop)))
        switch action {
        case .lease(let connection, let waiter):
            waiter.promise.succeed(connection)

            snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()
            XCTAssertEqual(0, snapshot.availableConnections.count)
            XCTAssertEqual(1, snapshot.leasedConnections.count)
            XCTAssertEqual(0, snapshot.waiters.count)
            XCTAssertEqual(0, snapshot.pending)
            XCTAssertEqual(1, snapshot.openedConnectionsCount)

            // cleanup, since we don't call release
            // this cleanup code needs to go and use HTTP1ConnectionProvider's API instead
            // (https://github.com/swift-server/async-http-client/issues/234)
            snapshot.openedConnectionsCount = 0
            self.http1ConnectionProvider.state.testsOnly_setInternalState(snapshot)
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    func testAcquireReplace() throws {
        let channel = EmbeddedChannel()

        var snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()

        let connection = Connection(channel: channel, provider: self.http1ConnectionProvider)
        snapshot.availableConnections.append(connection)
        snapshot.openedConnectionsCount = 8

        self.http1ConnectionProvider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(1, snapshot.availableConnections.count)
        XCTAssertEqual(0, snapshot.leasedConnections.count)
        XCTAssertEqual(0, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(8, snapshot.openedConnectionsCount)

        XCTAssertTrue(self.http1ConnectionProvider.enqueue())

        let action = self.http1ConnectionProvider.state.acquire(waiter: .init(promise: self.eventLoop.makePromise(), setupComplete: self.eventLoop.makeSucceededFuture(()), preference: .delegateAndChannel(on: self.eventLoop)))
        switch action {
        case .replace(_, let waiter):
            waiter.promise.fail(TempError())

            snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()
            XCTAssertEqual(0, snapshot.availableConnections.count)
            XCTAssertEqual(0, snapshot.leasedConnections.count)
            XCTAssertEqual(0, snapshot.waiters.count)
            XCTAssertEqual(0, snapshot.pending)
            XCTAssertEqual(8, snapshot.openedConnectionsCount)
        default:
            XCTFail("Unexpected action: \(action)")
        }

        // cleanup
        // this cleanup code needs to go and use HTTP1ConnectionProvider's API instead
        // (https://github.com/swift-server/async-http-client/issues/234)
        snapshot.openedConnectionsCount = 0
        self.http1ConnectionProvider.state.testsOnly_setInternalState(snapshot)
    }

    func testAcquireWhenUnavailableSpecificEL() throws {
        var snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()

        snapshot.openedConnectionsCount = 8

        self.http1ConnectionProvider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(0, snapshot.availableConnections.count)
        XCTAssertEqual(0, snapshot.leasedConnections.count)
        XCTAssertEqual(0, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(8, snapshot.openedConnectionsCount)

        XCTAssertTrue(self.http1ConnectionProvider.enqueue())

        let action = self.http1ConnectionProvider.state.acquire(waiter: .init(promise: self.eventLoop.makePromise(), setupComplete: self.eventLoop.makeSucceededFuture(()), preference: .delegateAndChannel(on: self.eventLoop)))
        switch action {
        case .none:
            snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()
            XCTAssertEqual(0, snapshot.availableConnections.count)
            XCTAssertEqual(0, snapshot.leasedConnections.count)
            XCTAssertEqual(1, snapshot.waiters.count)
            XCTAssertEqual(0, snapshot.pending)
            XCTAssertEqual(8, snapshot.openedConnectionsCount)
        default:
            XCTFail("Unexpected action: \(action)")
        }

        // cleanup
        // this cleanup code needs to go and use HTTP1ConnectionProvider's API instead
        // (https://github.com/swift-server/async-http-client/issues/234)
        snapshot.openedConnectionsCount = 0
        self.http1ConnectionProvider.state.testsOnly_setInternalState(snapshot)
    }

    // MARK: - Acquire Errors Tests

    func testAcquireWhenClosed() {
        var state = HTTP1ConnectionProvider.ConnectionsState(eventLoop: self.eventLoop)
        var snapshot = state.testsOnly_getInternalState()
        snapshot.state = .closed
        state.testsOnly_setInternalState(snapshot)

        XCTAssertFalse(state.enqueue())

        let promise = self.eventLoop.makePromise(of: Connection.self)
        let action = state.acquire(waiter: .init(promise: promise, setupComplete: self.eventLoop.makeSucceededFuture(()), preference: .indifferent))
        switch action {
        case .fail(let waiter, let error):
            waiter.promise.fail(error)
        default:
            XCTFail("Unexpected action: \(action)")
        }
        print(state.testsOnly_getInternalState())
    }

    // MARK: - Release Tests

    func testReleaseAliveConnectionEmptyQueue() throws {
        let channel = ActiveChannel(eventLoop: self.eventLoop)
        var snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()

        snapshot.pending = 0
        snapshot.openedConnectionsCount = 1
        let connection = Connection(channel: channel, provider: self.http1ConnectionProvider)
        snapshot.leasedConnections.insert(ConnectionKey(connection))

        self.http1ConnectionProvider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(0, snapshot.availableConnections.count)
        XCTAssertEqual(1, snapshot.leasedConnections.count)
        XCTAssertEqual(0, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(1, snapshot.openedConnectionsCount)

        let action = self.http1ConnectionProvider.state.release(connection: connection, closing: false)
        switch action {
        case .park:
            snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()
            XCTAssertEqual(1, snapshot.availableConnections.count)
            XCTAssertEqual(0, snapshot.leasedConnections.count)
            XCTAssertEqual(0, snapshot.waiters.count)
            XCTAssertEqual(0, snapshot.pending)
            XCTAssertEqual(1, snapshot.openedConnectionsCount)

            // cleanup
            // this cleanup code needs to go and use HTTP1ConnectionProvider's API instead
            // (https://github.com/swift-server/async-http-client/issues/234)
            snapshot.openedConnectionsCount = 0
            self.http1ConnectionProvider.state.testsOnly_setInternalState(snapshot)
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    func testReleaseAliveButClosingConnectionEmptyQueue() throws {
        let channel = ActiveChannel(eventLoop: self.eventLoop)

        var snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()

        snapshot.pending = 0
        snapshot.openedConnectionsCount = 1
        let connection = Connection(channel: channel, provider: self.http1ConnectionProvider)
        snapshot.leasedConnections.insert(ConnectionKey(connection))

        self.http1ConnectionProvider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(0, snapshot.availableConnections.count)
        XCTAssertEqual(1, snapshot.leasedConnections.count)
        XCTAssertEqual(0, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(1, snapshot.openedConnectionsCount)

        let action = self.http1ConnectionProvider.state.release(connection: connection, closing: true)
        switch action {
        case .closeProvider:
            snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()
            XCTAssertEqual(0, snapshot.availableConnections.count)
            XCTAssertEqual(0, snapshot.leasedConnections.count)
            XCTAssertEqual(0, snapshot.waiters.count)
            XCTAssertEqual(0, snapshot.pending)
            XCTAssertEqual(0, snapshot.openedConnectionsCount)
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    func testReleaseInactiveConnectionEmptyQueue() throws {
        let channel = EmbeddedChannel()

        var snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()

        snapshot.pending = 0
        snapshot.openedConnectionsCount = 1
        let connection = Connection(channel: channel, provider: self.http1ConnectionProvider)
        snapshot.leasedConnections.insert(ConnectionKey(connection))

        self.http1ConnectionProvider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(0, snapshot.availableConnections.count)
        XCTAssertEqual(1, snapshot.leasedConnections.count)
        XCTAssertEqual(0, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(1, snapshot.openedConnectionsCount)

        let action = self.http1ConnectionProvider.state.release(connection: connection, closing: true)
        switch action {
        case .closeProvider:
            snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()
            XCTAssertEqual(0, snapshot.availableConnections.count)
            XCTAssertEqual(0, snapshot.leasedConnections.count)
            XCTAssertEqual(0, snapshot.waiters.count)
            XCTAssertEqual(0, snapshot.pending)
            XCTAssertEqual(0, snapshot.openedConnectionsCount)
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    func testReleaseInactiveConnectionEmptyQueueHasConnections() throws {
        let channel = EmbeddedChannel()

        var snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()

        snapshot.pending = 0
        snapshot.openedConnectionsCount = 2
        let connection = Connection(channel: channel, provider: self.http1ConnectionProvider)
        snapshot.leasedConnections.insert(ConnectionKey(connection))
        let available = Connection(channel: channel, provider: self.http1ConnectionProvider)
        snapshot.availableConnections.append(available)

        self.http1ConnectionProvider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(1, snapshot.availableConnections.count)
        XCTAssertEqual(1, snapshot.leasedConnections.count)
        XCTAssertEqual(0, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(2, snapshot.openedConnectionsCount)

        let action = self.http1ConnectionProvider.state.release(connection: connection, closing: true)
        switch action {
        case .none:
            snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()
            XCTAssertEqual(1, snapshot.availableConnections.count)
            XCTAssertEqual(0, snapshot.leasedConnections.count)
            XCTAssertEqual(0, snapshot.waiters.count)
            XCTAssertEqual(0, snapshot.pending)
            XCTAssertEqual(1, snapshot.openedConnectionsCount)

            // cleanup
            // this cleanup code needs to go and use HTTP1ConnectionProvider's API instead
            // (https://github.com/swift-server/async-http-client/issues/234)
            snapshot.openedConnectionsCount = 0
            self.http1ConnectionProvider.state.testsOnly_setInternalState(snapshot)
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    func testReleaseAliveConnectionHasWaiter() throws {
        let channel = ActiveChannel(eventLoop: self.eventLoop)

        var snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()

        snapshot.pending = 0
        snapshot.openedConnectionsCount = 1
        let connection = Connection(channel: channel, provider: self.http1ConnectionProvider)
        snapshot.leasedConnections.insert(ConnectionKey(connection))
        snapshot.waiters.append(.init(promise: channel.eventLoop.makePromise(), setupComplete: channel.eventLoop.makeSucceededFuture(()), preference: .indifferent))

        self.http1ConnectionProvider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(0, snapshot.availableConnections.count)
        XCTAssertEqual(1, snapshot.leasedConnections.count)
        XCTAssertEqual(1, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(1, snapshot.openedConnectionsCount)

        let action = self.http1ConnectionProvider.state.release(connection: connection, closing: false)
        switch action {
        case .lease(let connection, let waiter):
            // XCTAssertTrue(connection.isInUse)
            snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()
            XCTAssertEqual(0, snapshot.availableConnections.count)
            XCTAssertEqual(1, snapshot.leasedConnections.count)
            XCTAssertEqual(0, snapshot.waiters.count)
            XCTAssertEqual(0, snapshot.pending)
            XCTAssertEqual(1, snapshot.openedConnectionsCount)

            // cleanup
            // this cleanup code needs to go and use HTTP1ConnectionProvider's API instead
            // (https://github.com/swift-server/async-http-client/issues/234)
            waiter.promise.succeed(connection)
            snapshot.openedConnectionsCount = 0
            self.http1ConnectionProvider.state.testsOnly_setInternalState(snapshot)
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    func testReleaseInactiveConnectionHasWaitersNoConnections() throws {
        let channel = EmbeddedChannel()

        var snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()

        snapshot.pending = 0
        snapshot.openedConnectionsCount = 1
        let connection = Connection(channel: channel, provider: self.http1ConnectionProvider)
        snapshot.leasedConnections.insert(ConnectionKey(connection))
        snapshot.waiters.append(.init(promise: channel.eventLoop.makePromise(), setupComplete: channel.eventLoop.makeSucceededFuture(()), preference: .indifferent))

        self.http1ConnectionProvider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(0, snapshot.availableConnections.count)
        XCTAssertEqual(1, snapshot.leasedConnections.count)
        XCTAssertEqual(1, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(1, snapshot.openedConnectionsCount)

        let action = self.http1ConnectionProvider.state.release(connection: connection, closing: true)
        switch action {
        case .create(let waiter):
            snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()
            XCTAssertEqual(0, snapshot.availableConnections.count)
            XCTAssertEqual(0, snapshot.leasedConnections.count)
            XCTAssertEqual(0, snapshot.waiters.count)
            XCTAssertEqual(0, snapshot.pending)
            XCTAssertEqual(1, snapshot.openedConnectionsCount)

            // cleanup
            // this cleanup code needs to go and use HTTP1ConnectionProvider's API instead
            // (https://github.com/swift-server/async-http-client/issues/234)
            waiter.promise.fail(TempError())
            snapshot.openedConnectionsCount = 0
            self.http1ConnectionProvider.state.testsOnly_setInternalState(snapshot)
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    func testReleaseInactiveConnectionHasWaitersHasConnections() throws {
        let channel = EmbeddedChannel()

        var snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()

        snapshot.pending = 0
        snapshot.openedConnectionsCount = 2
        let connection = Connection(channel: channel, provider: self.http1ConnectionProvider)
        snapshot.leasedConnections.insert(ConnectionKey(connection))
        snapshot.waiters.append(.init(promise: channel.eventLoop.makePromise(), setupComplete: channel.eventLoop.makeSucceededFuture(()), preference: .indifferent))

        let available = Connection(channel: channel, provider: self.http1ConnectionProvider)
        snapshot.availableConnections.append(available)

        self.http1ConnectionProvider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(1, snapshot.availableConnections.count)
        XCTAssertEqual(1, snapshot.leasedConnections.count)
        XCTAssertEqual(1, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(2, snapshot.openedConnectionsCount)

        let action = self.http1ConnectionProvider.state.release(connection: connection, closing: false)
        switch action {
        case .lease(let connection, let waiter):
            snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()
            XCTAssertEqual(0, snapshot.availableConnections.count)
            XCTAssertEqual(1, snapshot.leasedConnections.count)
            XCTAssertEqual(0, snapshot.waiters.count)
            XCTAssertEqual(0, snapshot.pending)
            XCTAssertEqual(1, snapshot.openedConnectionsCount)

            // cleanup
            waiter.promise.succeed(connection)
            snapshot.openedConnectionsCount = 0
            self.http1ConnectionProvider.state.testsOnly_setInternalState(snapshot)
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    // MARK: - Release on Specific EL Tests

    func testReleaseAliveConnectionSameELHasWaiterSpecificEL() throws {
        let channel = ActiveChannel(eventLoop: self.eventLoop)

        var snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()

        snapshot.pending = 0
        snapshot.openedConnectionsCount = 1
        let connection = Connection(channel: channel, provider: self.http1ConnectionProvider)
        snapshot.leasedConnections.insert(ConnectionKey(connection))
        snapshot.waiters.append(.init(promise: channel.eventLoop.makePromise(), setupComplete: channel.eventLoop.makeSucceededFuture(()), preference: .delegateAndChannel(on: channel.eventLoop)))

        self.http1ConnectionProvider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(0, snapshot.availableConnections.count)
        XCTAssertEqual(1, snapshot.leasedConnections.count)
        XCTAssertEqual(1, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(1, snapshot.openedConnectionsCount)

        let action = self.http1ConnectionProvider.state.release(connection: connection, closing: false)
        switch action {
        case .lease(let connection, let waiter):
            snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()
            XCTAssertTrue(snapshot.leasedConnections.contains(ConnectionKey(connection)))
            XCTAssertEqual(0, snapshot.availableConnections.count)
            XCTAssertEqual(1, snapshot.leasedConnections.count)
            XCTAssertEqual(0, snapshot.waiters.count)
            XCTAssertEqual(0, snapshot.pending)
            XCTAssertEqual(1, snapshot.openedConnectionsCount)

            // cleanup
            waiter.promise.succeed(connection)
            snapshot.openedConnectionsCount = 0
            self.http1ConnectionProvider.state.testsOnly_setInternalState(snapshot)
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    func testReleaseAliveConnectionDifferentELNoSameELConnectionsHasWaiterSpecificEL() throws {
        let differentEL = EmbeddedEventLoop()
        defer {
            XCTAssertNoThrow(try differentEL.syncShutdownGracefully())
        }
        let channel = ActiveChannel(eventLoop: differentEL) // Channel on different EL, that's important for the test.
        var snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()

        snapshot.pending = 0
        snapshot.openedConnectionsCount = 1
        let connection = Connection(channel: channel, provider: self.http1ConnectionProvider)
        snapshot.leasedConnections.insert(ConnectionKey(connection))
        snapshot.waiters.append(.init(promise: channel.eventLoop.makePromise(of: Connection.self),
                                      setupComplete: self.eventLoop.makeSucceededFuture(()),
                                      preference: .delegateAndChannel(on: self.eventLoop)))

        self.http1ConnectionProvider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(0, snapshot.availableConnections.count)
        XCTAssertEqual(1, snapshot.leasedConnections.count)
        XCTAssertEqual(1, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(1, snapshot.openedConnectionsCount)

        let action = self.http1ConnectionProvider.state.release(connection: connection, closing: false)
        switch action {
        case .parkAnd(let connection, .create(let waiter)):
            snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()
            XCTAssertFalse(snapshot.leasedConnections.contains(ConnectionKey(connection)))
            XCTAssertEqual(1, snapshot.availableConnections.count)
            XCTAssertEqual(0, snapshot.leasedConnections.count)
            XCTAssertEqual(0, snapshot.waiters.count)
            XCTAssertEqual(0, snapshot.pending)
            XCTAssertEqual(2, snapshot.openedConnectionsCount)

            // cleanup
            waiter.promise.succeed(connection)
            snapshot.openedConnectionsCount = 0
            self.http1ConnectionProvider.state.testsOnly_setInternalState(snapshot)
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    func testReleaseAliveConnectionDifferentELHasSameELConnectionsHasWaiterSpecificEL() throws {
        let channel = ActiveChannel(eventLoop: self.eventLoop)
        let otherChannel = EmbeddedChannel()

        var snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()

        snapshot.pending = 0
        snapshot.openedConnectionsCount = 2
        let connection = Connection(channel: channel, provider: self.http1ConnectionProvider)
        snapshot.leasedConnections.insert(ConnectionKey(connection))
        snapshot.waiters.append(.init(promise: channel.eventLoop.makePromise(), setupComplete: channel.eventLoop.makeSucceededFuture(()), preference: .delegateAndChannel(on: otherChannel.eventLoop)))

        let available = Connection(channel: otherChannel, provider: self.http1ConnectionProvider)
        snapshot.availableConnections.append(available)

        self.http1ConnectionProvider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(1, snapshot.availableConnections.count)
        XCTAssertEqual(1, snapshot.leasedConnections.count)
        XCTAssertEqual(1, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(2, snapshot.openedConnectionsCount)

        let action = self.http1ConnectionProvider.state.release(connection: connection, closing: false)
        switch action {
        case .parkAnd(let connection, .lease(let replacement, let waiter)):
            snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()
            XCTAssertFalse(snapshot.leasedConnections.contains(ConnectionKey(connection)))
            XCTAssertTrue(snapshot.leasedConnections.contains(ConnectionKey(replacement)))
            XCTAssertEqual(1, snapshot.availableConnections.count)
            XCTAssertEqual(1, snapshot.leasedConnections.count)
            XCTAssertEqual(0, snapshot.waiters.count)
            XCTAssertEqual(0, snapshot.pending)
            XCTAssertEqual(2, snapshot.openedConnectionsCount)

            // cleanup
            waiter.promise.succeed(replacement)
            snapshot.openedConnectionsCount = 0
            self.http1ConnectionProvider.state.testsOnly_setInternalState(snapshot)
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    func testReleaseAliveConnectionDifferentELNoSameELConnectionsOnLimitHasWaiterSpecificEL() throws {
        let channel = ActiveChannel(eventLoop: self.eventLoop)
        let otherChannel = EmbeddedChannel()

        var snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()

        snapshot.pending = 0
        snapshot.openedConnectionsCount = 8
        let connection = Connection(channel: channel, provider: self.http1ConnectionProvider)
        snapshot.leasedConnections.insert(ConnectionKey(connection))
        snapshot.waiters.append(.init(promise: channel.eventLoop.makePromise(), setupComplete: channel.eventLoop.makeSucceededFuture(()), preference: .delegateAndChannel(on: otherChannel.eventLoop)))

        let available = Connection(channel: channel, provider: self.http1ConnectionProvider)
        snapshot.availableConnections.append(available)

        self.http1ConnectionProvider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(1, snapshot.availableConnections.count)
        XCTAssertEqual(1, snapshot.leasedConnections.count)
        XCTAssertEqual(1, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(8, snapshot.openedConnectionsCount)

        let action = self.http1ConnectionProvider.state.release(connection: connection, closing: false)
        switch action {
        case .replace(let connection, let waiter):
            snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()
            XCTAssertTrue(snapshot.leasedConnections.contains(ConnectionKey(connection)))
            XCTAssertEqual(1, snapshot.availableConnections.count)
            XCTAssertEqual(1, snapshot.leasedConnections.count)
            XCTAssertEqual(0, snapshot.waiters.count)
            XCTAssertEqual(0, snapshot.pending)
            XCTAssertEqual(8, snapshot.openedConnectionsCount)

            // cleanup
            waiter.promise.fail(TempError())
            snapshot.openedConnectionsCount = 0
            self.http1ConnectionProvider.state.testsOnly_setInternalState(snapshot)
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    func testReleaseInactiveConnectionHasWaitersHasSameELConnectionsSpecificEL() throws {
        let channel = EmbeddedChannel()
        let otherChannel = EmbeddedChannel()

        var snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()

        snapshot.pending = 0
        snapshot.openedConnectionsCount = 2
        let connection = Connection(channel: channel, provider: self.http1ConnectionProvider)
        snapshot.leasedConnections.insert(ConnectionKey(connection))
        snapshot.waiters.append(.init(promise: channel.eventLoop.makePromise(), setupComplete: channel.eventLoop.makeSucceededFuture(()), preference: .delegateAndChannel(on: otherChannel.eventLoop)))

        let available = Connection(channel: otherChannel, provider: self.http1ConnectionProvider)
        snapshot.availableConnections.append(available)

        self.http1ConnectionProvider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(1, snapshot.availableConnections.count)
        XCTAssertEqual(1, snapshot.leasedConnections.count)
        XCTAssertEqual(1, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(2, snapshot.openedConnectionsCount)

        let action = self.http1ConnectionProvider.state.release(connection: connection, closing: false)
        switch action {
        case .lease(let connection, let waiter):
            snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()
            XCTAssertTrue(connection === available)
            XCTAssertTrue(snapshot.leasedConnections.contains(ConnectionKey(connection)))
            XCTAssertEqual(0, snapshot.availableConnections.count)
            XCTAssertEqual(1, snapshot.leasedConnections.count)
            XCTAssertEqual(0, snapshot.waiters.count)
            XCTAssertEqual(0, snapshot.pending)
            XCTAssertEqual(1, snapshot.openedConnectionsCount)

            // cleanup
            waiter.promise.succeed(connection)
            snapshot.openedConnectionsCount = 0
            self.http1ConnectionProvider.state.testsOnly_setInternalState(snapshot)
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    func testReleaseInactiveConnectionHasWaitersNoSameELConnectionsSpecificEL() throws {
        let channel = EmbeddedChannel()
        let otherChannel = EmbeddedChannel()

        var snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()

        snapshot.pending = 0
        snapshot.openedConnectionsCount = 2
        let connection = Connection(channel: channel, provider: self.http1ConnectionProvider)
        snapshot.leasedConnections.insert(ConnectionKey(connection))
        snapshot.waiters.append(.init(promise: channel.eventLoop.makePromise(), setupComplete: channel.eventLoop.makeSucceededFuture(()), preference: .delegateAndChannel(on: otherChannel.eventLoop)))

        let available = Connection(channel: channel, provider: self.http1ConnectionProvider)
        snapshot.availableConnections.append(available)

        self.http1ConnectionProvider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(1, snapshot.availableConnections.count)
        XCTAssertEqual(1, snapshot.leasedConnections.count)
        XCTAssertEqual(1, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(2, snapshot.openedConnectionsCount)

        let action = self.http1ConnectionProvider.state.release(connection: connection, closing: false)
        switch action {
        case .create(let waiter):
            snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()
            XCTAssertEqual(1, snapshot.availableConnections.count)
            XCTAssertEqual(0, snapshot.leasedConnections.count)
            XCTAssertEqual(0, snapshot.waiters.count)
            XCTAssertEqual(0, snapshot.pending)
            XCTAssertEqual(2, snapshot.openedConnectionsCount)

            // cleanup
            waiter.promise.fail(TempError())
            snapshot.openedConnectionsCount = 0
            self.http1ConnectionProvider.state.testsOnly_setInternalState(snapshot)
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    // MARK: - Next Waiter Tests

    func testNextWaiterEmptyQueue() throws {
        var snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()

        snapshot.pending = 0
        self.http1ConnectionProvider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(0, snapshot.availableConnections.count)
        XCTAssertEqual(0, snapshot.leasedConnections.count)
        XCTAssertEqual(0, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(0, snapshot.openedConnectionsCount)

        let action = self.http1ConnectionProvider.state.processNextWaiter()
        switch action {
        case .closeProvider:
            snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()
            XCTAssertEqual(0, snapshot.availableConnections.count)
            XCTAssertEqual(0, snapshot.leasedConnections.count)
            XCTAssertEqual(0, snapshot.waiters.count)
            XCTAssertEqual(0, snapshot.pending)
            XCTAssertEqual(0, snapshot.openedConnectionsCount)
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    func testNextWaiterEmptyQueueHasConnections() throws {
        let channel = ActiveChannel(eventLoop: self.eventLoop)
        var snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()

        snapshot.pending = 0
        snapshot.openedConnectionsCount = 1

        let available = Connection(channel: channel, provider: self.http1ConnectionProvider)
        snapshot.availableConnections.append(available)

        self.http1ConnectionProvider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(1, snapshot.availableConnections.count)
        XCTAssertEqual(0, snapshot.leasedConnections.count)
        XCTAssertEqual(0, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(1, snapshot.openedConnectionsCount)

        let action = self.http1ConnectionProvider.state.processNextWaiter()
        switch action {
        case .none:
            snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()
            XCTAssertEqual(1, snapshot.availableConnections.count)
            XCTAssertEqual(0, snapshot.leasedConnections.count)
            XCTAssertEqual(0, snapshot.waiters.count)
            XCTAssertEqual(0, snapshot.pending)
            XCTAssertEqual(1, snapshot.openedConnectionsCount)

            // cleanup
            // this cleanup code needs to go and use HTTP1ConnectionProvider's API instead
            // (https://github.com/swift-server/async-http-client/issues/234)
            XCTAssertNoThrow(try available.close().wait())
            snapshot.availableConnections.removeAll()
            snapshot.openedConnectionsCount = 0
            self.http1ConnectionProvider.state.testsOnly_setInternalState(snapshot)
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    func testNextWaiterHasWaitersHasConnections() throws {
        let channel = EmbeddedChannel()

        var snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()

        snapshot.pending = 0
        snapshot.openedConnectionsCount = 1
        snapshot.waiters.append(.init(promise: channel.eventLoop.makePromise(), setupComplete: channel.eventLoop.makeSucceededFuture(()), preference: .indifferent))

        let available = Connection(channel: channel, provider: self.http1ConnectionProvider)
        snapshot.availableConnections.append(available)

        self.http1ConnectionProvider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(1, snapshot.availableConnections.count)
        XCTAssertEqual(0, snapshot.leasedConnections.count)
        XCTAssertEqual(1, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(1, snapshot.openedConnectionsCount)

        let action = self.http1ConnectionProvider.state.processNextWaiter()
        switch action {
        case .lease(let connection, let waiter):
            snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()
            XCTAssertTrue(snapshot.leasedConnections.contains(ConnectionKey(connection)))
            XCTAssertEqual(0, snapshot.availableConnections.count)
            XCTAssertEqual(1, snapshot.leasedConnections.count)
            XCTAssertEqual(0, snapshot.waiters.count)
            XCTAssertEqual(0, snapshot.pending)
            XCTAssertEqual(1, snapshot.openedConnectionsCount)

            // cleanup
            // this cleanup code needs to go and use HTTP1ConnectionProvider's API instead
            // (https://github.com/swift-server/async-http-client/issues/234)
            waiter.promise.succeed(connection)
            snapshot.openedConnectionsCount = 0
            self.http1ConnectionProvider.state.testsOnly_setInternalState(snapshot)
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    func testNextWaiterHasWaitersHasSameELConnectionsSpecificEL() throws {
        let channel = EmbeddedChannel()

        var snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()

        snapshot.pending = 0
        snapshot.openedConnectionsCount = 1
        snapshot.waiters.append(.init(promise: channel.eventLoop.makePromise(), setupComplete: channel.eventLoop.makeSucceededFuture(()), preference: .delegateAndChannel(on: channel.eventLoop)))

        let available = Connection(channel: channel, provider: self.http1ConnectionProvider)
        snapshot.availableConnections.append(available)

        self.http1ConnectionProvider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(1, snapshot.availableConnections.count)
        XCTAssertEqual(0, snapshot.leasedConnections.count)
        XCTAssertEqual(1, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(1, snapshot.openedConnectionsCount)

        let action = self.http1ConnectionProvider.state.processNextWaiter()
        switch action {
        case .lease(let connection, let waiter):
            var snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()
            XCTAssertTrue(snapshot.leasedConnections.contains(ConnectionKey(connection)))
            XCTAssertEqual(0, snapshot.availableConnections.count)
            XCTAssertEqual(1, snapshot.leasedConnections.count)
            XCTAssertEqual(0, snapshot.waiters.count)
            XCTAssertEqual(0, snapshot.pending)
            XCTAssertEqual(1, snapshot.openedConnectionsCount)

            // cleanup
            // this cleanup code needs to go and use HTTP1ConnectionProvider's API instead
            // (https://github.com/swift-server/async-http-client/issues/234)
            waiter.promise.succeed(connection)
            snapshot.openedConnectionsCount = 0
            self.http1ConnectionProvider.state.testsOnly_setInternalState(snapshot)
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    func testNextWaiterHasWaitersHasDifferentELConnectionsSpecificEL() throws {
        let channel = EmbeddedChannel()

        var snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()

        snapshot.pending = 0
        snapshot.openedConnectionsCount = 1
        snapshot.waiters.append(.init(promise: channel.eventLoop.makePromise(), setupComplete: self.eventLoop.makeSucceededFuture(()), preference: .delegateAndChannel(on: self.eventLoop)))

        let available = Connection(channel: channel, provider: self.http1ConnectionProvider)
        snapshot.availableConnections.append(available)

        self.http1ConnectionProvider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(1, snapshot.availableConnections.count)
        XCTAssertEqual(0, snapshot.leasedConnections.count)
        XCTAssertEqual(1, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(1, snapshot.openedConnectionsCount)

        let action = self.http1ConnectionProvider.state.processNextWaiter()
        switch action {
        case .create(let waiter):
            snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()
            XCTAssertEqual(1, snapshot.availableConnections.count)
            XCTAssertEqual(0, snapshot.leasedConnections.count)
            XCTAssertEqual(0, snapshot.waiters.count)
            XCTAssertEqual(0, snapshot.pending)
            XCTAssertEqual(2, snapshot.openedConnectionsCount)

            // cleanup
            // this cleanup code needs to go and use HTTP1ConnectionProvider's API instead
            // (https://github.com/swift-server/async-http-client/issues/234)
            waiter.promise.fail(TempError())
            snapshot.openedConnectionsCount = 0
            self.http1ConnectionProvider.state.testsOnly_setInternalState(snapshot)
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    // MARK: - Timeout and Remote Close Tests

    func testTimeoutLeasedConnection() throws {
        let channel = EmbeddedChannel()

        var snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()

        let connection = Connection(channel: channel, provider: self.http1ConnectionProvider)
        snapshot.pending = 0
        snapshot.openedConnectionsCount = 1
        snapshot.leasedConnections.insert(ConnectionKey(connection))

        self.http1ConnectionProvider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(0, snapshot.availableConnections.count)
        XCTAssertEqual(1, snapshot.leasedConnections.count)
        XCTAssertEqual(0, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(1, snapshot.openedConnectionsCount)

        let action = self.http1ConnectionProvider.state.timeout(connection: connection)
        switch action {
        case .none:
            snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()
            XCTAssertEqual(0, snapshot.availableConnections.count)
            XCTAssertEqual(1, snapshot.leasedConnections.count)
            XCTAssertEqual(0, snapshot.waiters.count)
            XCTAssertEqual(0, snapshot.pending)
            XCTAssertEqual(1, snapshot.openedConnectionsCount)
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    func testTimeoutAvailableConnection() throws {
        let channel = EmbeddedChannel()

        var snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()

        let connection = Connection(channel: channel, provider: self.http1ConnectionProvider)
        snapshot.pending = 0
        snapshot.openedConnectionsCount = 1
        snapshot.availableConnections.append(connection)

        self.http1ConnectionProvider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(1, snapshot.availableConnections.count)
        XCTAssertEqual(0, snapshot.leasedConnections.count)
        XCTAssertEqual(0, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(1, snapshot.openedConnectionsCount)

        let action = self.http1ConnectionProvider.state.timeout(connection: connection)
        switch action {
        case .closeAnd(_, let after):
            switch after {
            case .closeProvider:
                break
            default:
                XCTFail("Unexpected action: \(action)")
            }
            snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()
            XCTAssertEqual(0, snapshot.availableConnections.count)
            XCTAssertEqual(0, snapshot.leasedConnections.count)
            XCTAssertEqual(0, snapshot.waiters.count)
            XCTAssertEqual(0, snapshot.pending)
            XCTAssertEqual(0, snapshot.openedConnectionsCount)
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    func testRemoteClosedLeasedConnection() throws {
        let channel = EmbeddedChannel()

        var snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()

        let connection = Connection(channel: channel, provider: self.http1ConnectionProvider)
        snapshot.pending = 0
        snapshot.openedConnectionsCount = 1
        snapshot.leasedConnections.insert(ConnectionKey(connection))

        self.http1ConnectionProvider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(0, snapshot.availableConnections.count)
        XCTAssertEqual(1, snapshot.leasedConnections.count)
        XCTAssertEqual(0, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(1, snapshot.openedConnectionsCount)

        let action = self.http1ConnectionProvider.state.remoteClosed(connection: connection)
        switch action {
        case .none:
            snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()
            XCTAssertEqual(0, snapshot.availableConnections.count)
            XCTAssertEqual(1, snapshot.leasedConnections.count)
            XCTAssertEqual(0, snapshot.waiters.count)
            XCTAssertEqual(0, snapshot.pending)
            XCTAssertEqual(1, snapshot.openedConnectionsCount)
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    func testRemoteClosedAvailableConnection() throws {
        let channel = EmbeddedChannel()

        var snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()

        let connection = Connection(channel: channel, provider: self.http1ConnectionProvider)
        snapshot.pending = 0
        snapshot.openedConnectionsCount = 1
        snapshot.availableConnections.append(connection)

        self.http1ConnectionProvider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(1, snapshot.availableConnections.count)
        XCTAssertEqual(0, snapshot.leasedConnections.count)
        XCTAssertEqual(0, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(1, snapshot.openedConnectionsCount)

        let action = self.http1ConnectionProvider.state.remoteClosed(connection: connection)
        switch action {
        case .closeProvider:
            snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()
            XCTAssertEqual(0, snapshot.availableConnections.count)
            XCTAssertEqual(0, snapshot.leasedConnections.count)
            XCTAssertEqual(0, snapshot.waiters.count)
            XCTAssertEqual(0, snapshot.pending)
            XCTAssertEqual(0, snapshot.openedConnectionsCount)
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    // MARK: - Connection Tests

    func testConnectionReleaseActive() throws {
        let channel = ActiveChannel(eventLoop: self.eventLoop)
        var snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()

        let connection = Connection(channel: channel, provider: self.http1ConnectionProvider)
        snapshot.openedConnectionsCount = 1
        snapshot.leasedConnections.insert(ConnectionKey(connection))

        self.http1ConnectionProvider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(0, snapshot.availableConnections.count)
        XCTAssertEqual(1, snapshot.leasedConnections.count)
        XCTAssertEqual(0, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(1, snapshot.openedConnectionsCount)

        connection.release(closing: false, logger: HTTPClient.loggingDisabled)

        // XCTAssertFalse(connection.isInUse)
        snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()
        XCTAssertEqual(1, snapshot.availableConnections.count)
        XCTAssertEqual(0, snapshot.leasedConnections.count)
        XCTAssertEqual(0, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(1, snapshot.openedConnectionsCount)

        // cleanup
        // this cleanup code needs to go and use HTTP1ConnectionProvider's API instead
        // (https://github.com/swift-server/async-http-client/issues/234)
        snapshot.pending = 0
        self.http1ConnectionProvider.state.testsOnly_setInternalState(snapshot)
    }

    func testConnectionReleaseInactive() throws {
        let channel = EmbeddedChannel()

        var snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()

        let connection = Connection(channel: channel, provider: self.http1ConnectionProvider)
        snapshot.openedConnectionsCount = 1
        snapshot.leasedConnections.insert(ConnectionKey(connection))

        self.http1ConnectionProvider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(0, snapshot.availableConnections.count)
        XCTAssertEqual(1, snapshot.leasedConnections.count)
        XCTAssertEqual(0, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(1, snapshot.openedConnectionsCount)

        connection.release(closing: true, logger: HTTPClient.loggingDisabled)

        snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()
        XCTAssertEqual(0, snapshot.availableConnections.count)
        XCTAssertEqual(0, snapshot.leasedConnections.count)
        XCTAssertEqual(0, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(0, snapshot.openedConnectionsCount)

        // cleanup
        // this cleanup code needs to go and use HTTP1ConnectionProvider's API instead
        // (https://github.com/swift-server/async-http-client/issues/234)
        snapshot.pending = 0
        self.http1ConnectionProvider.state.testsOnly_setInternalState(snapshot)
    }

    func testConnectionRemoteCloseRelease() throws {
        let channel = EmbeddedChannel()

        var snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()

        let connection = Connection(channel: channel, provider: self.http1ConnectionProvider)
        snapshot.availableConnections.append(connection)
        snapshot.openedConnectionsCount = 1

        self.http1ConnectionProvider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(1, snapshot.availableConnections.count)
        XCTAssertEqual(0, snapshot.leasedConnections.count)
        XCTAssertEqual(0, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(1, snapshot.openedConnectionsCount)

        connection.remoteClosed(logger: HTTPClient.loggingDisabled)

        snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()
        XCTAssertEqual(0, snapshot.availableConnections.count)
        XCTAssertEqual(0, snapshot.leasedConnections.count)
        XCTAssertEqual(0, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(0, snapshot.openedConnectionsCount)

        // cleanup
        // this cleanup code needs to go and use HTTP1ConnectionProvider's API instead
        // (https://github.com/swift-server/async-http-client/issues/234)
        snapshot.pending = 0
        self.http1ConnectionProvider.state.testsOnly_setInternalState(snapshot)
    }

    func testConnectionTimeoutRelease() throws {
        let channel = EmbeddedChannel()

        var snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()

        let connection = Connection(channel: channel, provider: self.http1ConnectionProvider)
        snapshot.availableConnections.append(connection)
        snapshot.openedConnectionsCount = 1

        self.http1ConnectionProvider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(1, snapshot.availableConnections.count)
        XCTAssertEqual(0, snapshot.leasedConnections.count)
        XCTAssertEqual(0, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(1, snapshot.openedConnectionsCount)

        connection.timeout(logger: HTTPClient.loggingDisabled)

        snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()
        XCTAssertEqual(0, snapshot.availableConnections.count)
        XCTAssertEqual(0, snapshot.leasedConnections.count)
        XCTAssertEqual(0, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(0, snapshot.openedConnectionsCount)

        // cleanup
        // this cleanup code needs to go and use HTTP1ConnectionProvider's API instead
        // (https://github.com/swift-server/async-http-client/issues/234)
        snapshot.pending = 0
        self.http1ConnectionProvider.state.testsOnly_setInternalState(snapshot)
    }

    func testAcquireAvailableBecomesUnavailable() throws {
        let channel = ActiveChannel(eventLoop: self.eventLoop)
        var snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()

        let connection = Connection(channel: channel, provider: self.http1ConnectionProvider)
        snapshot.availableConnections.append(connection)
        snapshot.openedConnectionsCount = 1

        self.http1ConnectionProvider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(1, snapshot.availableConnections.count)
        XCTAssertEqual(0, snapshot.leasedConnections.count)
        XCTAssertEqual(0, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(1, snapshot.openedConnectionsCount)

        XCTAssertTrue(self.http1ConnectionProvider.enqueue())

        let action = self.http1ConnectionProvider.state.acquire(waiter: .init(promise: self.eventLoop.makePromise(), setupComplete: self.eventLoop.makeSucceededFuture(()), preference: .indifferent))
        switch action {
        case .lease(let connection, let waiter):
            // Since this connection is already in use, this should be a no-op and state should not have changed from normal lease
            connection.timeout(logger: HTTPClient.loggingDisabled)

            snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()
            XCTAssertTrue(connection.isActiveEstimation)
            XCTAssertTrue(snapshot.leasedConnections.contains(ConnectionKey(connection)))
            XCTAssertEqual(0, snapshot.availableConnections.count)
            XCTAssertEqual(1, snapshot.leasedConnections.count)
            XCTAssertEqual(0, snapshot.waiters.count)
            XCTAssertEqual(0, snapshot.pending)
            XCTAssertEqual(1, snapshot.openedConnectionsCount)

            // This is unrecoverable, but in this case we create a new connection, so state again should not change, even though release will be called
            // This is important to preventself.http1ConnectionProvider deletion since connection is released and there could be 0 waiters
            connection.remoteClosed(logger: HTTPClient.loggingDisabled)

            snapshot = self.http1ConnectionProvider.state.testsOnly_getInternalState()
            XCTAssertTrue(snapshot.leasedConnections.contains(ConnectionKey(connection)))
            XCTAssertEqual(0, snapshot.availableConnections.count)
            XCTAssertEqual(1, snapshot.leasedConnections.count)
            XCTAssertEqual(0, snapshot.waiters.count)
            XCTAssertEqual(0, snapshot.pending)
            XCTAssertEqual(1, snapshot.openedConnectionsCount)

            waiter.promise.succeed(connection)

            // cleanup
            // this cleanup code needs to go and use HTTP1ConnectionProvider's API instead
            // (https://github.com/swift-server/async-http-client/issues/234)
            snapshot.openedConnectionsCount = 0
            self.http1ConnectionProvider.state.testsOnly_setInternalState(snapshot)
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    override func setUp() {
        XCTAssertNil(self.eventLoop)
        XCTAssertNil(self.http1ConnectionProvider)
        self.eventLoop = EmbeddedEventLoop()
        XCTAssertNoThrow(self.http1ConnectionProvider = try HTTP1ConnectionProvider(key: .init(.init(url: "http://some.test")),
                                                                                    eventLoop: self.eventLoop,
                                                                                    configuration: .init(),
                                                                                    pool: .init(configuration: .init(),
                                                                                                backgroundActivityLogger: HTTPClient.loggingDisabled),
                                                                                    backgroundActivityLogger: HTTPClient.loggingDisabled))
    }

    override func tearDown() {
        XCTAssertNotNil(self.eventLoop)
        XCTAssertNotNil(self.http1ConnectionProvider)
        /* BEGIN workaround for #232, this whole block is to be replaced by the commented out line below */
        // not closing the provider here (https://github.com/swift-server/async-http-client/issues/232)
        var state = self.http1ConnectionProvider.state.testsOnly_getInternalState()
        if state.pending == 1, state.waiters.isEmpty, state.leasedConnections.isEmpty, state.openedConnectionsCount == 0 {
            state.pending = 0
            self.http1ConnectionProvider.state.testsOnly_setInternalState(state)
        }
        self.http1ConnectionProvider.closePromise.succeed(())
        /* END workaround for #232 */
        XCTAssertNoThrow(try self.http1ConnectionProvider.close().wait())
        XCTAssertNoThrow(try self.eventLoop.syncShutdownGracefully())
        self.eventLoop = nil
        self.http1ConnectionProvider = nil
    }
}

class ActiveChannel: Channel, ChannelCore {
    struct NotImplementedError: Error {}

    func localAddress0() throws -> SocketAddress {
        throw NotImplementedError()
    }

    func remoteAddress0() throws -> SocketAddress {
        throw NotImplementedError()
    }

    func register0(promise: EventLoopPromise<Void>?) {
        promise?.fail(NotImplementedError())
    }

    func bind0(to: SocketAddress, promise: EventLoopPromise<Void>?) {
        promise?.fail(NotImplementedError())
    }

    func connect0(to: SocketAddress, promise: EventLoopPromise<Void>?) {
        promise?.fail(NotImplementedError())
    }

    func write0(_ data: NIOAny, promise: EventLoopPromise<Void>?) {
        promise?.fail(NotImplementedError())
    }

    func flush0() {}

    func read0() {}

    func close0(error: Error, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        promise?.succeed(())
    }

    func triggerUserOutboundEvent0(_ event: Any, promise: EventLoopPromise<Void>?) {
        promise?.fail(NotImplementedError())
    }

    func channelRead0(_: NIOAny) {}

    func errorCaught0(error: Error) {}

    var allocator: ByteBufferAllocator
    var closeFuture: EventLoopFuture<Void>
    var eventLoop: EventLoop

    var localAddress: SocketAddress?
    var remoteAddress: SocketAddress?
    var parent: Channel?
    var isWritable: Bool = true
    var isActive: Bool = true

    init(eventLoop: EmbeddedEventLoop) {
        self.allocator = ByteBufferAllocator()
        self.eventLoop = eventLoop
        self.closeFuture = self.eventLoop.makeSucceededFuture(())
    }

    var _channelCore: ChannelCore {
        return self
    }

    var pipeline: ChannelPipeline {
        return ChannelPipeline(channel: self)
    }

    func setOption<Option>(_ option: Option, value: Option.Value) -> EventLoopFuture<Void> where Option: ChannelOption {
        preconditionFailure("Not implemented")
    }

    func getOption<Option>(_: Option) -> EventLoopFuture<Option.Value> where Option: ChannelOption {
        preconditionFailure("Not implemented")
    }
}
