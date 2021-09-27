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
import NIOCore
import NIOEmbedded
import XCTest

class HTTPConnectionPool_HTTP2ConnectionsTests: XCTestCase {
    func testCreatingConnections() {
        let elg = EmbeddedEventLoopGroup(loops: 4)
        var connections = HTTPConnectionPool.HTTP2Connections(generator: .init())

        let el1 = elg.next()
        let el2 = elg.next()

        // general purpose connection
        XCTAssertFalse(connections.hasConnectionThatCanOrWillBeAbleToExecuteRequests)
        XCTAssertFalse(connections.hasConnectionThatCanOrWillBeAbleToExecuteRequests(for: el1))
        let conn1ID = connections.createNewConnection(on: el1)
        XCTAssertTrue(connections.hasConnectionThatCanOrWillBeAbleToExecuteRequests)
        XCTAssertTrue(connections.hasConnectionThatCanOrWillBeAbleToExecuteRequests(for: el1))
        let conn1: HTTPConnectionPool.Connection = .__testOnly_connection(id: conn1ID, eventLoop: el1)
        let (conn1Index, conn1CreatedContext) = connections.newHTTP2ConnectionEstablished(conn1, maxConcurrentStreams: 100)
        XCTAssertEqual(conn1CreatedContext.availableStreams, 100)
        XCTAssertEqual(conn1CreatedContext.isIdle, true)
        XCTAssert(conn1CreatedContext.eventLoop === el1)
        XCTAssertEqual(connections.leaseStreams(at: conn1Index, count: 1), conn1)

        // eventLoop connection
        XCTAssertTrue(connections.hasConnectionThatCanOrWillBeAbleToExecuteRequests)
        XCTAssertFalse(connections.hasConnectionThatCanOrWillBeAbleToExecuteRequests(for: el2))
        let conn2ID = connections.createNewConnection(on: el2)
        XCTAssertTrue(connections.hasConnectionThatCanOrWillBeAbleToExecuteRequests(for: el2))
        let conn2: HTTPConnectionPool.Connection = .__testOnly_connection(id: conn2ID, eventLoop: el2)
        let (conn2Index, conn2CreatedContext) = connections.newHTTP2ConnectionEstablished(conn2, maxConcurrentStreams: 100)
        XCTAssertEqual(conn1CreatedContext.availableStreams, 100)
        XCTAssertTrue(conn1CreatedContext.isIdle)
        XCTAssert(conn2CreatedContext.eventLoop === el2)
        XCTAssertEqual(connections.leaseStreams(at: conn2Index, count: 1), conn2)
        XCTAssertTrue(connections.hasConnectionThatCanOrWillBeAbleToExecuteRequests(for: el2))
    }

    func testCreatingConnectionAndFailing() {
        let elg = EmbeddedEventLoopGroup(loops: 4)
        var connections = HTTPConnectionPool.HTTP2Connections(generator: .init())

        let el1 = elg.next()
        let el2 = elg.next()

        // general purpose connection
        XCTAssertFalse(connections.hasConnectionThatCanOrWillBeAbleToExecuteRequests)
        XCTAssertFalse(connections.hasConnectionThatCanOrWillBeAbleToExecuteRequests(for: el1))
        let conn1ID = connections.createNewConnection(on: el1)
        XCTAssertEqual(conn1ID, 0)
        XCTAssertTrue(connections.hasConnectionThatCanOrWillBeAbleToExecuteRequests)
        XCTAssertTrue(connections.hasConnectionThatCanOrWillBeAbleToExecuteRequests(for: el1))

        // connection failed to start. 1. backoff
        let backoff1EL = connections.backoffNextConnectionAttempt(conn1ID)
        XCTAssert(backoff1EL === el1)
        // backoff done. 2. decide what's next
        guard let (conn1FailIndex, conn1FailContext) = connections.failConnection(conn1ID) else {
            return XCTFail("Expected that the connection is remembered")
        }

        XCTAssert(conn1FailContext.eventLoop === el1)
        XCTAssertFalse(connections.hasConnectionThatCanOrWillBeAbleToExecuteRequests)
        XCTAssertFalse(connections.hasConnectionThatCanOrWillBeAbleToExecuteRequests(for: el1))
        let (replaceConn1ID, replaceConn1EL) = connections.createNewConnectionByReplacingClosedConnection(at: conn1FailIndex)
        XCTAssert(replaceConn1EL === el1)
        XCTAssertEqual(replaceConn1ID, 1)
        XCTAssertTrue(connections.hasConnectionThatCanOrWillBeAbleToExecuteRequests)
        XCTAssertTrue(connections.hasConnectionThatCanOrWillBeAbleToExecuteRequests(for: el1))

        // eventLoop connection
        let conn2ID = connections.createNewConnection(on: el2)
        XCTAssertTrue(connections.hasConnectionThatCanOrWillBeAbleToExecuteRequests)
        XCTAssertTrue(connections.hasConnectionThatCanOrWillBeAbleToExecuteRequests(for: el2))
        let backoff2EL = connections.backoffNextConnectionAttempt(conn2ID)
        XCTAssert(backoff2EL === el2)
        guard let (conn2FailIndex, conn2FailContext) = connections.failConnection(conn2ID) else {
            return XCTFail("Expected that the connection is remembered")
        }
        XCTAssert(conn2FailContext.eventLoop === el2)
        connections.removeConnection(at: conn2FailIndex)
        XCTAssertFalse(connections.hasConnectionThatCanOrWillBeAbleToExecuteRequests(for: el2))
    }

    func testFailConnectionRace() {
        let elg = EmbeddedEventLoopGroup(loops: 5)

        let el1 = elg.next()

        var connections = HTTPConnectionPool.HTTP2Connections(generator: .init())

        // connection is idle
        let conn1ID = connections.createNewConnection(on: el1)
        let conn1: HTTPConnectionPool.Connection = .__testOnly_connection(id: conn1ID, eventLoop: el1)
        _ = connections.newHTTP2ConnectionEstablished(conn1, maxConcurrentStreams: 100)

        // connection close is initiated from the pool
        XCTAssertEqual(connections.closeConnectionIfIdle(conn1ID), conn1)

        // connection will report close event to us even if we have initialled it an we need to tolerate it
        XCTAssertNil(connections.failConnection(conn1ID))
    }

    func testLeaseConnectionOfPreferredButUnavailableEL() {
        let elg = EmbeddedEventLoopGroup(loops: 5)
        let el1 = elg.next()
        let el2 = elg.next()
        let el3 = elg.next()
        let el4 = elg.next()
        let el5 = elg.next()

        var connections = HTTPConnectionPool.HTTP2Connections(generator: .init())
        XCTAssertFalse(connections.hasConnectionThatCanOrWillBeAbleToExecuteRequests)
        for el in [el1, el2, el3, el4] {
            XCTAssertFalse(connections.hasConnectionThatCanOrWillBeAbleToExecuteRequests(for: el))
            let connID = connections.createNewConnection(on: el)
            XCTAssertTrue(connections.hasConnectionThatCanOrWillBeAbleToExecuteRequests)
            XCTAssertTrue(connections.hasConnectionThatCanOrWillBeAbleToExecuteRequests(for: el))
            let conn: HTTPConnectionPool.Connection = .__testOnly_connection(id: connID, eventLoop: el)
            let (_, conn1CreatedContext) = connections.newHTTP2ConnectionEstablished(conn, maxConcurrentStreams: 100)
            XCTAssertEqual(conn1CreatedContext.availableStreams, 100)
            XCTAssertEqual(conn1CreatedContext.isIdle, true)
            XCTAssert(conn1CreatedContext.eventLoop === el)
        }

        XCTAssertNotNil(connections.leaseStream(onPreferred: el5))
    }

    func testLeaseConnectionOnRequiredButUnavailableEL() {
        let elg = EmbeddedEventLoopGroup(loops: 5)
        let el1 = elg.next()
        let el2 = elg.next()
        let el3 = elg.next()
        let el4 = elg.next()
        let el5 = elg.next()

        var connections = HTTPConnectionPool.HTTP2Connections(generator: .init())
        XCTAssertFalse(connections.hasConnectionThatCanOrWillBeAbleToExecuteRequests)
        for el in [el1, el2, el3, el4] {
            XCTAssertFalse(connections.hasConnectionThatCanOrWillBeAbleToExecuteRequests(for: el))
            let connID = connections.createNewConnection(on: el)
            XCTAssertTrue(connections.hasConnectionThatCanOrWillBeAbleToExecuteRequests)
            XCTAssertTrue(connections.hasConnectionThatCanOrWillBeAbleToExecuteRequests(for: el))
            let conn: HTTPConnectionPool.Connection = .__testOnly_connection(id: connID, eventLoop: el)
            let (_, conn1CreatedContext) = connections.newHTTP2ConnectionEstablished(conn, maxConcurrentStreams: 100)
            XCTAssertEqual(conn1CreatedContext.availableStreams, 100)
            XCTAssertEqual(conn1CreatedContext.isIdle, true)
            XCTAssert(conn1CreatedContext.eventLoop === el)
        }

        XCTAssertNil(connections.leaseStreams(onRequired: el5))
    }

    func testCloseConnectionIfIdle() {
        let elg = EmbeddedEventLoopGroup(loops: 5)

        let el1 = elg.next()

        var connections = HTTPConnectionPool.HTTP2Connections(generator: .init())

        // connection is idle
        let conn1ID = connections.createNewConnection(on: el1)
        let conn1: HTTPConnectionPool.Connection = .__testOnly_connection(id: conn1ID, eventLoop: el1)
        _ = connections.newHTTP2ConnectionEstablished(conn1, maxConcurrentStreams: 100)
        XCTAssertEqual(connections.closeConnectionIfIdle(conn1ID), conn1)

        // connection is not idle
        let conn2ID = connections.createNewConnection(on: el1)
        let conn2: HTTPConnectionPool.Connection = .__testOnly_connection(id: conn2ID, eventLoop: el1)
        let (conn2Index, _) = connections.newHTTP2ConnectionEstablished(conn2, maxConcurrentStreams: 100)
        XCTAssertEqual(connections.leaseStreams(at: conn2Index, count: 1), conn2)
        XCTAssertNil(connections.closeConnectionIfIdle(conn2ID))
    }

    func testCloseConnectionIfIdleButLeasedRaceCondition() {
        let elg = EmbeddedEventLoopGroup(loops: 5)

        let el1 = elg.next()

        var connections = HTTPConnectionPool.HTTP2Connections(generator: .init())

        // connection is idle
        let conn1ID = connections.createNewConnection(on: el1)
        let conn1: HTTPConnectionPool.Connection = .__testOnly_connection(id: conn1ID, eventLoop: el1)
        _ = connections.newHTTP2ConnectionEstablished(conn1, maxConcurrentStreams: 100)

        // connection is leased
        let lease = connections.leaseStream(onPreferred: el1)
        XCTAssertEqual(lease, conn1)

        // timeout arrives minimal to late
        XCTAssertEqual(connections.closeConnectionIfIdle(conn1ID), nil)
    }

    func testCloseConnectionIfIdleButClosedRaceCondition() {
        let elg = EmbeddedEventLoopGroup(loops: 5)

        let el1 = elg.next()

        var connections = HTTPConnectionPool.HTTP2Connections(generator: .init())

        // connection is idle
        let conn1ID = connections.createNewConnection(on: el1)
        let conn1: HTTPConnectionPool.Connection = .__testOnly_connection(id: conn1ID, eventLoop: el1)
        _ = connections.newHTTP2ConnectionEstablished(conn1, maxConcurrentStreams: 100)
        _ = connections.failConnection(conn1ID)

        // timeout arrives minimal to late
        XCTAssertEqual(connections.closeConnectionIfIdle(conn1ID), nil)
    }

    func testCloseConnectionIfIdleRace() {
        let elg = EmbeddedEventLoopGroup(loops: 5)

        let el1 = elg.next()

        var connections = HTTPConnectionPool.HTTP2Connections(generator: .init())

        // connection is idle
        let conn1ID = connections.createNewConnection(on: el1)
        let conn1: HTTPConnectionPool.Connection = .__testOnly_connection(id: conn1ID, eventLoop: el1)
        _ = connections.newHTTP2ConnectionEstablished(conn1, maxConcurrentStreams: 100)

        // we lease it just before timeout
        XCTAssertEqual(connections.leaseStreams(onRequired: el1), conn1)

        // timeout arrives minimal to late
        XCTAssertEqual(connections.closeConnectionIfIdle(conn1ID), nil)
    }

    func testShutdown() {
        let elg = EmbeddedEventLoopGroup(loops: 6)
        let el1 = elg.next()
        let el2 = elg.next()
        let el3 = elg.next()
        let el4 = elg.next()
        let el5 = elg.next()
        let el6 = elg.next()

        var connections = HTTPConnectionPool.HTTP2Connections(generator: .init())
        XCTAssertFalse(connections.hasConnectionThatCanOrWillBeAbleToExecuteRequests)
        for el in [el1, el2, el3, el4] {
            XCTAssertFalse(connections.hasConnectionThatCanOrWillBeAbleToExecuteRequests(for: el))
            let connID = connections.createNewConnection(on: el)
            XCTAssertTrue(connections.hasConnectionThatCanOrWillBeAbleToExecuteRequests)
            XCTAssertTrue(connections.hasConnectionThatCanOrWillBeAbleToExecuteRequests(for: el))
            let conn: HTTPConnectionPool.Connection = .__testOnly_connection(id: connID, eventLoop: el)
            let (_, conn1CreatedContext) = connections.newHTTP2ConnectionEstablished(conn, maxConcurrentStreams: 100)
            XCTAssertEqual(conn1CreatedContext.availableStreams, 100)
            XCTAssertEqual(conn1CreatedContext.isIdle, true)
            XCTAssert(conn1CreatedContext.eventLoop === el)
        }

        XCTAssertEqual(connections.stats.backingOffConnections, 0)
        XCTAssertEqual(connections.stats.leasedStreams, 0)
        XCTAssertEqual(connections.stats.availableStreams, 400)
        XCTAssertEqual(connections.stats.idleConnections, 4)

        // connection is leased
        guard let lease = connections.leaseStream(onPreferred: el1) else {
            return XCTFail("Expected to be able to lease a connection")
        }
        XCTAssertEqual(lease, .__testOnly_connection(id: 0, eventLoop: el1))

        XCTAssertEqual(connections.stats.backingOffConnections, 0)
        XCTAssertEqual(connections.stats.leasedStreams, 1)
        XCTAssertEqual(connections.stats.availableStreams, 399)
        XCTAssertEqual(connections.stats.idleConnections, 3)

        // start another connection that fails
        let backingOffID = connections.createNewConnection(on: el5)
        XCTAssert(connections.backoffNextConnectionAttempt(backingOffID) === el5)

        // start another connection
        let startingID = connections.createNewConnection(on: el6)

        let context = connections.shutdown()
        XCTAssertEqual(context.close.count, 3)
        XCTAssertEqual(context.cancel, [lease])
        XCTAssertEqual(context.connectBackoff, [backingOffID])

        XCTAssertEqual(connections.stats.idleConnections, 0)
        XCTAssertEqual(connections.stats.backingOffConnections, 0)
        XCTAssertEqual(connections.stats.leasedStreams, 1)
        XCTAssertEqual(connections.stats.availableStreams, 99)
        XCTAssertEqual(connections.stats.startingConnections, 1)
        XCTAssertFalse(connections.isEmpty)

        let (releaseIndex, _) = connections.releaseStream(lease.id)
        XCTAssertEqual(connections.closeConnection(at: releaseIndex), lease)
        XCTAssertFalse(connections.isEmpty)

        guard let (failIndex, _) = connections.failConnection(startingID) else {
            return XCTFail("Expected that the connection is remembered")
        }
        connections.removeConnection(at: failIndex)
        XCTAssertTrue(connections.isEmpty)
    }

    func testLeasingAllConnections() {
        let elg = EmbeddedEventLoopGroup(loops: 4)
        var connections = HTTPConnectionPool.HTTP2Connections(generator: .init())
        let el1 = elg.next()

        let conn1ID = connections.createNewConnection(on: el1)
        let conn1: HTTPConnectionPool.Connection = .__testOnly_connection(id: conn1ID, eventLoop: el1)
        let (conn1Index, conn1CreatedContext) = connections.newHTTP2ConnectionEstablished(conn1, maxConcurrentStreams: 100)
        XCTAssertEqual(conn1CreatedContext.availableStreams, 100)
        XCTAssertEqual(connections.leaseStreams(at: conn1Index, count: 100), conn1)

        XCTAssertNil(connections.leaseStreams(onRequired: el1), "should not be able to lease stream because they are all already leased")

        let (_, releaseContext) = connections.releaseStream(conn1ID)
        XCTAssertFalse(releaseContext.isIdle)
        XCTAssertEqual(releaseContext.availableStreams, 1)

        XCTAssertEqual(connections.leaseStreams(onRequired: el1), conn1)
        XCTAssertNil(connections.leaseStreams(onRequired: el1), "should not be able to lease stream because they are all already leased")
    }

    func testGoAway() {
        let elg = EmbeddedEventLoopGroup(loops: 4)
        var connections = HTTPConnectionPool.HTTP2Connections(generator: .init())
        let el1 = elg.next()

        let conn1ID = connections.createNewConnection(on: el1)
        let conn1: HTTPConnectionPool.Connection = .__testOnly_connection(id: conn1ID, eventLoop: el1)
        let (conn1Index, conn1CreatedContext) = connections.newHTTP2ConnectionEstablished(conn1, maxConcurrentStreams: 10)
        XCTAssertEqual(conn1CreatedContext.availableStreams, 10)
        XCTAssertEqual(connections.leaseStreams(at: conn1Index, count: 2), conn1)

        XCTAssertTrue(connections.goAwayReceived(conn1ID).eventLoop === el1)

        XCTAssertEqual(
            connections.stats,
            .init(
                startingConnections: 0,
                backingOffConnections: 0,
                idleConnections: 0,
                availableConnections: 0,
                drainingConnections: 1,
                leasedStreams: 2,
                availableStreams: 0
            )
        )

        XCTAssertNil(connections.leaseStreams(onRequired: el1), "we should not be able to lease a stream because the connection is draining")

        // a server can potentially send more than one connection go away and we should not crash
        XCTAssertTrue(connections.goAwayReceived(conn1ID).eventLoop === el1)
        XCTAssertEqual(
            connections.stats,
            .init(
                startingConnections: 0,
                backingOffConnections: 0,
                idleConnections: 0,
                availableConnections: 0,
                drainingConnections: 1,
                leasedStreams: 2,
                availableStreams: 0
            )
        )

        // release a connection
        let (_, release1Context) = connections.releaseStream(conn1ID)
        XCTAssertFalse(release1Context.isIdle)
        XCTAssertEqual(release1Context.availableStreams, 0)
        XCTAssertEqual(
            connections.stats,
            .init(
                startingConnections: 0,
                backingOffConnections: 0,
                idleConnections: 0,
                availableConnections: 0,
                drainingConnections: 1,
                leasedStreams: 1,
                availableStreams: 0
            )
        )

        // release last connection
        let (_, release2Context) = connections.releaseStream(conn1ID)
        XCTAssertFalse(release2Context.isIdle)
        XCTAssertEqual(release2Context.availableStreams, 0)
        XCTAssertEqual(
            connections.stats,
            .init(
                startingConnections: 0,
                backingOffConnections: 0,
                idleConnections: 0,
                availableConnections: 0,
                drainingConnections: 1,
                leasedStreams: 0,
                availableStreams: 0
            )
        )
    }

    func testNewMaxConcurrentStreamsSetting() {
        let elg = EmbeddedEventLoopGroup(loops: 4)
        var connections = HTTPConnectionPool.HTTP2Connections(generator: .init())
        let el1 = elg.next()

        let conn1ID = connections.createNewConnection(on: el1)
        let conn1: HTTPConnectionPool.Connection = .__testOnly_connection(id: conn1ID, eventLoop: el1)
        let (conn1Index, conn1CreatedContext) = connections.newHTTP2ConnectionEstablished(conn1, maxConcurrentStreams: 1)
        XCTAssertEqual(conn1CreatedContext.availableStreams, 1)
        XCTAssertEqual(connections.leaseStreams(at: conn1Index, count: 1), conn1)

        XCTAssertNil(connections.leaseStreams(onRequired: el1), "all streams are in use")

        let (_, newSettingsContext1) = connections.newHTTP2MaxConcurrentStreamsReceived(conn1ID, newMaxStreams: 2)
        XCTAssertEqual(newSettingsContext1.availableStreams, 1)
        XCTAssertTrue(newSettingsContext1.eventLoop === el1)
        XCTAssertFalse(newSettingsContext1.isIdle)

        XCTAssertEqual(connections.leaseStreams(onRequired: el1), conn1)

        let (_, newSettingsContext2) = connections.newHTTP2MaxConcurrentStreamsReceived(conn1ID, newMaxStreams: 1)
        XCTAssertEqual(newSettingsContext2.availableStreams, 0)
        XCTAssertTrue(newSettingsContext2.eventLoop === el1)
        XCTAssertFalse(newSettingsContext2.isIdle)

        // release a connection
        let (_, release1Context) = connections.releaseStream(conn1ID)
        XCTAssertFalse(release1Context.isIdle)
        XCTAssertEqual(release1Context.availableStreams, 0)

        XCTAssertNil(connections.leaseStreams(onRequired: el1), "all streams are in use")

        // release a connection
        let (_, release2Context) = connections.releaseStream(conn1ID)
        XCTAssertTrue(release2Context.isIdle)
        XCTAssertEqual(release2Context.availableStreams, 1)

        XCTAssertEqual(connections.leaseStreams(onRequired: el1), conn1)
    }

    func testLeaseOnPreferredEventLoopWithoutAnyAvailable() {
        let elg = EmbeddedEventLoopGroup(loops: 4)
        var connections = HTTPConnectionPool.HTTP2Connections(generator: .init())
        let el1 = elg.next()

        let conn1ID = connections.createNewConnection(on: el1)
        let conn1: HTTPConnectionPool.Connection = .__testOnly_connection(id: conn1ID, eventLoop: el1)
        let (conn1Index, conn1CreatedContext) = connections.newHTTP2ConnectionEstablished(conn1, maxConcurrentStreams: 1)
        XCTAssertEqual(conn1CreatedContext.availableStreams, 1)
        XCTAssertEqual(connections.leaseStreams(at: conn1Index, count: 1), conn1)

        XCTAssertNil(connections.leaseStream(onPreferred: el1), "all streams are in use")
    }

    func testMigrationFromHTTP1() {
        let elg = EmbeddedEventLoopGroup(loops: 4)
        var connections = HTTPConnectionPool.HTTP2Connections(generator: .init())
        let el1 = elg.next()
        let el2 = elg.next()
        let conn1ID: HTTPConnectionPool.Connection.ID = 1
        let conn2ID: HTTPConnectionPool.Connection.ID = 2

        connections.migrateConnections(
            starting: [(conn1ID, el1)],
            backingOff: [(conn2ID, el2)]
        )
        XCTAssertEqual(
            connections.stats,
            .init(
                startingConnections: 1,
                backingOffConnections: 1,
                idleConnections: 0,
                availableConnections: 0,
                drainingConnections: 0,
                leasedStreams: 0,
                availableStreams: 0
            )
        )

        let conn1: HTTPConnectionPool.Connection = .__testOnly_connection(id: conn1ID, eventLoop: el1)
        let (conn1Index, conn1CreatedContext) = connections.newHTTP2ConnectionEstablished(conn1, maxConcurrentStreams: 100)
        XCTAssertEqual(conn1CreatedContext.availableStreams, 100)
        XCTAssertEqual(connections.leaseStreams(at: conn1Index, count: 2), conn1)
        XCTAssertEqual(
            connections.stats,
            .init(
                startingConnections: 0,
                backingOffConnections: 1,
                idleConnections: 0,
                availableConnections: 1,
                drainingConnections: 0,
                leasedStreams: 2,
                availableStreams: 98
            )
        )
    }
}
