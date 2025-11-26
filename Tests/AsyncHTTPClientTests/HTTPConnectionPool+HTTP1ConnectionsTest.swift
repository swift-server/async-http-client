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
import NIOEmbedded
import XCTest

@testable import AsyncHTTPClient

class HTTPConnectionPool_HTTP1ConnectionsTests: XCTestCase {
    func testCreatingConnections() {
        let elg = EmbeddedEventLoopGroup(loops: 4)
        var connections = HTTPConnectionPool.HTTP1Connections(
            maximumConcurrentConnections: 8,
            generator: .init(),
            maximumConnectionUses: nil,
            preWarmedHTTP1ConnectionCount: 0
        )

        let el1 = elg.next()
        let el2 = elg.next()

        // general purpose connection
        XCTAssertEqual(connections.startingGeneralPurposeConnections, 0)
        XCTAssertEqual(connections.startingEventLoopConnections(on: el1), 0)
        let conn1ID = connections.createNewConnection(on: el1)
        XCTAssertEqual(connections.startingGeneralPurposeConnections, 1)
        XCTAssertEqual(connections.startingEventLoopConnections(on: el1), 0)
        let conn1: HTTPConnectionPool.Connection = .__testOnly_connection(id: conn1ID, eventLoop: el1)
        let (conn1Index, conn1CreatedContext) = connections.newHTTP1ConnectionEstablished(conn1)
        XCTAssertEqual(conn1CreatedContext.use, .generalPurpose)
        XCTAssert(conn1CreatedContext.eventLoop === el1)
        XCTAssertEqual(connections.leaseConnection(at: conn1Index), conn1)
        XCTAssertEqual(connections.startingGeneralPurposeConnections, 0)

        // eventLoop connection
        let conn2ID = connections.createNewOverflowConnection(on: el2)
        XCTAssertEqual(connections.startingGeneralPurposeConnections, 0)
        XCTAssertEqual(connections.startingEventLoopConnections(on: el2), 1)
        let conn2: HTTPConnectionPool.Connection = .__testOnly_connection(id: conn2ID, eventLoop: el2)
        let (conn2Index, conn2CreatedContext) = connections.newHTTP1ConnectionEstablished(conn2)
        XCTAssertEqual(conn2CreatedContext.use, .eventLoop(el2))
        XCTAssert(conn2CreatedContext.eventLoop === el2)
        XCTAssertEqual(connections.leaseConnection(at: conn2Index), conn2)
        XCTAssertEqual(connections.startingEventLoopConnections(on: el2), 0)
    }

    func testCreatingConnectionAndFailing() {
        let elg = EmbeddedEventLoopGroup(loops: 4)
        var connections = HTTPConnectionPool.HTTP1Connections(
            maximumConcurrentConnections: 8,
            generator: .init(),
            maximumConnectionUses: nil,
            preWarmedHTTP1ConnectionCount: 0
        )

        let el1 = elg.next()
        let el2 = elg.next()

        // general purpose connection
        XCTAssertEqual(connections.startingGeneralPurposeConnections, 0)
        XCTAssertEqual(connections.startingEventLoopConnections(on: el1), 0)
        let conn1ID = connections.createNewConnection(on: el1)
        XCTAssertEqual(conn1ID, 0)
        XCTAssertEqual(connections.startingGeneralPurposeConnections, 1)
        XCTAssertEqual(connections.startingEventLoopConnections(on: el1), 0)
        // connection failed to start. 1. backoff
        let backoff1EL = connections.backoffNextConnectionAttempt(conn1ID)
        XCTAssert(backoff1EL === el1)
        // backoff done. 2. decide what's next
        guard let (conn1FailIndex, conn1FailContext) = connections.failConnection(conn1ID) else {
            return XCTFail("Expected that the connection is remembered")
        }
        XCTAssert(conn1FailContext.eventLoop === el1)
        XCTAssertEqual(conn1FailContext.use, .generalPurpose)
        XCTAssertEqual(conn1FailContext.connectionsStartingForUseCase, 0)
        let (replaceConn1ID, replaceConn1EL) = connections.replaceConnection(at: conn1FailIndex)
        XCTAssert(replaceConn1EL === el1)
        XCTAssertEqual(replaceConn1ID, 1)

        // eventLoop connection
        let conn2ID = connections.createNewOverflowConnection(on: el2)
        // the replacement connection is starting
        XCTAssertEqual(connections.startingGeneralPurposeConnections, 1)
        XCTAssertEqual(connections.startingEventLoopConnections(on: el2), 1)
        let backoff2EL = connections.backoffNextConnectionAttempt(conn2ID)
        XCTAssert(backoff2EL === el2)
        guard let (conn2FailIndex, conn2FailContext) = connections.failConnection(conn2ID) else {
            return XCTFail("Expected that the connection is remembered")
        }
        XCTAssert(conn2FailContext.eventLoop === el2)
        XCTAssertEqual(conn2FailContext.use, .eventLoop(el2))
        XCTAssertEqual(conn2FailContext.connectionsStartingForUseCase, 0)
        connections.removeConnection(at: conn2FailIndex)
        // the replacement connection is still starting
        XCTAssertEqual(connections.startingGeneralPurposeConnections, 1)
    }

    func testLeaseConnectionOnPreferredAndAvailableEL() {
        let elg = EmbeddedEventLoopGroup(loops: 4)
        let el1 = elg.next()
        let el2 = elg.next()
        let el3 = elg.next()
        let el4 = elg.next()

        var connections = HTTPConnectionPool.HTTP1Connections(
            maximumConcurrentConnections: 8,
            generator: .init(),
            maximumConnectionUses: nil,
            preWarmedHTTP1ConnectionCount: 0
        )

        for el in [el1, el2, el3, el4] {
            XCTAssertEqual(connections.startingGeneralPurposeConnections, 0)
            XCTAssertEqual(connections.startingEventLoopConnections(on: el), 0)
            let connID = connections.createNewConnection(on: el)
            XCTAssertEqual(connections.startingGeneralPurposeConnections, 1)
            XCTAssertEqual(connections.startingEventLoopConnections(on: el), 0)
            let conn: HTTPConnectionPool.Connection = .__testOnly_connection(id: connID, eventLoop: el)
            let (_, connCreatedContext) = connections.newHTTP1ConnectionEstablished(conn)
            XCTAssertEqual(connCreatedContext.use, .generalPurpose)
            XCTAssert(connCreatedContext.eventLoop === el)
            XCTAssertEqual(connections.startingGeneralPurposeConnections, 0)
        }

        let connection = connections.leaseConnection(onPreferred: el1)
        XCTAssertEqual(connection, .__testOnly_connection(id: 0, eventLoop: el1))
    }

    func testLeaseConnectionOnPreferredButUnavailableEL() {
        let elg = EmbeddedEventLoopGroup(loops: 5)
        let el1 = elg.next()
        let el2 = elg.next()
        let el3 = elg.next()
        let el4 = elg.next()
        let el5 = elg.next()

        var connections = HTTPConnectionPool.HTTP1Connections(
            maximumConcurrentConnections: 8,
            generator: .init(),
            maximumConnectionUses: nil,
            preWarmedHTTP1ConnectionCount: 0
        )

        for el in [el1, el2, el3, el4] {
            XCTAssertEqual(connections.startingGeneralPurposeConnections, 0)
            XCTAssertEqual(connections.startingEventLoopConnections(on: el), 0)
            let connID = connections.createNewConnection(on: el)
            XCTAssertEqual(connections.startingGeneralPurposeConnections, 1)
            XCTAssertEqual(connections.startingEventLoopConnections(on: el), 0)
            let conn: HTTPConnectionPool.Connection = .__testOnly_connection(id: connID, eventLoop: el)
            let (_, connCreatedContext) = connections.newHTTP1ConnectionEstablished(conn)
            XCTAssertEqual(connCreatedContext.use, .generalPurpose)
            XCTAssert(connCreatedContext.eventLoop === el)
            XCTAssertEqual(connections.startingGeneralPurposeConnections, 0)
        }

        let connection = connections.leaseConnection(onPreferred: el5)
        XCTAssertEqual(connection, .__testOnly_connection(id: 3, eventLoop: el4))
    }

    func testLeaseConnectionOnRequiredButUnavailableEL() {
        let elg = EmbeddedEventLoopGroup(loops: 5)
        let el1 = elg.next()
        let el2 = elg.next()
        let el3 = elg.next()
        let el4 = elg.next()
        let el5 = elg.next()

        var connections = HTTPConnectionPool.HTTP1Connections(
            maximumConcurrentConnections: 8,
            generator: .init(),
            maximumConnectionUses: nil,
            preWarmedHTTP1ConnectionCount: 0
        )

        for el in [el1, el2, el3, el4] {
            XCTAssertEqual(connections.startingGeneralPurposeConnections, 0)
            XCTAssertEqual(connections.startingEventLoopConnections(on: el), 0)
            let connID = connections.createNewConnection(on: el)
            XCTAssertEqual(connections.startingGeneralPurposeConnections, 1)
            XCTAssertEqual(connections.startingEventLoopConnections(on: el), 0)
            let conn: HTTPConnectionPool.Connection = .__testOnly_connection(id: connID, eventLoop: el)
            let (_, connCreatedContext) = connections.newHTTP1ConnectionEstablished(conn)
            XCTAssertEqual(connCreatedContext.use, .generalPurpose)
            XCTAssert(connCreatedContext.eventLoop === el)
            XCTAssertEqual(connections.startingGeneralPurposeConnections, 0)
        }

        let connection = connections.leaseConnection(onRequired: el5)
        XCTAssertEqual(connection, .none)
    }

    func testLeaseConnectionOnRequiredAndAvailableEL() {
        let elg = EmbeddedEventLoopGroup(loops: 2)
        let el1 = elg.next()
        let el2 = elg.next()

        var connections = HTTPConnectionPool.HTTP1Connections(
            maximumConcurrentConnections: 8,
            generator: .init(),
            maximumConnectionUses: nil,
            preWarmedHTTP1ConnectionCount: 0
        )

        for el in [el1, el1, el1, el1, el2] {
            let connID = connections.createNewConnection(on: el)
            let conn: HTTPConnectionPool.Connection = .__testOnly_connection(id: connID, eventLoop: el)
            _ = connections.newHTTP1ConnectionEstablished(conn)
        }

        // 1. get el from general pool, even though el is required!
        guard let lease1 = connections.leaseConnection(onRequired: el1) else {
            return XCTFail("Expected to get a connection at this point.")
        }
        // the last created connection on the correct el is the shortest amount idle. we should use this
        XCTAssertEqual(lease1, .__testOnly_connection(id: 3, eventLoop: el1))
        _ = connections.releaseConnection(lease1.id)

        // 2. create specialized el connection
        let connID5 = connections.createNewOverflowConnection(on: el1)
        XCTAssertEqual(connections.startingEventLoopConnections(on: el1), 1)
        let conn5: HTTPConnectionPool.Connection = .__testOnly_connection(id: connID5, eventLoop: el1)
        _ = connections.newHTTP1ConnectionEstablished(conn5)
        XCTAssertEqual(connections.startingEventLoopConnections(on: el1), 0)

        // 3. get el from specialized pool, since it is the newest!
        guard let lease2 = connections.leaseConnection(onRequired: el1) else {
            return XCTFail("Expected to get a connection at this point.")
        }
        XCTAssertEqual(lease2, conn5)
        _ = connections.releaseConnection(lease2.id)

        // 4. create another general purpose connection on the correct el
        let connID6 = connections.createNewConnection(on: el1)
        let conn6: HTTPConnectionPool.Connection = .__testOnly_connection(id: connID6, eventLoop: el1)
        _ = connections.newHTTP1ConnectionEstablished(conn6)

        // 5. get el from general pool, since it is the newest!
        guard let lease3 = connections.leaseConnection(onRequired: el1) else {
            return XCTFail("Expected to get a connection at this point.")
        }
        // the last created connection is the shortest amount idle. we should use this
        XCTAssertEqual(lease3, conn6)

        _ = connections.releaseConnection(lease3.id)
    }

    func testCloseConnectionIfIdle() {
        let elg = EmbeddedEventLoopGroup(loops: 1)
        var connections = HTTPConnectionPool.HTTP1Connections(
            maximumConcurrentConnections: 8,
            generator: .init(),
            maximumConnectionUses: nil,
            preWarmedHTTP1ConnectionCount: 0
        )

        let el1 = elg.next()

        // connection is idle
        let conn1ID = connections.createNewConnection(on: el1)
        let conn1: HTTPConnectionPool.Connection = .__testOnly_connection(id: conn1ID, eventLoop: el1)
        _ = connections.newHTTP1ConnectionEstablished(conn1)
        XCTAssertEqual(connections.closeConnectionIfIdle(conn1ID), conn1)

        // connection is not idle
        let conn2ID = connections.createNewConnection(on: el1)
        let conn2: HTTPConnectionPool.Connection = .__testOnly_connection(id: conn2ID, eventLoop: el1)
        let (conn2Index, _) = connections.newHTTP1ConnectionEstablished(conn2)
        XCTAssertEqual(connections.leaseConnection(at: conn2Index), conn2)
        XCTAssertNil(connections.closeConnectionIfIdle(conn2ID))
    }

    func testCloseConnectionIfIdleButLeasedRaceCondition() {
        let elg = EmbeddedEventLoopGroup(loops: 1)
        var connections = HTTPConnectionPool.HTTP1Connections(
            maximumConcurrentConnections: 8,
            generator: .init(),
            maximumConnectionUses: nil,
            preWarmedHTTP1ConnectionCount: 0
        )

        let el1 = elg.next()

        // connection is idle
        let connID = connections.createNewConnection(on: el1)
        let conn: HTTPConnectionPool.Connection = .__testOnly_connection(id: connID, eventLoop: el1)
        _ = connections.newHTTP1ConnectionEstablished(conn)

        // connection is leased
        let lease = connections.leaseConnection(onPreferred: el1)
        XCTAssertEqual(lease, conn)

        // timeout arrives minimal to late
        XCTAssertEqual(connections.closeConnectionIfIdle(connID), nil)
    }

    func testCloseConnectionIfIdleButClosedRaceCondition() {
        let elg = EmbeddedEventLoopGroup(loops: 1)
        var connections = HTTPConnectionPool.HTTP1Connections(
            maximumConcurrentConnections: 8,
            generator: .init(),
            maximumConnectionUses: nil,
            preWarmedHTTP1ConnectionCount: 0
        )

        let el1 = elg.next()

        // connection is idle
        let connID = connections.createNewConnection(on: el1)
        let conn: HTTPConnectionPool.Connection = .__testOnly_connection(id: connID, eventLoop: el1)
        _ = connections.newHTTP1ConnectionEstablished(conn)
        _ = connections.failConnection(connID)

        // timeout arrives minimal to late
        XCTAssertEqual(connections.closeConnectionIfIdle(connID), nil)
    }

    func testShutdown() {
        let elg = EmbeddedEventLoopGroup(loops: 4)
        let el1 = elg.next()
        let el2 = elg.next()
        let el3 = elg.next()
        let el4 = elg.next()

        var connections = HTTPConnectionPool.HTTP1Connections(
            maximumConcurrentConnections: 8,
            generator: .init(),
            maximumConnectionUses: nil,
            preWarmedHTTP1ConnectionCount: 0
        )

        for el in [el1, el2, el3, el4] {
            let connID = connections.createNewConnection(on: el)
            let conn: HTTPConnectionPool.Connection = .__testOnly_connection(id: connID, eventLoop: el)
            let (_, connContext) = connections.newHTTP1ConnectionEstablished(conn)
            XCTAssertEqual(connContext.use, .generalPurpose)
            XCTAssert(connContext.eventLoop === el)
        }

        XCTAssertEqual(connections.stats.backingOff, 0)
        XCTAssertEqual(connections.stats.leased, 0)
        XCTAssertEqual(connections.stats.idle, 4)

        // connection is leased
        guard let lease = connections.leaseConnection(onPreferred: el1) else {
            return XCTFail("Expected to be able to lease a connection")
        }
        XCTAssertEqual(lease, .__testOnly_connection(id: 0, eventLoop: el1))

        XCTAssertEqual(connections.stats.leased, 1)
        XCTAssertEqual(connections.stats.idle, 3)

        // start another connection that fails
        let backingOffID = connections.createNewConnection(on: el1)
        XCTAssert(connections.backoffNextConnectionAttempt(backingOffID) === el1)

        // start another connection
        let startingID = connections.createNewConnection(on: el2)

        let context = connections.shutdown()
        XCTAssertEqual(context.close.count, 3)
        XCTAssertEqual(context.cancel, [lease])
        XCTAssertEqual(context.connectBackoff, [backingOffID])

        XCTAssertEqual(connections.stats.idle, 0)
        XCTAssertEqual(connections.stats.backingOff, 0)
        XCTAssertEqual(connections.stats.leased, 1)
        XCTAssertEqual(connections.stats.connecting, 1)
        XCTAssertFalse(connections.isEmpty)

        let (releaseIndex, _) = connections.releaseConnection(lease.id)
        XCTAssertEqual(connections.closeConnection(at: releaseIndex), lease)
        XCTAssertFalse(connections.isEmpty)

        let backoffEL = connections.backoffNextConnectionAttempt(startingID)
        XCTAssertIdentical(backoffEL, el2)
        guard let (failIndex, _) = connections.failConnection(startingID) else {
            return XCTFail("Expected that the connection is remembered")
        }
        connections.removeConnection(at: failIndex)
        XCTAssertTrue(connections.isEmpty)
    }

    func testMigrationFromHTTP2() {
        let elg = EmbeddedEventLoopGroup(loops: 4)
        let generator = HTTPConnectionPool.Connection.ID.Generator()
        var connections = HTTPConnectionPool.HTTP1Connections(
            maximumConcurrentConnections: 8,
            generator: generator,
            maximumConnectionUses: nil,
            preWarmedHTTP1ConnectionCount: 0
        )

        let el1 = elg.next()
        let el2 = elg.next()

        let conn1ID = generator.next()
        let conn2ID = generator.next()

        connections.migrateFromHTTP2(
            starting: [(conn1ID, el1)],
            backingOff: [(conn2ID, el2)]
        )
        let newConnections = connections.createConnectionsAfterMigrationIfNeeded(
            requiredEventLoopOfPendingRequests: [],
            generalPurposeRequestCountGroupedByPreferredEventLoop: [(el1, 1), (el2, 1)]
        )

        XCTAssertTrue(newConnections.isEmpty)

        let stats = connections.stats
        XCTAssertEqual(stats.idle, 0)
        XCTAssertEqual(stats.leased, 0)
        XCTAssertEqual(stats.connecting, 1)
        XCTAssertEqual(stats.backingOff, 1)
    }

    func testMigrationFromHTTP2WithPendingRequestsWithRequiredEventLoop() {
        let elg = EmbeddedEventLoopGroup(loops: 4)
        let generator = HTTPConnectionPool.Connection.ID.Generator()
        var connections = HTTPConnectionPool.HTTP1Connections(
            maximumConcurrentConnections: 8,
            generator: generator,
            maximumConnectionUses: nil,
            preWarmedHTTP1ConnectionCount: 0
        )

        let el1 = elg.next()
        let el2 = elg.next()
        let el3 = elg.next()

        let conn1ID = generator.next()
        let conn2ID = generator.next()

        connections.migrateFromHTTP2(
            starting: [(conn1ID, el1)],
            backingOff: [(conn2ID, el2)]
        )
        let newConnections = connections.createConnectionsAfterMigrationIfNeeded(
            requiredEventLoopOfPendingRequests: [(el3, 1)],
            generalPurposeRequestCountGroupedByPreferredEventLoop: []
        )
        XCTAssertEqual(newConnections.count, 1)
        XCTAssertEqual(newConnections.first?.1.id, el3.id)

        guard let conn3ID = newConnections.first?.0 else {
            return XCTFail("expected to start a new connection")
        }

        let stats = connections.stats
        XCTAssertEqual(stats.idle, 0)
        XCTAssertEqual(stats.leased, 0)
        XCTAssertEqual(stats.connecting, 2)
        XCTAssertEqual(stats.backingOff, 1)

        let conn3: HTTPConnectionPool.Connection = .__testOnly_connection(id: conn3ID, eventLoop: el3)
        let (_, context) = connections.newHTTP1ConnectionEstablished(conn3)
        XCTAssertEqual(context.use, .eventLoop(el3))
        XCTAssertTrue(context.eventLoop === el3)
    }

    func testMigrationFromHTTP2WithPendingRequestsWithRequiredEventLoopSameAsStartingConnections() {
        let elg = EmbeddedEventLoopGroup(loops: 4)
        let generator = HTTPConnectionPool.Connection.ID.Generator()
        var connections = HTTPConnectionPool.HTTP1Connections(
            maximumConcurrentConnections: 8,
            generator: generator,
            maximumConnectionUses: nil,
            preWarmedHTTP1ConnectionCount: 0
        )

        let el1 = elg.next()
        let el2 = elg.next()

        let conn1ID = generator.next()
        let conn2ID = generator.next()

        connections.migrateFromHTTP2(
            starting: [(conn1ID, el1)],
            backingOff: [(conn2ID, el2)]
        )

        let stats = connections.stats
        XCTAssertEqual(stats.idle, 0)
        XCTAssertEqual(stats.leased, 0)
        XCTAssertEqual(stats.connecting, 1)
        XCTAssertEqual(stats.backingOff, 1)

        let conn1: HTTPConnectionPool.Connection = .__testOnly_connection(id: conn1ID, eventLoop: el1)
        let (_, context) = connections.newHTTP1ConnectionEstablished(conn1)
        XCTAssertEqual(context.use, .generalPurpose)
        XCTAssertTrue(context.eventLoop === el1)
    }

    func testMigrationFromHTTP2WithPendingRequestsWithPreferredEventLoop() {
        let elg = EmbeddedEventLoopGroup(loops: 4)
        let generator = HTTPConnectionPool.Connection.ID.Generator()
        var connections = HTTPConnectionPool.HTTP1Connections(
            maximumConcurrentConnections: 8,
            generator: generator,
            maximumConnectionUses: nil,
            preWarmedHTTP1ConnectionCount: 0
        )

        let el1 = elg.next()
        let el2 = elg.next()
        let el3 = elg.next()

        let conn1ID = generator.next()
        let conn2ID = generator.next()

        connections.migrateFromHTTP2(
            starting: [(conn1ID, el1)],
            backingOff: [(conn2ID, el2)]
        )
        let newConnections = connections.createConnectionsAfterMigrationIfNeeded(
            requiredEventLoopOfPendingRequests: [],
            generalPurposeRequestCountGroupedByPreferredEventLoop: [(el3, 3)]
        )
        XCTAssertEqual(newConnections.count, 1)
        XCTAssertEqual(newConnections.first?.1.id, el3.id)

        guard let conn3ID = newConnections.first?.0 else {
            return XCTFail("expected to start a new connection")
        }

        let stats = connections.stats
        XCTAssertEqual(stats.idle, 0)
        XCTAssertEqual(stats.leased, 0)
        XCTAssertEqual(stats.connecting, 2)
        XCTAssertEqual(stats.backingOff, 1)

        let conn3: HTTPConnectionPool.Connection = .__testOnly_connection(id: conn3ID, eventLoop: el3)
        let (_, context) = connections.newHTTP1ConnectionEstablished(conn3)
        XCTAssertEqual(context.use, .generalPurpose)
        XCTAssertTrue(context.eventLoop === el3)
    }

    func testMigrationFromHTTP2WithAlreadyLeasedHTTP1Connection() {
        let elg = EmbeddedEventLoopGroup(loops: 4)
        let generator = HTTPConnectionPool.Connection.ID.Generator()
        var connections = HTTPConnectionPool.HTTP1Connections(
            maximumConcurrentConnections: 8,
            generator: generator,
            maximumConnectionUses: nil,
            preWarmedHTTP1ConnectionCount: 0
        )
        let el1 = elg.next()
        let el2 = elg.next()
        let el3 = elg.next()

        let conn1ID = connections.createNewConnection(on: el1)
        let conn1: HTTPConnectionPool.Connection = .__testOnly_connection(id: conn1ID, eventLoop: el1)
        let (index, _) = connections.newHTTP1ConnectionEstablished(conn1)
        _ = connections.leaseConnection(at: index)

        let conn2ID = generator.next()
        let conn3ID = generator.next()

        connections.migrateFromHTTP2(
            starting: [(conn2ID, el2)],
            backingOff: [(conn3ID, el3)]
        )
        let newConnections = connections.createConnectionsAfterMigrationIfNeeded(
            requiredEventLoopOfPendingRequests: [],
            generalPurposeRequestCountGroupedByPreferredEventLoop: [(el3, 3)]
        )

        XCTAssertEqual(newConnections.count, 1)
        XCTAssertEqual(newConnections.first?.1.id, el3.id)

        guard let conn4ID = newConnections.first?.0 else {
            return XCTFail("expected to start a new connection")
        }

        let stats = connections.stats
        XCTAssertEqual(stats.idle, 0)
        XCTAssertEqual(stats.leased, 1)
        XCTAssertEqual(stats.connecting, 2)
        XCTAssertEqual(stats.backingOff, 1)

        let conn3: HTTPConnectionPool.Connection = .__testOnly_connection(id: conn4ID, eventLoop: el3)
        let (_, context) = connections.newHTTP1ConnectionEstablished(conn3)
        XCTAssertEqual(context.use, .generalPurpose)
        XCTAssertTrue(context.eventLoop === el3)
    }

    func testMigrationFromHTTP2WithMoreStartingConnectionsThanMaximumAllowedConccurentConnections() {
        let elg = EmbeddedEventLoopGroup(loops: 4)
        let generator = HTTPConnectionPool.Connection.ID.Generator()
        var connections = HTTPConnectionPool.HTTP1Connections(
            maximumConcurrentConnections: 2,
            generator: generator,
            maximumConnectionUses: nil,
            preWarmedHTTP1ConnectionCount: 0
        )

        let el1 = elg.next()
        let el2 = elg.next()
        let el3 = elg.next()

        let conn1ID = generator.next()
        let conn2ID = generator.next()
        let conn3ID = generator.next()

        connections.migrateFromHTTP2(
            starting: [(conn1ID, el1), (conn2ID, el2), (conn3ID, el3)],
            backingOff: []
        )

        // first two connections should be added as general purpose connections
        let conn1: HTTPConnectionPool.Connection = .__testOnly_connection(id: conn1ID, eventLoop: el1)
        let (_, context1) = connections.newHTTP1ConnectionEstablished(conn1)
        XCTAssertEqual(context1.use, .generalPurpose)
        XCTAssertTrue(context1.eventLoop === el1)
        let conn2: HTTPConnectionPool.Connection = .__testOnly_connection(id: conn2ID, eventLoop: el2)
        let (_, context2) = connections.newHTTP1ConnectionEstablished(conn2)
        XCTAssertEqual(context2.use, .generalPurpose)
        XCTAssertTrue(context2.eventLoop === el2)

        // additional connection should be added as overflow connection
        let conn3: HTTPConnectionPool.Connection = .__testOnly_connection(id: conn3ID, eventLoop: el3)
        let (_, context3) = connections.newHTTP1ConnectionEstablished(conn3)
        XCTAssertEqual(context3.use, .eventLoop(el3))
        XCTAssertTrue(context3.eventLoop === el3)
    }

    func testMigrationFromHTTP2StartsEnoghOverflowConnectionsForRequiredEventLoopRequests() {
        let elg = EmbeddedEventLoopGroup(loops: 4)
        let generator = HTTPConnectionPool.Connection.ID.Generator()
        var connections = HTTPConnectionPool.HTTP1Connections(
            maximumConcurrentConnections: 1,
            generator: generator,
            maximumConnectionUses: nil,
            preWarmedHTTP1ConnectionCount: 0
        )

        let el1 = elg.next()
        let el2 = elg.next()
        let el3 = elg.next()
        let el4 = elg.next()

        let conn1ID = generator.next()
        let conn2ID = generator.next()
        let conn3ID = generator.next()

        connections.migrateFromHTTP2(
            starting: [(conn1ID, el1), (conn2ID, el2), (conn3ID, el3)],
            backingOff: []
        )

        let connectionsToCreate = connections.createConnectionsAfterMigrationIfNeeded(
            requiredEventLoopOfPendingRequests: [(el2, 2), (el3, 1), (el4, 2)],
            generalPurposeRequestCountGroupedByPreferredEventLoop: []
        )

        XCTAssertEqual(
            connectionsToCreate.map { $0.1.id },
            [el2.id, el4.id, el4.id],
            "should create one connection for el2 and two for el4"
        )

        for (connID, el) in connectionsToCreate {
            let conn: HTTPConnectionPool.Connection = .__testOnly_connection(id: connID, eventLoop: el)
            let (_, context) = connections.newHTTP1ConnectionEstablished(conn)
            XCTAssertEqual(context.use, .eventLoop(el))
            XCTAssertTrue(context.eventLoop === el)
        }
    }

    func testMigrationFromHTTP1ToHTTP2AndBackToHTTP1() throws {
        let elg = EmbeddedEventLoopGroup(loops: 2)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }
        let el1 = elg.next()
        let el2 = elg.next()

        let generator = HTTPConnectionPool.Connection.ID.Generator()
        var connections = HTTPConnectionPool.HTTP1Connections(
            maximumConcurrentConnections: 8,
            generator: generator,
            maximumConnectionUses: nil,
            preWarmedHTTP1ConnectionCount: 0
        )

        let connID1 = connections.createNewConnection(on: el1)

        let context = connections.migrateToHTTP2()
        XCTAssertEqual(
            context,
            .init(
                backingOff: [],
                starting: [(connID1, el1)],
                close: []
            )
        )

        let connID2 = generator.next()

        connections.migrateFromHTTP2(
            starting: [(connID2, el2)],
            backingOff: []
        )

        let conn2: HTTPConnectionPool.Connection = .__testOnly_connection(id: connID2, eventLoop: el2)
        let (_, idleContext) = connections.newHTTP1ConnectionEstablished(conn2)
        XCTAssertEqual(idleContext.use, .generalPurpose)
        XCTAssertEqual(idleContext.eventLoop.id, el2.id)
    }
}

extension HTTPConnectionPool.HTTP1Connections.HTTP1ToHTTP2MigrationContext: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.close == rhs.close && lhs.starting.elementsEqual(rhs.starting, by: { $0.0 == $1.0 && $0.1 === $1.1 })
            && lhs.backingOff.elementsEqual(rhs.backingOff, by: { $0.0 == $1.0 && $0.1 === $1.1 })
    }
}
