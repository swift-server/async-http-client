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
import NIO
import XCTest

extension ConnectionPoolTests {
    func buildState(count: Int, release: Bool = true, eventLoop: EventLoop? = nil) -> (HTTP1ConnectionProvider.ConnectionsState<Connection>, [Connection]) {
        let eventLoop = eventLoop ?? self.eventLoop!

        var state = HTTP1ConnectionProvider.ConnectionsState<Connection>(eventLoop: eventLoop)
        var items: [Connection] = []

        if count == 0 {
            return (state, items)
        }

        let channel = ActiveChannel(eventLoop: self.eventLoop)

        for _ in 1...count {
            // Set up connection pool to have one available connection
            do {
                let connection = Connection(channel: channel, provider: self.http1ConnectionProvider)
                items.append(connection)
                // First, we ask the empty pool for a connection, triggering connection creation
                XCTAssertTrue(state.enqueue())
                let action = state.acquire(waiter: .init(promise: eventLoop.makePromise(), setupComplete: eventLoop.makeSucceededFuture(()), preference: .indifferent))

                switch action {
                case .create(let waiter):
                    waiter.promise.succeed(connection)
                default:
                    XCTFail("Unexpected action: \(action)")
                }

                // We offer the connection to the pool so that it can be tracked
                _ = state.offer(connection: connection)
            }
        }

        if release {
            for item in items {
                // No we release the connection, making it available for the next caller
                _ = state.release(connection: item, closing: false)
            }
        }
        return (state, items)
    }
}

func XCTAssertState<ConnectionType>(_ state: HTTP1ConnectionProvider.ConnectionsState<ConnectionType>, available: Int, leased: Int, waiters: Int, pending: Int, opened: Int) {
    let snapshot = state.testsOnly_getInternalState()
    XCTAssertEqual(available, snapshot.availableConnections.count)
    XCTAssertEqual(leased, snapshot.leasedConnections.count)
    XCTAssertEqual(waiters, snapshot.waiters.count)
    XCTAssertEqual(pending, snapshot.pending)
    XCTAssertEqual(opened, snapshot.openedConnectionsCount)
}

func XCTAssertState<ConnectionType>(_ state: HTTP1ConnectionProvider.ConnectionsState<ConnectionType>, available: Int, leased: Int, waiters: Int, pending: Int, opened: Int, isLeased connection: ConnectionType) {
    let snapshot = state.testsOnly_getInternalState()
    XCTAssertEqual(available, snapshot.availableConnections.count)
    XCTAssertEqual(leased, snapshot.leasedConnections.count)
    XCTAssertEqual(waiters, snapshot.waiters.count)
    XCTAssertEqual(pending, snapshot.pending)
    XCTAssertEqual(opened, snapshot.openedConnectionsCount)
    XCTAssertTrue(snapshot.leasedConnections.contains(ConnectionKey(connection)))
}

func XCTAssertState<ConnectionType>(_ state: HTTP1ConnectionProvider.ConnectionsState<ConnectionType>, available: Int, leased: Int, waiters: Int, pending: Int, opened: Int, isNotLeased connection: ConnectionType) {
    let snapshot = state.testsOnly_getInternalState()
    XCTAssertEqual(available, snapshot.availableConnections.count)
    XCTAssertEqual(leased, snapshot.leasedConnections.count)
    XCTAssertEqual(waiters, snapshot.waiters.count)
    XCTAssertEqual(pending, snapshot.pending)
    XCTAssertEqual(opened, snapshot.openedConnectionsCount)
    XCTAssertFalse(snapshot.leasedConnections.contains(ConnectionKey(connection)))
}

struct XCTEmptyError: Error {}

func XCTUnwrap<T>(_ value: T?) throws -> T {
    if let unwrapped = value {
        return unwrapped
    }
    throw XCTEmptyError()
}

struct TempError: Error {}

func XCTAssertStateClose<ConnectionType>(_ state: HTTP1ConnectionProvider.ConnectionsState<ConnectionType>, available: Int, leased: Int, waiters: Int, clean: Bool) throws {
    var state = state

    let (foundWaiters, foundAvailable, foundLeased, foundClean) = try XCTUnwrap(state.close())
    XCTAssertEqual(waiters, foundWaiters.count)
    XCTAssertEqual(available, foundAvailable.count)
    XCTAssertEqual(leased, foundLeased.count)
    XCTAssertEqual(clean, foundClean)

    for waiter in foundWaiters {
        waiter.promise.fail(TempError())
    }

    for lease in foundLeased {
        try lease.cancel().wait()
    }
}
