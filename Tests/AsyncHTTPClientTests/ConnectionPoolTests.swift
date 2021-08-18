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
import NIOCore
import NIOEmbedded
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

    func testPending() {
        var state = HTTP1ConnectionProvider.ConnectionsState<ConnectionForTests>(eventLoop: self.eventLoop)
        XCTAssertState(state, available: 0, leased: 0, waiters: 0, pending: 0, opened: 0)
        XCTAssertTrue(state.enqueue())
        XCTAssertState(state, available: 0, leased: 0, waiters: 0, pending: 1, opened: 0)
    }

    // MARK: - Acquire Tests

    func testAcquireWhenEmpty() {
        var state = HTTP1ConnectionProvider.ConnectionsState<ConnectionForTests>(eventLoop: self.eventLoop)
        XCTAssertState(state, available: 0, leased: 0, waiters: 0, pending: 0, opened: 0)

        XCTAssertTrue(state.enqueue())
        let action = state.acquire(waiter: .init(promise: self.eventLoop.makePromise(), setupComplete: self.eventLoop.makeSucceededFuture(()), preference: .indifferent))
        switch action {
        case .create(let waiter):
            waiter.promise.fail(TempError())
        default:
            XCTFail("Unexpected action: \(action)")
        }

        XCTAssertState(state, available: 0, leased: 0, waiters: 0, pending: 0, opened: 1)
    }

    func testAcquireWhenAvailable() throws {
        var (state, _) = self.buildState(count: 1)

        // Validate that the pool has one available connection and it's internal state is correct
        XCTAssertState(state, available: 1, leased: 0, waiters: 0, pending: 0, opened: 1)

        XCTAssertTrue(state.enqueue())

        let action = state.acquire(waiter: .init(promise: self.eventLoop.makePromise(), setupComplete: self.eventLoop.makeSucceededFuture(()), preference: .indifferent))
        switch action {
        case .lease(let connection, let waiter):
            XCTAssertState(state, available: 0, leased: 1, waiters: 0, pending: 0, opened: 1)

            // cleanup
            waiter.promise.succeed(connection)
        default:
            XCTFail("Unexpected action: \(action)")
        }

        // cleanup
        try XCTAssertStateClose(state, available: 0, leased: 1, waiters: 0, clean: false)
    }

    func testAcquireWhenUnavailable() throws {
        var (state, _) = self.buildState(count: 8, release: false)
        XCTAssertState(state, available: 0, leased: 8, waiters: 0, pending: 0, opened: 8)

        XCTAssertTrue(state.enqueue())
        let action = state.acquire(waiter: .init(promise: self.eventLoop.makePromise(), setupComplete: self.eventLoop.makeSucceededFuture(()), preference: .indifferent))
        switch action {
        case .none:
            XCTAssertState(state, available: 0, leased: 8, waiters: 1, pending: 0, opened: 8)
        default:
            XCTFail("Unexpected action: \(action)")
        }

        // cleanup
        try XCTAssertStateClose(state, available: 0, leased: 8, waiters: 1, clean: false)
    }

    // MARK: - Acquire on Specific EL Tests

    func testAcquireWhenEmptySpecificEL() {
        let el: EventLoop = self.eventLoop
        let preference: HTTPClient.EventLoopPreference = .delegateAndChannel(on: el)

        var state = HTTP1ConnectionProvider.ConnectionsState<ConnectionForTests>(eventLoop: el)
        XCTAssertState(state, available: 0, leased: 0, waiters: 0, pending: 0, opened: 0)

        XCTAssertTrue(state.enqueue())
        let action = state.acquire(waiter: .init(promise: el.makePromise(), setupComplete: el.makeSucceededFuture(()), preference: preference))
        switch action {
        case .create(let waiter):
            waiter.promise.fail(TempError())
        default:
            XCTFail("Unexpected action: \(action)")
        }

        XCTAssertState(state, available: 0, leased: 0, waiters: 0, pending: 0, opened: 1)
    }

    func testAcquireWhenAvailableSpecificEL() throws {
        let el: EventLoop = self.eventLoop
        let preference: HTTPClient.EventLoopPreference = .delegateAndChannel(on: el)
        var (state, _) = self.buildState(count: 1, eventLoop: el)
        XCTAssertState(state, available: 1, leased: 0, waiters: 0, pending: 0, opened: 1)

        XCTAssertTrue(state.enqueue())
        let action = state.acquire(waiter: .init(promise: el.makePromise(), setupComplete: el.makeSucceededFuture(()), preference: preference))
        switch action {
        case .lease(let connection, let waiter):
            waiter.promise.succeed(connection)
            XCTAssertState(state, available: 0, leased: 1, waiters: 0, pending: 0, opened: 1)
        default:
            XCTFail("Unexpected action: \(action)")
        }

        // cleanup
        try XCTAssertStateClose(state, available: 0, leased: 1, waiters: 0, clean: false)
    }

    func testAcquireReplace() throws {
        let el: EventLoop = self.eventLoop
        var (state, connections) = self.buildState(count: 8, release: false, eventLoop: el)

        // release a connection
        _ = state.release(connection: connections.first!, closing: false)
        XCTAssertState(state, available: 1, leased: 7, waiters: 0, pending: 0, opened: 8)

        // other eventLoop
        let preference: HTTPClient.EventLoopPreference = .delegateAndChannel(on: EmbeddedEventLoop())

        XCTAssertTrue(state.enqueue())
        let action = state.acquire(waiter: .init(promise: el.makePromise(), setupComplete: el.makeSucceededFuture(()), preference: preference))
        switch action {
        case .replace(let connection, let waiter):
            waiter.promise.fail(TempError())
            XCTAssertState(state, available: 0, leased: 7, waiters: 0, pending: 0, opened: 8, isNotLeased: connection)
        default:
            XCTFail("Unexpected action: \(action)")
        }

        // cleanup
        try XCTAssertStateClose(state, available: 0, leased: 7, waiters: 0, clean: false)
    }

    func testAcquireWhenUnavailableSpecificEL() throws {
        var (state, _) = self.buildState(count: 8, release: false, eventLoop: self.eventLoop)
        XCTAssertState(state, available: 0, leased: 8, waiters: 0, pending: 0, opened: 8)

        XCTAssertTrue(state.enqueue())
        let action = state.acquire(waiter: .init(promise: self.eventLoop.makePromise(), setupComplete: self.eventLoop.makeSucceededFuture(()), preference: .delegateAndChannel(on: self.eventLoop)))
        switch action {
        case .none:
            XCTAssertState(state, available: 0, leased: 8, waiters: 1, pending: 0, opened: 8)
        default:
            XCTFail("Unexpected action: \(action)")
        }

        // cleanup
        try XCTAssertStateClose(state, available: 0, leased: 8, waiters: 1, clean: false)
    }

    // MARK: - Acquire Errors Tests

    func testAcquireWhenClosed() {
        var state = HTTP1ConnectionProvider.ConnectionsState<Connection>(eventLoop: self.eventLoop)
        _ = state.close()
        XCTAssertState(state, available: 0, leased: 0, waiters: 0, pending: 0, opened: 0)

        XCTAssertFalse(state.enqueue())

        let promise = self.eventLoop.makePromise(of: Connection.self)
        let action = state.acquire(waiter: .init(promise: promise, setupComplete: self.eventLoop.makeSucceededFuture(()), preference: .indifferent))
        switch action {
        case .fail(let waiter, let error):
            waiter.promise.fail(error)
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    func testConnectFailedWhenClosed() {
        var state = HTTP1ConnectionProvider.ConnectionsState<Connection>(eventLoop: self.eventLoop)
        _ = state.close()
        XCTAssertState(state, available: 0, leased: 0, waiters: 0, pending: 0, opened: 0)

        let action = state.connectFailed()
        switch action {
        case .none:
            break
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    // MARK: - Release Tests

    func testReleaseAliveConnectionEmptyQueue() throws {
        var (state, connections) = self.buildState(count: 1, release: false)
        XCTAssertState(state, available: 0, leased: 1, waiters: 0, pending: 0, opened: 1)

        let connection = try XCTUnwrap(connections.first)
        let action = state.release(connection: connection, closing: false)
        switch action {
        case .park:
            XCTAssertState(state, available: 1, leased: 0, waiters: 0, pending: 0, opened: 1)
        default:
            XCTFail("Unexpected action: \(action)")
        }

        // cleanup
        try XCTAssertStateClose(state, available: 1, leased: 0, waiters: 0, clean: true)
    }

    func testReleaseAliveButClosingConnectionEmptyQueue() throws {
        var (state, connections) = self.buildState(count: 1, release: false)
        XCTAssertState(state, available: 0, leased: 1, waiters: 0, pending: 0, opened: 1)

        let connection = try XCTUnwrap(connections.first)
        // closing should be true to test that we can discard connection that is still active, but caller indicated that it will be closed soon
        let action = state.release(connection: connection, closing: true)
        switch action {
        case .closeProvider:
            XCTAssertState(state, available: 0, leased: 0, waiters: 0, pending: 0, opened: 0)
        default:
            XCTFail("Unexpected action: \(action)")
        }

        // cleanup
        XCTAssertNil(state.close())
    }

    func testReleaseInactiveConnectionEmptyQueue() throws {
        var (state, connections) = self.buildState(count: 1, release: false)
        XCTAssertState(state, available: 0, leased: 1, waiters: 0, pending: 0, opened: 1)

        let connection = try XCTUnwrap(connections.first)
        connection.isActiveEstimation = false
        // closing should be false to test that we check connection state in order to decided if we need to discard the connection
        let action = state.release(connection: connection, closing: false)
        switch action {
        case .closeProvider:
            XCTAssertState(state, available: 0, leased: 0, waiters: 0, pending: 0, opened: 0)
        default:
            XCTFail("Unexpected action: \(action)")
        }

        // cleanup
        XCTAssertNil(state.close())
    }

    func testReleaseInactiveConnectionEmptyQueueHasConnections() throws {
        var (state, connections) = self.buildState(count: 2, release: false)
        XCTAssertState(state, available: 0, leased: 2, waiters: 0, pending: 0, opened: 2)

        let connection = try XCTUnwrap(connections.first)

        // Return a connection to the pool
        _ = state.release(connection: try XCTUnwrap(connections.dropFirst().first), closing: false)
        XCTAssertState(state, available: 1, leased: 1, waiters: 0, pending: 0, opened: 2)

        let action = state.release(connection: connection, closing: true)
        switch action {
        case .none:
            XCTAssertState(state, available: 1, leased: 0, waiters: 0, pending: 0, opened: 1)
        default:
            XCTFail("Unexpected action: \(action)")
        }

        // cleanup
        try XCTAssertStateClose(state, available: 1, leased: 0, waiters: 0, clean: true)
    }

    func testReleaseAliveConnectionHasWaiter() throws {
        var (state, connections) = self.buildState(count: 8, release: false)

        // Add one waiter to the pool
        XCTAssertTrue(state.enqueue())
        _ = state.acquire(waiter: .init(promise: self.eventLoop.makePromise(), setupComplete: self.eventLoop.makeSucceededFuture(()), preference: .indifferent))

        XCTAssertState(state, available: 0, leased: 8, waiters: 1, pending: 0, opened: 8)

        let connection = try XCTUnwrap(connections.first)
        let action = state.release(connection: connection, closing: false)
        switch action {
        case .lease(let connection, let waiter):
            XCTAssertState(state, available: 0, leased: 8, waiters: 0, pending: 0, opened: 8, isLeased: connection)
            // cleanup
            waiter.promise.succeed(connection)
        default:
            XCTFail("Unexpected action: \(action)")
        }

        // cleanup
        try XCTAssertStateClose(state, available: 0, leased: 8, waiters: 0, clean: false)
    }

    func testReleaseInactiveConnectionHasWaitersNoConnections() throws {
        var (state, connections) = self.buildState(count: 8, release: false)
        XCTAssertState(state, available: 0, leased: 8, waiters: 0, pending: 0, opened: 8)

        // Add one waiter to the pool
        XCTAssertTrue(state.enqueue())
        _ = state.acquire(waiter: .init(promise: self.eventLoop.makePromise(), setupComplete: self.eventLoop.makeSucceededFuture(()), preference: .indifferent))
        XCTAssertState(state, available: 0, leased: 8, waiters: 1, pending: 0, opened: 8)

        let connection = try XCTUnwrap(connections.first)
        let action = state.release(connection: connection, closing: true)
        switch action {
        case .create(let waiter):
            XCTAssertState(state, available: 0, leased: 7, waiters: 0, pending: 0, opened: 8)
            // cleanup
            waiter.promise.fail(TempError())
        default:
            XCTFail("Unexpected action: \(action)")
        }

        // cleanup
        try XCTAssertStateClose(state, available: 0, leased: 7, waiters: 0, clean: false)
    }

    // MARK: - Release on Specific EL Tests

    func testReleaseAliveConnectionSameELHasWaiterSpecificEL() throws {
        var (state, connections) = self.buildState(count: 8, release: false)
        XCTAssertState(state, available: 0, leased: 8, waiters: 0, pending: 0, opened: 8)

        // Add one waiter to the pool
        XCTAssertTrue(state.enqueue())
        _ = state.acquire(waiter: .init(promise: self.eventLoop.makePromise(), setupComplete: self.eventLoop.makeSucceededFuture(()), preference: .delegateAndChannel(on: self.eventLoop)))
        XCTAssertState(state, available: 0, leased: 8, waiters: 1, pending: 0, opened: 8)

        let connection = try XCTUnwrap(connections.first)
        let action = state.release(connection: connection, closing: false)
        switch action {
        case .lease(let connection, let waiter):
            XCTAssertState(state, available: 0, leased: 8, waiters: 0, pending: 0, opened: 8, isLeased: connection)
            // cleanup
            waiter.promise.succeed(connection)
        default:
            XCTFail("Unexpected action: \(action)")
        }

        try XCTAssertStateClose(state, available: 0, leased: 8, waiters: 0, clean: false)
    }

    func testReleaseAliveConnectionDifferentELNoSameELConnectionsOnLimitHasWaiterSpecificEL() throws {
        var (state, connections) = self.buildState(count: 8, release: false)
        XCTAssertState(state, available: 0, leased: 8, waiters: 0, pending: 0, opened: 8)

        let differentEL = EmbeddedEventLoop()
        // Add one waiter to the pool
        XCTAssertTrue(state.enqueue())
        _ = state.acquire(waiter: .init(promise: differentEL.makePromise(), setupComplete: differentEL.makeSucceededFuture(()), preference: .delegateAndChannel(on: differentEL)))
        XCTAssertState(state, available: 0, leased: 8, waiters: 1, pending: 0, opened: 8)

        let connection = try XCTUnwrap(connections.first)
        let action = state.release(connection: connection, closing: false)
        switch action {
        case .replace(let connection, let waiter):
            XCTAssertState(state, available: 0, leased: 7, waiters: 0, pending: 0, opened: 8, isNotLeased: connection)
            // cleanup
            waiter.promise.fail(TempError())
        default:
            XCTFail("Unexpected action: \(action)")
        }

        try XCTAssertStateClose(state, available: 0, leased: 7, waiters: 0, clean: false)
    }

    // MARK: - Next Waiter Tests

    func testNextWaiterEmptyQueue() throws {
        var (state, _) = self.buildState(count: 0)
        XCTAssertState(state, available: 0, leased: 0, waiters: 0, pending: 0, opened: 0)

        let action = state.processNextWaiter()
        switch action {
        case .closeProvider:
            XCTAssertState(state, available: 0, leased: 0, waiters: 0, pending: 0, opened: 0)
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    func testNextWaiterEmptyQueueHasConnections() throws {
        var (state, _) = self.buildState(count: 1, release: true)
        XCTAssertState(state, available: 1, leased: 0, waiters: 0, pending: 0, opened: 1)

        let action = state.processNextWaiter()
        switch action {
        case .none:
            XCTAssertState(state, available: 1, leased: 0, waiters: 0, pending: 0, opened: 1)
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    // MARK: - Timeout and Remote Close Tests

    func testTimeoutLeasedConnection() throws {
        var (state, connections) = self.buildState(count: 1, release: false)
        XCTAssertState(state, available: 0, leased: 1, waiters: 0, pending: 0, opened: 1)

        let connection = try XCTUnwrap(connections.first)
        let action = state.timeout(connection: connection)
        switch action {
        case .none:
            XCTAssertState(state, available: 0, leased: 1, waiters: 0, pending: 0, opened: 1)
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    func testTimeoutAvailableConnection() throws {
        var (state, connections) = self.buildState(count: 1)
        XCTAssertState(state, available: 1, leased: 0, waiters: 0, pending: 0, opened: 1)

        let connection = try XCTUnwrap(connections.first)
        let action = state.timeout(connection: connection)
        switch action {
        case .closeAnd(_, let after):
            switch after {
            case .closeProvider:
                break
            default:
                XCTFail("Unexpected action: \(action)")
            }
            XCTAssertState(state, available: 0, leased: 0, waiters: 0, pending: 0, opened: 0)
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    func testRemoteClosedLeasedConnection() throws {
        var (state, connections) = self.buildState(count: 1, release: false)

        XCTAssertState(state, available: 0, leased: 1, waiters: 0, pending: 0, opened: 1)

        // This can happen when just leased connection is closed before TaskHandler is added to pipeline
        let connection = try XCTUnwrap(connections.first)
        let action = state.remoteClosed(connection: connection)
        switch action {
        case .none:
            XCTAssertState(state, available: 0, leased: 1, waiters: 0, pending: 0, opened: 1)
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    func testRemoteClosedAvailableConnection() throws {
        var (state, connections) = self.buildState(count: 1)

        XCTAssertState(state, available: 1, leased: 0, waiters: 0, pending: 0, opened: 1)

        let connection = try XCTUnwrap(connections.first)
        let action = state.remoteClosed(connection: connection)
        switch action {
        case .closeProvider:
            XCTAssertState(state, available: 0, leased: 0, waiters: 0, pending: 0, opened: 0)
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    // MARK: - Shutdown tests

    func testShutdownOnPendingAndSuccess() {
        var state = HTTP1ConnectionProvider.ConnectionsState<ConnectionForTests>(eventLoop: self.eventLoop)

        XCTAssertTrue(state.enqueue())

        let connectionPromise = self.eventLoop.makePromise(of: ConnectionForTests.self)
        let setupPromise = self.eventLoop.makePromise(of: Void.self)
        let waiter = HTTP1ConnectionProvider.Waiter(promise: connectionPromise, setupComplete: setupPromise.futureResult, preference: .indifferent)
        var action = state.acquire(waiter: waiter)

        guard case .create = action else {
            XCTFail("unexpected action \(action)")
            return
        }

        let snapshot = state.testsOnly_getInternalState()
        XCTAssertEqual(snapshot.openedConnectionsCount, 1)

        if let (waiters, available, leased, clean) = state.close() {
            XCTAssertTrue(waiters.isEmpty)
            XCTAssertTrue(available.isEmpty)
            XCTAssertTrue(leased.isEmpty)
            XCTAssertFalse(clean)
        } else {
            XCTFail("Expecting snapshot")
        }

        let connection = ConnectionForTests(eventLoop: self.eventLoop)

        action = state.offer(connection: connection)
        guard case .closeAnd(_, .closeProvider) = action else {
            XCTFail("unexpected action \(action)")
            return
        }

        connectionPromise.fail(TempError())
        setupPromise.succeed(())
    }

    func testShutdownOnPendingAndError() {
        var state = HTTP1ConnectionProvider.ConnectionsState<ConnectionForTests>(eventLoop: self.eventLoop)

        XCTAssertTrue(state.enqueue())

        let connectionPromise = self.eventLoop.makePromise(of: ConnectionForTests.self)
        let setupPromise = self.eventLoop.makePromise(of: Void.self)
        let waiter = HTTP1ConnectionProvider.Waiter(promise: connectionPromise, setupComplete: setupPromise.futureResult, preference: .indifferent)
        var action = state.acquire(waiter: waiter)

        guard case .create = action else {
            XCTFail("unexpected action \(action)")
            return
        }

        let snapshot = state.testsOnly_getInternalState()
        XCTAssertEqual(snapshot.openedConnectionsCount, 1)

        if let (waiters, available, leased, clean) = state.close() {
            XCTAssertTrue(waiters.isEmpty)
            XCTAssertTrue(available.isEmpty)
            XCTAssertTrue(leased.isEmpty)
            XCTAssertFalse(clean)
        } else {
            XCTFail("Expecting snapshot")
        }

        action = state.connectFailed()
        guard case .closeProvider = action else {
            XCTFail("unexpected action \(action)")
            return
        }

        connectionPromise.fail(TempError())
        setupPromise.succeed(())
    }

    func testShutdownTimeout() throws {
        var (state, connections) = self.buildState(count: 1)

        if let (waiters, available, leased, clean) = state.close() {
            XCTAssertTrue(waiters.isEmpty)
            XCTAssertFalse(available.isEmpty)
            XCTAssertTrue(leased.isEmpty)
            XCTAssertTrue(clean)
        } else {
            XCTFail("Expecting snapshot")
        }

        let connection = try XCTUnwrap(connections.first)
        let action = state.timeout(connection: connection)
        switch action {
        case .closeAnd(_, let next):
            switch next {
            case .closeProvider:
                // expected
                break
            default:
                XCTFail("Unexpected action: \(action)")
            }
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    func testShutdownRemoteClosed() throws {
        var (state, connections) = self.buildState(count: 1)

        if let (waiters, available, leased, clean) = state.close() {
            XCTAssertTrue(waiters.isEmpty)
            XCTAssertFalse(available.isEmpty)
            XCTAssertTrue(leased.isEmpty)
            XCTAssertTrue(clean)
        } else {
            XCTFail("Expecting snapshot")
        }

        let connection = try XCTUnwrap(connections.first)
        let action = state.remoteClosed(connection: connection)
        switch action {
        case .closeProvider:
            // expected
            break
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    override func setUp() {
        XCTAssertNil(self.eventLoop)
        self.eventLoop = EmbeddedEventLoop()
    }

    override func tearDown() {
        XCTAssertNotNil(self.eventLoop)
        XCTAssertNoThrow(try self.eventLoop.syncShutdownGracefully())
        self.eventLoop = nil
    }
}
