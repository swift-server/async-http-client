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
    struct TempError: Error {}

    func testPending() {
        let eventLoop = EmbeddedEventLoop()

        var state = HTTP1ConnectionProvider.ConnectionsState(eventLoop: eventLoop)

        var snapshot = state.testsOnly_getInternalState()
        XCTAssertEqual(0, snapshot.availableConnections.count)
        XCTAssertEqual(0, snapshot.leasedConnections.count)
        XCTAssertEqual(0, snapshot.waiters.count)
        XCTAssertEqual(1, snapshot.pending)
        XCTAssertEqual(0, snapshot.openedConnectionsCount)

        XCTAssertTrue(state.enqueue())

        snapshot = state.testsOnly_getInternalState()
        XCTAssertEqual(0, snapshot.availableConnections.count)
        XCTAssertEqual(0, snapshot.leasedConnections.count)
        XCTAssertEqual(0, snapshot.waiters.count)
        XCTAssertEqual(2, snapshot.pending)
        XCTAssertEqual(0, snapshot.openedConnectionsCount)
    }

    // MARK: - Acquire Tests

    func testAcquireWhenEmpty() {
        let eventLoop = EmbeddedEventLoop()

        var state = HTTP1ConnectionProvider.ConnectionsState(eventLoop: eventLoop)

        var snapshot = state.testsOnly_getInternalState()
        XCTAssertEqual(0, snapshot.availableConnections.count)
        XCTAssertEqual(0, snapshot.leasedConnections.count)
        XCTAssertEqual(0, snapshot.waiters.count)
        XCTAssertEqual(1, snapshot.pending)
        XCTAssertEqual(0, snapshot.openedConnectionsCount)

        let action = state.acquire(waiter: .init(promise: eventLoop.makePromise(), setupComplete: eventLoop.makeSucceededFuture(()), preference: .indifferent))
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
        let eventLoop = EmbeddedEventLoop()
        let channel = EmbeddedChannel()

        let provider = try HTTP1ConnectionProvider(key: .init(.init(url: "http://some.test")), eventLoop: eventLoop, configuration: .init(), pool: .init(configuration: .init()))
        var snapshot = provider.state.testsOnly_getInternalState()

        let connection = Connection(channel: channel, provider: provider)
        snapshot.availableConnections.append(connection)
        snapshot.openedConnectionsCount = 1

        provider.state.testsOnly_setInternalState(snapshot)

        snapshot = provider.state.testsOnly_getInternalState()
        XCTAssertEqual(1, snapshot.availableConnections.count)
        XCTAssertEqual(0, snapshot.leasedConnections.count)
        XCTAssertEqual(0, snapshot.waiters.count)
        XCTAssertEqual(1, snapshot.pending)
        XCTAssertEqual(1, snapshot.openedConnectionsCount)

        let action = provider.state.acquire(waiter: .init(promise: eventLoop.makePromise(), setupComplete: eventLoop.makeSucceededFuture(()), preference: .indifferent))
        switch action {
        case .lease(let connection, let waiter):
            waiter.promise.succeed(connection)

            snapshot = provider.state.testsOnly_getInternalState()
            XCTAssertEqual(0, snapshot.availableConnections.count)
            XCTAssertEqual(1, snapshot.leasedConnections.count)
            XCTAssertEqual(0, snapshot.waiters.count)
            XCTAssertEqual(0, snapshot.pending)
            XCTAssertEqual(1, snapshot.openedConnectionsCount)

            // cleanup, since we don't call release
            snapshot.openedConnectionsCount = 0
            provider.state.testsOnly_setInternalState(snapshot)
            provider.closePromise.succeed(())
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    func testAcquireWhenUnavailable() throws {
        let eventLoop = EmbeddedEventLoop()

        let provider = try HTTP1ConnectionProvider(key: .init(.init(url: "http://some.test")), eventLoop: eventLoop, configuration: .init(), pool: .init(configuration: .init()))
        var snapshot = provider.state.testsOnly_getInternalState()

        snapshot.openedConnectionsCount = 8
        provider.state.testsOnly_setInternalState(snapshot)

        snapshot = provider.state.testsOnly_getInternalState()
        XCTAssertEqual(0, snapshot.availableConnections.count)
        XCTAssertEqual(0, snapshot.leasedConnections.count)
        XCTAssertEqual(0, snapshot.waiters.count)
        XCTAssertEqual(1, snapshot.pending)
        XCTAssertEqual(8, snapshot.openedConnectionsCount)

        let action = provider.state.acquire(waiter: .init(promise: eventLoop.makePromise(), setupComplete: eventLoop.makeSucceededFuture(()), preference: .indifferent))
        switch action {
        case .none:
            snapshot = provider.state.testsOnly_getInternalState()
            XCTAssertEqual(0, snapshot.availableConnections.count)
            XCTAssertEqual(0, snapshot.leasedConnections.count)
            XCTAssertEqual(1, snapshot.waiters.count)
            XCTAssertEqual(0, snapshot.pending)
            XCTAssertEqual(8, snapshot.openedConnectionsCount)
        default:
            XCTFail("Unexpected action: \(action)")
        }

        // cleanup
        snapshot.openedConnectionsCount = 0
        provider.state.testsOnly_setInternalState(snapshot)
        provider.closePromise.succeed(())
        _ = try provider.close().wait()
    }

    // MARK: - Acquire on Specific EL Tests

    func testAcquireWhenEmptySpecificEL() {
        let eventLoop = EmbeddedEventLoop()

        var state = HTTP1ConnectionProvider.ConnectionsState(eventLoop: eventLoop)
        var snapshot = state.testsOnly_getInternalState()

        XCTAssertEqual(0, snapshot.availableConnections.count)
        XCTAssertEqual(0, snapshot.leasedConnections.count)
        XCTAssertEqual(0, snapshot.waiters.count)
        XCTAssertEqual(1, snapshot.pending)
        XCTAssertEqual(0, snapshot.openedConnectionsCount)

        let action = state.acquire(waiter: .init(promise: eventLoop.makePromise(), setupComplete: eventLoop.makeSucceededFuture(()), preference: .delegateAndChannel(on: eventLoop)))
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

        let provider = try HTTP1ConnectionProvider(key: .init(.init(url: "http://some.test")), eventLoop: channel.eventLoop, configuration: .init(), pool: .init(configuration: .init()))
        var snapshot = provider.state.testsOnly_getInternalState()

        let connection = Connection(channel: channel, provider: provider)
        snapshot.availableConnections.append(connection)
        snapshot.openedConnectionsCount = 1

        provider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(1, snapshot.availableConnections.count)
        XCTAssertEqual(0, snapshot.leasedConnections.count)
        XCTAssertEqual(0, snapshot.waiters.count)
        XCTAssertEqual(1, snapshot.pending)
        XCTAssertEqual(1, snapshot.openedConnectionsCount)

        let action = provider.state.acquire(waiter: .init(promise: channel.eventLoop.makePromise(), setupComplete: channel.eventLoop.makeSucceededFuture(()), preference: .delegateAndChannel(on: channel.eventLoop)))
        switch action {
        case .lease(let connection, let waiter):
            waiter.promise.succeed(connection)

            snapshot = provider.state.testsOnly_getInternalState()
            XCTAssertEqual(0, snapshot.availableConnections.count)
            XCTAssertEqual(1, snapshot.leasedConnections.count)
            XCTAssertEqual(0, snapshot.waiters.count)
            XCTAssertEqual(0, snapshot.pending)
            XCTAssertEqual(1, snapshot.openedConnectionsCount)

            // cleanup, since we don't call release
            snapshot.openedConnectionsCount = 0
            provider.state.testsOnly_setInternalState(snapshot)
            provider.closePromise.succeed(())
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    func testAcquireReplace() throws {
        let eventLoop = EmbeddedEventLoop()
        let channel = EmbeddedChannel()

        let provider = try HTTP1ConnectionProvider(key: .init(.init(url: "http://some.test")), eventLoop: channel.eventLoop, configuration: .init(), pool: .init(configuration: .init()))
        var snapshot = provider.state.testsOnly_getInternalState()

        let connection = Connection(channel: channel, provider: provider)
        snapshot.availableConnections.append(connection)
        snapshot.openedConnectionsCount = 8

        provider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(1, snapshot.availableConnections.count)
        XCTAssertEqual(0, snapshot.leasedConnections.count)
        XCTAssertEqual(0, snapshot.waiters.count)
        XCTAssertEqual(1, snapshot.pending)
        XCTAssertEqual(8, snapshot.openedConnectionsCount)

        let action = provider.state.acquire(waiter: .init(promise: eventLoop.makePromise(), setupComplete: eventLoop.makeSucceededFuture(()), preference: .delegateAndChannel(on: eventLoop)))
        switch action {
        case .replace(_, let waiter):
            waiter.promise.fail(TempError())

            snapshot = provider.state.testsOnly_getInternalState()
            XCTAssertEqual(0, snapshot.availableConnections.count)
            XCTAssertEqual(0, snapshot.leasedConnections.count)
            XCTAssertEqual(0, snapshot.waiters.count)
            XCTAssertEqual(0, snapshot.pending)
            XCTAssertEqual(8, snapshot.openedConnectionsCount)
        default:
            XCTFail("Unexpected action: \(action)")
        }

        // cleanup
        snapshot.openedConnectionsCount = 0
        provider.state.testsOnly_setInternalState(snapshot)
        provider.closePromise.succeed(())
        _ = try provider.close().wait()
    }

    func testAcquireWhenUnavailableSpecificEL() throws {
        let eventLoop = EmbeddedEventLoop()

        let provider = try HTTP1ConnectionProvider(key: .init(.init(url: "http://some.test")), eventLoop: eventLoop, configuration: .init(), pool: .init(configuration: .init()))
        var snapshot = provider.state.testsOnly_getInternalState()

        snapshot.openedConnectionsCount = 8

        provider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(0, snapshot.availableConnections.count)
        XCTAssertEqual(0, snapshot.leasedConnections.count)
        XCTAssertEqual(0, snapshot.waiters.count)
        XCTAssertEqual(1, snapshot.pending)
        XCTAssertEqual(8, snapshot.openedConnectionsCount)

        let action = provider.state.acquire(waiter: .init(promise: eventLoop.makePromise(), setupComplete: eventLoop.makeSucceededFuture(()), preference: .delegateAndChannel(on: eventLoop)))
        switch action {
        case .none:
            snapshot = provider.state.testsOnly_getInternalState()
            XCTAssertEqual(0, snapshot.availableConnections.count)
            XCTAssertEqual(0, snapshot.leasedConnections.count)
            XCTAssertEqual(1, snapshot.waiters.count)
            XCTAssertEqual(0, snapshot.pending)
            XCTAssertEqual(8, snapshot.openedConnectionsCount)
        default:
            XCTFail("Unexpected action: \(action)")
        }

        // cleanup
        snapshot.openedConnectionsCount = 0
        provider.state.testsOnly_setInternalState(snapshot)
        provider.closePromise.succeed(())
        _ = try provider.close().wait()
    }

    // MARK: - Acquire Errors Tests

    func testAcquireWhenClosed() {
        let eventLoop = EmbeddedEventLoop()

        var state = HTTP1ConnectionProvider.ConnectionsState(eventLoop: eventLoop)
        var snapshot = state.testsOnly_getInternalState()
        snapshot.state = .closed
        state.testsOnly_setInternalState(snapshot)

        XCTAssertFalse(state.enqueue())

        let promise = eventLoop.makePromise(of: Connection.self)
        let action = state.acquire(waiter: .init(promise: promise, setupComplete: eventLoop.makeSucceededFuture(()), preference: .indifferent))
        switch action {
        case .fail(let waiter, let error):
            waiter.promise.fail(error)
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    // MARK: - Release Tests

    func testReleaseAliveConnectionEmptyQueue() throws {
        let channel = ActiveChannel()

        let provider = try HTTP1ConnectionProvider(key: .init(.init(url: "http://some.test")), eventLoop: channel.eventLoop, configuration: .init(), pool: .init(configuration: .init()))
        var snapshot = provider.state.testsOnly_getInternalState()

        snapshot.pending = 0
        snapshot.openedConnectionsCount = 1
        let connection = Connection(channel: channel, provider: provider)
        snapshot.leasedConnections.insert(ConnectionKey(connection))

        provider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(0, snapshot.availableConnections.count)
        XCTAssertEqual(1, snapshot.leasedConnections.count)
        XCTAssertEqual(0, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(1, snapshot.openedConnectionsCount)

        let action = provider.state.release(connection: connection, closing: false)
        switch action {
        case .park:
            snapshot = provider.state.testsOnly_getInternalState()
            XCTAssertEqual(1, snapshot.availableConnections.count)
            XCTAssertEqual(0, snapshot.leasedConnections.count)
            XCTAssertEqual(0, snapshot.waiters.count)
            XCTAssertEqual(0, snapshot.pending)
            XCTAssertEqual(1, snapshot.openedConnectionsCount)

            // cleanp
            provider.closePromise.succeed(())
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    func testReleaseAliveButClosingConnectionEmptyQueue() throws {
        let channel = ActiveChannel()

        let provider = try HTTP1ConnectionProvider(key: .init(.init(url: "http://some.test")), eventLoop: channel.eventLoop, configuration: .init(), pool: .init(configuration: .init()))
        var snapshot = provider.state.testsOnly_getInternalState()

        snapshot.pending = 0
        snapshot.openedConnectionsCount = 1
        let connection = Connection(channel: channel, provider: provider)
        snapshot.leasedConnections.insert(ConnectionKey(connection))

        provider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(0, snapshot.availableConnections.count)
        XCTAssertEqual(1, snapshot.leasedConnections.count)
        XCTAssertEqual(0, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(1, snapshot.openedConnectionsCount)

        let action = provider.state.release(connection: connection, closing: true)
        switch action {
        case .closeProvider:
            snapshot = provider.state.testsOnly_getInternalState()
            XCTAssertEqual(0, snapshot.availableConnections.count)
            XCTAssertEqual(0, snapshot.leasedConnections.count)
            XCTAssertEqual(0, snapshot.waiters.count)
            XCTAssertEqual(0, snapshot.pending)
            XCTAssertEqual(0, snapshot.openedConnectionsCount)

            // cleanup
            provider.closePromise.succeed(())
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    func testReleaseInactiveConnectionEmptyQueue() throws {
        let channel = EmbeddedChannel()

        let provider = try HTTP1ConnectionProvider(key: .init(.init(url: "http://some.test")), eventLoop: channel.eventLoop, configuration: .init(), pool: .init(configuration: .init()))
        var snapshot = provider.state.testsOnly_getInternalState()

        snapshot.pending = 0
        snapshot.openedConnectionsCount = 1
        let connection = Connection(channel: channel, provider: provider)
        snapshot.leasedConnections.insert(ConnectionKey(connection))

        provider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(0, snapshot.availableConnections.count)
        XCTAssertEqual(1, snapshot.leasedConnections.count)
        XCTAssertEqual(0, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(1, snapshot.openedConnectionsCount)

        let action = provider.state.release(connection: connection, closing: true)
        switch action {
        case .closeProvider:
            snapshot = provider.state.testsOnly_getInternalState()
            XCTAssertEqual(0, snapshot.availableConnections.count)
            XCTAssertEqual(0, snapshot.leasedConnections.count)
            XCTAssertEqual(0, snapshot.waiters.count)
            XCTAssertEqual(0, snapshot.pending)
            XCTAssertEqual(0, snapshot.openedConnectionsCount)

            // cleanup
            provider.closePromise.succeed(())
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    func testReleaseInactiveConnectionEmptyQueueHasConnections() throws {
        let channel = EmbeddedChannel()

        let provider = try HTTP1ConnectionProvider(key: .init(.init(url: "http://some.test")), eventLoop: channel.eventLoop, configuration: .init(), pool: .init(configuration: .init()))
        var snapshot = provider.state.testsOnly_getInternalState()

        snapshot.pending = 0
        snapshot.openedConnectionsCount = 2
        let connection = Connection(channel: channel, provider: provider)
        snapshot.leasedConnections.insert(ConnectionKey(connection))
        let available = Connection(channel: channel, provider: provider)
        snapshot.availableConnections.append(available)

        provider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(1, snapshot.availableConnections.count)
        XCTAssertEqual(1, snapshot.leasedConnections.count)
        XCTAssertEqual(0, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(2, snapshot.openedConnectionsCount)

        let action = provider.state.release(connection: connection, closing: true)
        switch action {
        case .none:
            snapshot = provider.state.testsOnly_getInternalState()
            XCTAssertEqual(1, snapshot.availableConnections.count)
            XCTAssertEqual(0, snapshot.leasedConnections.count)
            XCTAssertEqual(0, snapshot.waiters.count)
            XCTAssertEqual(0, snapshot.pending)
            XCTAssertEqual(1, snapshot.openedConnectionsCount)

            // cleanup
            provider.closePromise.succeed(())
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    func testReleaseAliveConnectionHasWaiter() throws {
        let channel = ActiveChannel()

        let provider = try HTTP1ConnectionProvider(key: .init(.init(url: "http://some.test")), eventLoop: channel.eventLoop, configuration: .init(), pool: .init(configuration: .init()))
        var snapshot = provider.state.testsOnly_getInternalState()

        snapshot.pending = 0
        snapshot.openedConnectionsCount = 1
        let connection = Connection(channel: channel, provider: provider)
        snapshot.leasedConnections.insert(ConnectionKey(connection))
        snapshot.waiters.append(.init(promise: channel.eventLoop.makePromise(), setupComplete: channel.eventLoop.makeSucceededFuture(()), preference: .indifferent))

        provider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(0, snapshot.availableConnections.count)
        XCTAssertEqual(1, snapshot.leasedConnections.count)
        XCTAssertEqual(1, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(1, snapshot.openedConnectionsCount)

        let action = provider.state.release(connection: connection, closing: false)
        switch action {
        case .lease(let connection, let waiter):
            // XCTAssertTrue(connection.isInUse)
            snapshot = provider.state.testsOnly_getInternalState()
            XCTAssertEqual(0, snapshot.availableConnections.count)
            XCTAssertEqual(1, snapshot.leasedConnections.count)
            XCTAssertEqual(0, snapshot.waiters.count)
            XCTAssertEqual(0, snapshot.pending)
            XCTAssertEqual(1, snapshot.openedConnectionsCount)

            // cleanup
            waiter.promise.succeed(connection)
            snapshot.openedConnectionsCount = 0
            provider.state.testsOnly_setInternalState(snapshot)
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    func testReleaseInactiveConnectionHasWaitersNoConnections() throws {
        let channel = EmbeddedChannel()

        let provider = try HTTP1ConnectionProvider(key: .init(.init(url: "http://some.test")), eventLoop: channel.eventLoop, configuration: .init(), pool: .init(configuration: .init()))
        var snapshot = provider.state.testsOnly_getInternalState()

        snapshot.pending = 0
        snapshot.openedConnectionsCount = 1
        let connection = Connection(channel: channel, provider: provider)
        snapshot.leasedConnections.insert(ConnectionKey(connection))
        snapshot.waiters.append(.init(promise: channel.eventLoop.makePromise(), setupComplete: channel.eventLoop.makeSucceededFuture(()), preference: .indifferent))

        provider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(0, snapshot.availableConnections.count)
        XCTAssertEqual(1, snapshot.leasedConnections.count)
        XCTAssertEqual(1, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(1, snapshot.openedConnectionsCount)

        let action = provider.state.release(connection: connection, closing: true)
        switch action {
        case .create(let waiter):
            snapshot = provider.state.testsOnly_getInternalState()
            XCTAssertEqual(0, snapshot.availableConnections.count)
            XCTAssertEqual(0, snapshot.leasedConnections.count)
            XCTAssertEqual(0, snapshot.waiters.count)
            XCTAssertEqual(0, snapshot.pending)
            XCTAssertEqual(1, snapshot.openedConnectionsCount)

            // cleanup
            waiter.promise.fail(TempError())
            snapshot.openedConnectionsCount = 0
            provider.state.testsOnly_setInternalState(snapshot)
            provider.closePromise.succeed(())
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    func testReleaseInactiveConnectionHasWaitersHasConnections() throws {
        let channel = EmbeddedChannel()

        let provider = try HTTP1ConnectionProvider(key: .init(.init(url: "http://some.test")), eventLoop: channel.eventLoop, configuration: .init(), pool: .init(configuration: .init()))
        var snapshot = provider.state.testsOnly_getInternalState()

        snapshot.pending = 0
        snapshot.openedConnectionsCount = 2
        let connection = Connection(channel: channel, provider: provider)
        snapshot.leasedConnections.insert(ConnectionKey(connection))
        snapshot.waiters.append(.init(promise: channel.eventLoop.makePromise(), setupComplete: channel.eventLoop.makeSucceededFuture(()), preference: .indifferent))

        let available = Connection(channel: channel, provider: provider)
        snapshot.availableConnections.append(available)

        provider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(1, snapshot.availableConnections.count)
        XCTAssertEqual(1, snapshot.leasedConnections.count)
        XCTAssertEqual(1, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(2, snapshot.openedConnectionsCount)

        let action = provider.state.release(connection: connection, closing: false)
        switch action {
        case .lease(let connection, let waiter):
            snapshot = provider.state.testsOnly_getInternalState()
            XCTAssertEqual(0, snapshot.availableConnections.count)
            XCTAssertEqual(1, snapshot.leasedConnections.count)
            XCTAssertEqual(0, snapshot.waiters.count)
            XCTAssertEqual(0, snapshot.pending)
            XCTAssertEqual(1, snapshot.openedConnectionsCount)

            // cleanup
            waiter.promise.succeed(connection)
            snapshot.openedConnectionsCount = 0
            provider.state.testsOnly_setInternalState(snapshot)
            provider.closePromise.succeed(())
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    // MARK: - Release on Specific EL Tests

    func testReleaseAliveConnectionSameELHasWaiterSpecificEL() throws {
        let channel = ActiveChannel()

        let provider = try HTTP1ConnectionProvider(key: .init(.init(url: "http://some.test")), eventLoop: channel.eventLoop, configuration: .init(), pool: .init(configuration: .init()))
        var snapshot = provider.state.testsOnly_getInternalState()

        snapshot.pending = 0
        snapshot.openedConnectionsCount = 1
        let connection = Connection(channel: channel, provider: provider)
        snapshot.leasedConnections.insert(ConnectionKey(connection))
        snapshot.waiters.append(.init(promise: channel.eventLoop.makePromise(), setupComplete: channel.eventLoop.makeSucceededFuture(()), preference: .delegateAndChannel(on: channel.eventLoop)))

        provider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(0, snapshot.availableConnections.count)
        XCTAssertEqual(1, snapshot.leasedConnections.count)
        XCTAssertEqual(1, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(1, snapshot.openedConnectionsCount)

        let action = provider.state.release(connection: connection, closing: false)
        switch action {
        case .lease(let connection, let waiter):
            snapshot = provider.state.testsOnly_getInternalState()
            XCTAssertTrue(snapshot.leasedConnections.contains(ConnectionKey(connection)))
            XCTAssertEqual(0, snapshot.availableConnections.count)
            XCTAssertEqual(1, snapshot.leasedConnections.count)
            XCTAssertEqual(0, snapshot.waiters.count)
            XCTAssertEqual(0, snapshot.pending)
            XCTAssertEqual(1, snapshot.openedConnectionsCount)

            // cleanup
            waiter.promise.succeed(connection)
            snapshot.openedConnectionsCount = 0
            provider.state.testsOnly_setInternalState(snapshot)
            provider.closePromise.succeed(())
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    func testReleaseAliveConnectionDifferentELNoSameELConnectionsHasWaiterSpecificEL() throws {
        let channel = ActiveChannel()
        let eventLoop = EmbeddedEventLoop()

        let provider = try HTTP1ConnectionProvider(key: .init(.init(url: "http://some.test")), eventLoop: channel.eventLoop, configuration: .init(), pool: .init(configuration: .init()))
        var snapshot = provider.state.testsOnly_getInternalState()

        snapshot.pending = 0
        snapshot.openedConnectionsCount = 1
        let connection = Connection(channel: channel, provider: provider)
        snapshot.leasedConnections.insert(ConnectionKey(connection))
        snapshot.waiters.append(.init(promise: channel.eventLoop.makePromise(), setupComplete: eventLoop.makeSucceededFuture(()), preference: .delegateAndChannel(on: eventLoop)))

        provider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(0, snapshot.availableConnections.count)
        XCTAssertEqual(1, snapshot.leasedConnections.count)
        XCTAssertEqual(1, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(1, snapshot.openedConnectionsCount)

        let action = provider.state.release(connection: connection, closing: false)
        switch action {
        case .parkAnd(let connection, .create(let waiter)):
            snapshot = provider.state.testsOnly_getInternalState()
            XCTAssertFalse(snapshot.leasedConnections.contains(ConnectionKey(connection)))
            XCTAssertEqual(1, snapshot.availableConnections.count)
            XCTAssertEqual(0, snapshot.leasedConnections.count)
            XCTAssertEqual(0, snapshot.waiters.count)
            XCTAssertEqual(0, snapshot.pending)
            XCTAssertEqual(2, snapshot.openedConnectionsCount)

            // cleanup
            waiter.promise.succeed(connection)
            snapshot.openedConnectionsCount = 0
            provider.state.testsOnly_setInternalState(snapshot)
            provider.closePromise.succeed(())
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    func testReleaseAliveConnectionDifferentELHasSameELConnectionsHasWaiterSpecificEL() throws {
        let channel = ActiveChannel()
        let otherChannel = EmbeddedChannel()

        let provider = try HTTP1ConnectionProvider(key: .init(.init(url: "http://some.test")), eventLoop: channel.eventLoop, configuration: .init(), pool: .init(configuration: .init()))
        var snapshot = provider.state.testsOnly_getInternalState()

        snapshot.pending = 0
        snapshot.openedConnectionsCount = 2
        let connection = Connection(channel: channel, provider: provider)
        snapshot.leasedConnections.insert(ConnectionKey(connection))
        snapshot.waiters.append(.init(promise: channel.eventLoop.makePromise(), setupComplete: channel.eventLoop.makeSucceededFuture(()), preference: .delegateAndChannel(on: otherChannel.eventLoop)))

        let available = Connection(channel: otherChannel, provider: provider)
        snapshot.availableConnections.append(available)

        provider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(1, snapshot.availableConnections.count)
        XCTAssertEqual(1, snapshot.leasedConnections.count)
        XCTAssertEqual(1, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(2, snapshot.openedConnectionsCount)

        let action = provider.state.release(connection: connection, closing: false)
        switch action {
        case .parkAnd(let connection, .lease(let replacement, let waiter)):
            snapshot = provider.state.testsOnly_getInternalState()
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
            provider.state.testsOnly_setInternalState(snapshot)
            provider.closePromise.succeed(())
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    func testReleaseAliveConnectionDifferentELNoSameELConnectionsOnLimitHasWaiterSpecificEL() throws {
        let channel = ActiveChannel()
        let otherChannel = EmbeddedChannel()

        let provider = try HTTP1ConnectionProvider(key: .init(.init(url: "http://some.test")), eventLoop: channel.eventLoop, configuration: .init(), pool: .init(configuration: .init()))
        var snapshot = provider.state.testsOnly_getInternalState()

        snapshot.pending = 0
        snapshot.openedConnectionsCount = 8
        let connection = Connection(channel: channel, provider: provider)
        snapshot.leasedConnections.insert(ConnectionKey(connection))
        snapshot.waiters.append(.init(promise: channel.eventLoop.makePromise(), setupComplete: channel.eventLoop.makeSucceededFuture(()), preference: .delegateAndChannel(on: otherChannel.eventLoop)))

        let available = Connection(channel: channel, provider: provider)
        snapshot.availableConnections.append(available)

        provider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(1, snapshot.availableConnections.count)
        XCTAssertEqual(1, snapshot.leasedConnections.count)
        XCTAssertEqual(1, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(8, snapshot.openedConnectionsCount)

        let action = provider.state.release(connection: connection, closing: false)
        switch action {
        case .replace(let connection, let waiter):
            snapshot = provider.state.testsOnly_getInternalState()
            XCTAssertTrue(snapshot.leasedConnections.contains(ConnectionKey(connection)))
            XCTAssertEqual(1, snapshot.availableConnections.count)
            XCTAssertEqual(1, snapshot.leasedConnections.count)
            XCTAssertEqual(0, snapshot.waiters.count)
            XCTAssertEqual(0, snapshot.pending)
            XCTAssertEqual(8, snapshot.openedConnectionsCount)

            // cleanup
            waiter.promise.fail(TempError())
            snapshot.openedConnectionsCount = 0
            provider.state.testsOnly_setInternalState(snapshot)
            provider.closePromise.succeed(())
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    func testReleaseInactiveConnectionHasWaitersHasSameELConnectionsSpecificEL() throws {
        let channel = EmbeddedChannel()
        let otherChannel = EmbeddedChannel()

        let provider = try HTTP1ConnectionProvider(key: .init(.init(url: "http://some.test")), eventLoop: channel.eventLoop, configuration: .init(), pool: .init(configuration: .init()))
        var snapshot = provider.state.testsOnly_getInternalState()

        snapshot.pending = 0
        snapshot.openedConnectionsCount = 2
        let connection = Connection(channel: channel, provider: provider)
        snapshot.leasedConnections.insert(ConnectionKey(connection))
        snapshot.waiters.append(.init(promise: channel.eventLoop.makePromise(), setupComplete: channel.eventLoop.makeSucceededFuture(()), preference: .delegateAndChannel(on: otherChannel.eventLoop)))

        let available = Connection(channel: otherChannel, provider: provider)
        snapshot.availableConnections.append(available)

        provider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(1, snapshot.availableConnections.count)
        XCTAssertEqual(1, snapshot.leasedConnections.count)
        XCTAssertEqual(1, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(2, snapshot.openedConnectionsCount)

        let action = provider.state.release(connection: connection, closing: false)
        switch action {
        case .lease(let connection, let waiter):
            snapshot = provider.state.testsOnly_getInternalState()
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
            provider.state.testsOnly_setInternalState(snapshot)
            provider.closePromise.succeed(())
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    func testReleaseInactiveConnectionHasWaitersNoSameELConnectionsSpecificEL() throws {
        let channel = EmbeddedChannel()
        let otherChannel = EmbeddedChannel()

        let provider = try HTTP1ConnectionProvider(key: .init(.init(url: "http://some.test")), eventLoop: channel.eventLoop, configuration: .init(), pool: .init(configuration: .init()))
        var snapshot = provider.state.testsOnly_getInternalState()

        snapshot.pending = 0
        snapshot.openedConnectionsCount = 2
        let connection = Connection(channel: channel, provider: provider)
        snapshot.leasedConnections.insert(ConnectionKey(connection))
        snapshot.waiters.append(.init(promise: channel.eventLoop.makePromise(), setupComplete: channel.eventLoop.makeSucceededFuture(()), preference: .delegateAndChannel(on: otherChannel.eventLoop)))

        let available = Connection(channel: channel, provider: provider)
        snapshot.availableConnections.append(available)

        provider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(1, snapshot.availableConnections.count)
        XCTAssertEqual(1, snapshot.leasedConnections.count)
        XCTAssertEqual(1, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(2, snapshot.openedConnectionsCount)

        let action = provider.state.release(connection: connection, closing: false)
        switch action {
        case .create(let waiter):
            snapshot = provider.state.testsOnly_getInternalState()
            XCTAssertEqual(1, snapshot.availableConnections.count)
            XCTAssertEqual(0, snapshot.leasedConnections.count)
            XCTAssertEqual(0, snapshot.waiters.count)
            XCTAssertEqual(0, snapshot.pending)
            XCTAssertEqual(2, snapshot.openedConnectionsCount)

            // cleanup
            waiter.promise.fail(TempError())
            snapshot.openedConnectionsCount = 0
            provider.state.testsOnly_setInternalState(snapshot)
            provider.closePromise.succeed(())
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    // MARK: - Next Waiter Tests

    func testNextWaiterEmptyQueue() throws {
        let channel = ActiveChannel()

        let provider = try HTTP1ConnectionProvider(key: .init(.init(url: "http://some.test")), eventLoop: channel.eventLoop, configuration: .init(), pool: .init(configuration: .init()))
        var snapshot = provider.state.testsOnly_getInternalState()

        snapshot.pending = 0
        provider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(0, snapshot.availableConnections.count)
        XCTAssertEqual(0, snapshot.leasedConnections.count)
        XCTAssertEqual(0, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(0, snapshot.openedConnectionsCount)

        let action = provider.state.processNextWaiter()
        switch action {
        case .closeProvider:
            snapshot = provider.state.testsOnly_getInternalState()
            XCTAssertEqual(0, snapshot.availableConnections.count)
            XCTAssertEqual(0, snapshot.leasedConnections.count)
            XCTAssertEqual(0, snapshot.waiters.count)
            XCTAssertEqual(0, snapshot.pending)
            XCTAssertEqual(0, snapshot.openedConnectionsCount)

            // cleanup
            provider.closePromise.succeed(())
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    func testNextWaiterEmptyQueueHasConnections() throws {
        let channel = ActiveChannel()

        let provider = try HTTP1ConnectionProvider(key: .init(.init(url: "http://some.test")), eventLoop: channel.eventLoop, configuration: .init(), pool: .init(configuration: .init()))
        var snapshot = provider.state.testsOnly_getInternalState()

        snapshot.pending = 0
        snapshot.openedConnectionsCount = 1

        let available = Connection(channel: channel, provider: provider)
        snapshot.availableConnections.append(available)

        provider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(1, snapshot.availableConnections.count)
        XCTAssertEqual(0, snapshot.leasedConnections.count)
        XCTAssertEqual(0, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(1, snapshot.openedConnectionsCount)

        let action = provider.state.processNextWaiter()
        switch action {
        case .none:
            snapshot = provider.state.testsOnly_getInternalState()
            XCTAssertEqual(1, snapshot.availableConnections.count)
            XCTAssertEqual(0, snapshot.leasedConnections.count)
            XCTAssertEqual(0, snapshot.waiters.count)
            XCTAssertEqual(0, snapshot.pending)
            XCTAssertEqual(1, snapshot.openedConnectionsCount)

            // cleanup
            provider.closePromise.succeed(())
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    func testNextWaiterHasWaitersHasConnections() throws {
        let channel = EmbeddedChannel()

        let provider = try HTTP1ConnectionProvider(key: .init(.init(url: "http://some.test")), eventLoop: channel.eventLoop, configuration: .init(), pool: .init(configuration: .init()))
        var snapshot = provider.state.testsOnly_getInternalState()

        snapshot.pending = 0
        snapshot.openedConnectionsCount = 1
        snapshot.waiters.append(.init(promise: channel.eventLoop.makePromise(), setupComplete: channel.eventLoop.makeSucceededFuture(()), preference: .indifferent))

        let available = Connection(channel: channel, provider: provider)
        snapshot.availableConnections.append(available)

        provider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(1, snapshot.availableConnections.count)
        XCTAssertEqual(0, snapshot.leasedConnections.count)
        XCTAssertEqual(1, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(1, snapshot.openedConnectionsCount)

        let action = provider.state.processNextWaiter()
        switch action {
        case .lease(let connection, let waiter):
            snapshot = provider.state.testsOnly_getInternalState()
            XCTAssertTrue(snapshot.leasedConnections.contains(ConnectionKey(connection)))
            XCTAssertEqual(0, snapshot.availableConnections.count)
            XCTAssertEqual(1, snapshot.leasedConnections.count)
            XCTAssertEqual(0, snapshot.waiters.count)
            XCTAssertEqual(0, snapshot.pending)
            XCTAssertEqual(1, snapshot.openedConnectionsCount)

            // cleanup
            waiter.promise.succeed(connection)
            snapshot.openedConnectionsCount = 0
            provider.state.testsOnly_setInternalState(snapshot)
            provider.closePromise.succeed(())
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    func testNextWaiterHasWaitersHasSameELConnectionsSpecificEL() throws {
        let channel = EmbeddedChannel()

        let provider = try HTTP1ConnectionProvider(key: .init(.init(url: "http://some.test")), eventLoop: channel.eventLoop, configuration: .init(), pool: .init(configuration: .init()))
        var snapshot = provider.state.testsOnly_getInternalState()

        snapshot.pending = 0
        snapshot.openedConnectionsCount = 1
        snapshot.waiters.append(.init(promise: channel.eventLoop.makePromise(), setupComplete: channel.eventLoop.makeSucceededFuture(()), preference: .delegateAndChannel(on: channel.eventLoop)))

        let available = Connection(channel: channel, provider: provider)
        snapshot.availableConnections.append(available)

        provider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(1, snapshot.availableConnections.count)
        XCTAssertEqual(0, snapshot.leasedConnections.count)
        XCTAssertEqual(1, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(1, snapshot.openedConnectionsCount)

        let action = provider.state.processNextWaiter()
        switch action {
        case .lease(let connection, let waiter):
            var snapshot = provider.state.testsOnly_getInternalState()
            XCTAssertTrue(snapshot.leasedConnections.contains(ConnectionKey(connection)))
            XCTAssertEqual(0, snapshot.availableConnections.count)
            XCTAssertEqual(1, snapshot.leasedConnections.count)
            XCTAssertEqual(0, snapshot.waiters.count)
            XCTAssertEqual(0, snapshot.pending)
            XCTAssertEqual(1, snapshot.openedConnectionsCount)

            // cleanup
            waiter.promise.succeed(connection)
            snapshot.openedConnectionsCount = 0
            provider.state.testsOnly_setInternalState(snapshot)
            provider.closePromise.succeed(())
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    func testNextWaiterHasWaitersHasDifferentELConnectionsSpecificEL() throws {
        let channel = EmbeddedChannel()
        let eventLoop = EmbeddedEventLoop()

        let provider = try HTTP1ConnectionProvider(key: .init(.init(url: "http://some.test")), eventLoop: channel.eventLoop, configuration: .init(), pool: .init(configuration: .init()))
        var snapshot = provider.state.testsOnly_getInternalState()

        snapshot.pending = 0
        snapshot.openedConnectionsCount = 1
        snapshot.waiters.append(.init(promise: channel.eventLoop.makePromise(), setupComplete: eventLoop.makeSucceededFuture(()), preference: .delegateAndChannel(on: eventLoop)))

        let available = Connection(channel: channel, provider: provider)
        snapshot.availableConnections.append(available)

        provider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(1, snapshot.availableConnections.count)
        XCTAssertEqual(0, snapshot.leasedConnections.count)
        XCTAssertEqual(1, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(1, snapshot.openedConnectionsCount)

        let action = provider.state.processNextWaiter()
        switch action {
        case .create(let waiter):
            snapshot = provider.state.testsOnly_getInternalState()
            XCTAssertEqual(1, snapshot.availableConnections.count)
            XCTAssertEqual(0, snapshot.leasedConnections.count)
            XCTAssertEqual(0, snapshot.waiters.count)
            XCTAssertEqual(0, snapshot.pending)
            XCTAssertEqual(2, snapshot.openedConnectionsCount)

            // cleanup
            waiter.promise.fail(TempError())
            snapshot.openedConnectionsCount = 0
            provider.state.testsOnly_setInternalState(snapshot)
            provider.closePromise.succeed(())
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    // MARK: - Timeout and Remote Close Tests

    func testTimeoutLeasedConnection() throws {
        let channel = EmbeddedChannel()

        let provider = try HTTP1ConnectionProvider(key: .init(.init(url: "http://some.test")), eventLoop: channel.eventLoop, configuration: .init(), pool: .init(configuration: .init()))
        var snapshot = provider.state.testsOnly_getInternalState()

        let connection = Connection(channel: channel, provider: provider)
        snapshot.pending = 0
        snapshot.openedConnectionsCount = 1
        snapshot.leasedConnections.insert(ConnectionKey(connection))

        provider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(0, snapshot.availableConnections.count)
        XCTAssertEqual(1, snapshot.leasedConnections.count)
        XCTAssertEqual(0, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(1, snapshot.openedConnectionsCount)

        let action = provider.state.timeout(connection: connection)
        switch action {
        case .none:
            snapshot = provider.state.testsOnly_getInternalState()
            XCTAssertEqual(0, snapshot.availableConnections.count)
            XCTAssertEqual(1, snapshot.leasedConnections.count)
            XCTAssertEqual(0, snapshot.waiters.count)
            XCTAssertEqual(0, snapshot.pending)
            XCTAssertEqual(1, snapshot.openedConnectionsCount)

            // cleanup
            provider.closePromise.succeed(())
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    func testTimeoutAvailableConnection() throws {
        let channel = EmbeddedChannel()

        let provider = try HTTP1ConnectionProvider(key: .init(.init(url: "http://some.test")), eventLoop: channel.eventLoop, configuration: .init(), pool: .init(configuration: .init()))
        var snapshot = provider.state.testsOnly_getInternalState()

        let connection = Connection(channel: channel, provider: provider)
        snapshot.pending = 0
        snapshot.openedConnectionsCount = 1
        snapshot.availableConnections.append(connection)

        provider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(1, snapshot.availableConnections.count)
        XCTAssertEqual(0, snapshot.leasedConnections.count)
        XCTAssertEqual(0, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(1, snapshot.openedConnectionsCount)

        let action = provider.state.timeout(connection: connection)
        switch action {
        case .closeAnd(_, let after):
            switch after {
            case .closeProvider:
                break
            default:
                XCTFail("Unexpected action: \(action)")
            }
            snapshot = provider.state.testsOnly_getInternalState()
            XCTAssertEqual(0, snapshot.availableConnections.count)
            XCTAssertEqual(0, snapshot.leasedConnections.count)
            XCTAssertEqual(0, snapshot.waiters.count)
            XCTAssertEqual(0, snapshot.pending)
            XCTAssertEqual(0, snapshot.openedConnectionsCount)

            // cleanup
            provider.closePromise.succeed(())
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    func testRemoteClosedLeasedConnection() throws {
        let channel = EmbeddedChannel()

        let provider = try HTTP1ConnectionProvider(key: .init(.init(url: "http://some.test")), eventLoop: channel.eventLoop, configuration: .init(), pool: .init(configuration: .init()))
        var snapshot = provider.state.testsOnly_getInternalState()

        let connection = Connection(channel: channel, provider: provider)
        snapshot.pending = 0
        snapshot.openedConnectionsCount = 1
        snapshot.leasedConnections.insert(ConnectionKey(connection))

        provider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(0, snapshot.availableConnections.count)
        XCTAssertEqual(1, snapshot.leasedConnections.count)
        XCTAssertEqual(0, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(1, snapshot.openedConnectionsCount)

        let action = provider.state.remoteClosed(connection: connection)
        switch action {
        case .none:
            snapshot = provider.state.testsOnly_getInternalState()
            XCTAssertEqual(0, snapshot.availableConnections.count)
            XCTAssertEqual(1, snapshot.leasedConnections.count)
            XCTAssertEqual(0, snapshot.waiters.count)
            XCTAssertEqual(0, snapshot.pending)
            XCTAssertEqual(1, snapshot.openedConnectionsCount)

            // cleanup
            provider.closePromise.succeed(())
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    func testRemoteClosedAvailableConnection() throws {
        let channel = EmbeddedChannel()

        let provider = try HTTP1ConnectionProvider(key: .init(.init(url: "http://some.test")), eventLoop: channel.eventLoop, configuration: .init(), pool: .init(configuration: .init()))
        var snapshot = provider.state.testsOnly_getInternalState()

        let connection = Connection(channel: channel, provider: provider)
        snapshot.pending = 0
        snapshot.openedConnectionsCount = 1
        snapshot.availableConnections.append(connection)

        provider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(1, snapshot.availableConnections.count)
        XCTAssertEqual(0, snapshot.leasedConnections.count)
        XCTAssertEqual(0, snapshot.waiters.count)
        XCTAssertEqual(0, snapshot.pending)
        XCTAssertEqual(1, snapshot.openedConnectionsCount)

        let action = provider.state.remoteClosed(connection: connection)
        switch action {
        case .closeProvider:
            snapshot = provider.state.testsOnly_getInternalState()
            XCTAssertEqual(0, snapshot.availableConnections.count)
            XCTAssertEqual(0, snapshot.leasedConnections.count)
            XCTAssertEqual(0, snapshot.waiters.count)
            XCTAssertEqual(0, snapshot.pending)
            XCTAssertEqual(0, snapshot.openedConnectionsCount)

            // cleanup
            provider.closePromise.succeed(())
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    // MARK: - Connection Tests

    func testConnectionReleaseActive() throws {
        let channel = ActiveChannel()

        let provider = try HTTP1ConnectionProvider(key: .init(.init(url: "http://some.test")), eventLoop: channel.eventLoop, configuration: .init(), pool: .init(configuration: .init()))
        var snapshot = provider.state.testsOnly_getInternalState()

        let connection = Connection(channel: channel, provider: provider)
        snapshot.openedConnectionsCount = 1
        snapshot.leasedConnections.insert(ConnectionKey(connection))

        provider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(0, snapshot.availableConnections.count)
        XCTAssertEqual(1, snapshot.leasedConnections.count)
        XCTAssertEqual(0, snapshot.waiters.count)
        XCTAssertEqual(1, snapshot.pending)
        XCTAssertEqual(1, snapshot.openedConnectionsCount)

        connection.release(closing: false)

        // XCTAssertFalse(connection.isInUse)
        snapshot = provider.state.testsOnly_getInternalState()
        XCTAssertEqual(1, snapshot.availableConnections.count)
        XCTAssertEqual(0, snapshot.leasedConnections.count)
        XCTAssertEqual(0, snapshot.waiters.count)
        XCTAssertEqual(1, snapshot.pending)
        XCTAssertEqual(1, snapshot.openedConnectionsCount)

        // cleanup
        snapshot.pending = 0
        provider.state.testsOnly_setInternalState(snapshot)
        provider.closePromise.succeed(())
    }

    func testConnectionReleaseInactive() throws {
        let channel = EmbeddedChannel()

        let provider = try HTTP1ConnectionProvider(key: .init(.init(url: "http://some.test")), eventLoop: channel.eventLoop, configuration: .init(), pool: .init(configuration: .init()))
        var snapshot = provider.state.testsOnly_getInternalState()

        let connection = Connection(channel: channel, provider: provider)
        snapshot.openedConnectionsCount = 1
        snapshot.leasedConnections.insert(ConnectionKey(connection))

        provider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(0, snapshot.availableConnections.count)
        XCTAssertEqual(1, snapshot.leasedConnections.count)
        XCTAssertEqual(0, snapshot.waiters.count)
        XCTAssertEqual(1, snapshot.pending)
        XCTAssertEqual(1, snapshot.openedConnectionsCount)

        connection.release(closing: true)

        snapshot = provider.state.testsOnly_getInternalState()
        XCTAssertEqual(0, snapshot.availableConnections.count)
        XCTAssertEqual(0, snapshot.leasedConnections.count)
        XCTAssertEqual(0, snapshot.waiters.count)
        XCTAssertEqual(1, snapshot.pending)
        XCTAssertEqual(0, snapshot.openedConnectionsCount)

        // cleanup
        snapshot.pending = 0
        provider.state.testsOnly_setInternalState(snapshot)
        provider.closePromise.succeed(())
    }

    func testConnectionRemoteCloseRelease() throws {
        let channel = EmbeddedChannel()

        let provider = try HTTP1ConnectionProvider(key: .init(.init(url: "http://some.test")), eventLoop: channel.eventLoop, configuration: .init(), pool: .init(configuration: .init()))
        var snapshot = provider.state.testsOnly_getInternalState()

        let connection = Connection(channel: channel, provider: provider)
        snapshot.availableConnections.append(connection)
        snapshot.openedConnectionsCount = 1

        provider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(1, snapshot.availableConnections.count)
        XCTAssertEqual(0, snapshot.leasedConnections.count)
        XCTAssertEqual(0, snapshot.waiters.count)
        XCTAssertEqual(1, snapshot.pending)
        XCTAssertEqual(1, snapshot.openedConnectionsCount)

        connection.remoteClosed()

        snapshot = provider.state.testsOnly_getInternalState()
        XCTAssertEqual(0, snapshot.availableConnections.count)
        XCTAssertEqual(0, snapshot.leasedConnections.count)
        XCTAssertEqual(0, snapshot.waiters.count)
        XCTAssertEqual(1, snapshot.pending)
        XCTAssertEqual(0, snapshot.openedConnectionsCount)

        // cleanup
        snapshot.pending = 0
        provider.state.testsOnly_setInternalState(snapshot)
        provider.closePromise.succeed(())
    }

    func testConnectionTimeoutRelease() throws {
        let channel = EmbeddedChannel()

        let provider = try HTTP1ConnectionProvider(key: .init(.init(url: "http://some.test")), eventLoop: channel.eventLoop, configuration: .init(), pool: .init(configuration: .init()))
        var snapshot = provider.state.testsOnly_getInternalState()

        let connection = Connection(channel: channel, provider: provider)
        snapshot.availableConnections.append(connection)
        snapshot.openedConnectionsCount = 1

        provider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(1, snapshot.availableConnections.count)
        XCTAssertEqual(0, snapshot.leasedConnections.count)
        XCTAssertEqual(0, snapshot.waiters.count)
        XCTAssertEqual(1, snapshot.pending)
        XCTAssertEqual(1, snapshot.openedConnectionsCount)

        connection.timeout()

        snapshot = provider.state.testsOnly_getInternalState()
        XCTAssertEqual(0, snapshot.availableConnections.count)
        XCTAssertEqual(0, snapshot.leasedConnections.count)
        XCTAssertEqual(0, snapshot.waiters.count)
        XCTAssertEqual(1, snapshot.pending)
        XCTAssertEqual(0, snapshot.openedConnectionsCount)

        // cleanup
        snapshot.pending = 0
        provider.state.testsOnly_setInternalState(snapshot)
        provider.closePromise.succeed(())
    }

    func testAcquireAvailableBecomesUnavailable() throws {
        let eventLoop = EmbeddedEventLoop()
        let channel = ActiveChannel()

        let provider = try HTTP1ConnectionProvider(key: .init(.init(url: "http://some.test")), eventLoop: eventLoop, configuration: .init(), pool: .init(configuration: .init()))
        var snapshot = provider.state.testsOnly_getInternalState()

        let connection = Connection(channel: channel, provider: provider)
        snapshot.availableConnections.append(connection)
        snapshot.openedConnectionsCount = 1

        provider.state.testsOnly_setInternalState(snapshot)

        XCTAssertEqual(1, snapshot.availableConnections.count)
        XCTAssertEqual(0, snapshot.leasedConnections.count)
        XCTAssertEqual(0, snapshot.waiters.count)
        XCTAssertEqual(1, snapshot.pending)
        XCTAssertEqual(1, snapshot.openedConnectionsCount)

        let action = provider.state.acquire(waiter: .init(promise: eventLoop.makePromise(), setupComplete: eventLoop.makeSucceededFuture(()), preference: .indifferent))
        switch action {
        case .lease(let connection, let waiter):
            // Since this connection is already in use, this should be a no-op and state should not have changed from normal lease
            connection.timeout()

            snapshot = provider.state.testsOnly_getInternalState()
            XCTAssertTrue(connection.isActiveEstimation)
            XCTAssertTrue(snapshot.leasedConnections.contains(ConnectionKey(connection)))
            XCTAssertEqual(0, snapshot.availableConnections.count)
            XCTAssertEqual(1, snapshot.leasedConnections.count)
            XCTAssertEqual(0, snapshot.waiters.count)
            XCTAssertEqual(0, snapshot.pending)
            XCTAssertEqual(1, snapshot.openedConnectionsCount)

            // This is unrecoverable, but in this case we create a new connection, so state again should not change, even though release will be called
            // This is important to prevent provider deletion since connection is released and there could be 0 waiters
            connection.remoteClosed()

            snapshot = provider.state.testsOnly_getInternalState()
            XCTAssertTrue(snapshot.leasedConnections.contains(ConnectionKey(connection)))
            XCTAssertEqual(0, snapshot.availableConnections.count)
            XCTAssertEqual(1, snapshot.leasedConnections.count)
            XCTAssertEqual(0, snapshot.waiters.count)
            XCTAssertEqual(0, snapshot.pending)
            XCTAssertEqual(1, snapshot.openedConnectionsCount)

            waiter.promise.succeed(connection)

            // cleanup
            snapshot.openedConnectionsCount = 0
            provider.state.testsOnly_setInternalState(snapshot)
            provider.closePromise.succeed(())
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }
}

class ActiveChannel: Channel {
    var allocator: ByteBufferAllocator
    var closeFuture: EventLoopFuture<Void>
    var eventLoop: EventLoop

    var localAddress: SocketAddress?
    var remoteAddress: SocketAddress?
    var parent: Channel?
    var isWritable: Bool = true
    var isActive: Bool = true

    init() {
        self.allocator = ByteBufferAllocator()
        self.eventLoop = EmbeddedEventLoop()
        self.closeFuture = self.eventLoop.makeSucceededFuture(())
    }

    var _channelCore: ChannelCore {
        preconditionFailure("Not implemented")
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
