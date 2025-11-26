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

class HTTPConnectionPool_HTTP2ConnectionsTests: XCTestCase {
    func testCreatingConnections() {
        let elg = EmbeddedEventLoopGroup(loops: 4)
        var connections = HTTPConnectionPool.HTTP2Connections(generator: .init(), maximumConnectionUses: nil)

        let el1 = elg.next()
        let el2 = elg.next()

        // general purpose connection
        XCTAssertFalse(connections.hasConnectionThatCanOrWillBeAbleToExecuteRequests)
        XCTAssertFalse(connections.hasConnectionThatCanOrWillBeAbleToExecuteRequests(for: el1))
        let conn1ID = connections.createNewConnection(on: el1)
        XCTAssertTrue(connections.hasConnectionThatCanOrWillBeAbleToExecuteRequests)
        XCTAssertTrue(connections.hasConnectionThatCanOrWillBeAbleToExecuteRequests(for: el1))
        let conn1: HTTPConnectionPool.Connection = .__testOnly_connection(id: conn1ID, eventLoop: el1)
        let (conn1Index, conn1CreatedContext) = connections.newHTTP2ConnectionEstablished(
            conn1,
            maxConcurrentStreams: 100
        )
        XCTAssertEqual(conn1CreatedContext.availableStreams, 100)
        XCTAssertEqual(conn1CreatedContext.isIdle, true)
        XCTAssert(conn1CreatedContext.eventLoop === el1)
        let (leasedConn1, leasdConnContext1) = connections.leaseStreams(at: conn1Index, count: 1)
        XCTAssertEqual(leasedConn1, conn1)
        XCTAssertEqual(leasdConnContext1.wasIdle, true)

        // eventLoop connection
        XCTAssertTrue(connections.hasConnectionThatCanOrWillBeAbleToExecuteRequests)
        XCTAssertFalse(connections.hasConnectionThatCanOrWillBeAbleToExecuteRequests(for: el2))
        let conn2ID = connections.createNewConnection(on: el2)
        XCTAssertTrue(connections.hasConnectionThatCanOrWillBeAbleToExecuteRequests(for: el2))
        let conn2: HTTPConnectionPool.Connection = .__testOnly_connection(id: conn2ID, eventLoop: el2)
        let (conn2Index, conn2CreatedContext) = connections.newHTTP2ConnectionEstablished(
            conn2,
            maxConcurrentStreams: 100
        )
        XCTAssertEqual(conn1CreatedContext.availableStreams, 100)
        XCTAssertTrue(conn1CreatedContext.isIdle)
        XCTAssert(conn2CreatedContext.eventLoop === el2)

        let (leasedConn2, leasdConnContext2) = connections.leaseStreams(at: conn2Index, count: 1)
        XCTAssertEqual(leasedConn2, conn2)
        XCTAssertEqual(leasdConnContext2.wasIdle, true)
        XCTAssertTrue(connections.hasConnectionThatCanOrWillBeAbleToExecuteRequests(for: el2))
    }

    func testCreatingConnectionAndFailing() {
        let elg = EmbeddedEventLoopGroup(loops: 4)
        var connections = HTTPConnectionPool.HTTP2Connections(generator: .init(), maximumConnectionUses: nil)

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
        let (replaceConn1ID, replaceConn1EL) = connections.createNewConnectionByReplacingClosedConnection(
            at: conn1FailIndex
        )
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

        var connections = HTTPConnectionPool.HTTP2Connections(generator: .init(), maximumConnectionUses: nil)

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

        var connections = HTTPConnectionPool.HTTP2Connections(generator: .init(), maximumConnectionUses: nil)
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

        var connections = HTTPConnectionPool.HTTP2Connections(generator: .init(), maximumConnectionUses: nil)
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

        XCTAssertNil(connections.leaseStream(onRequired: el5))
    }

    func testCloseConnectionIfIdle() {
        let elg = EmbeddedEventLoopGroup(loops: 5)

        let el1 = elg.next()

        var connections = HTTPConnectionPool.HTTP2Connections(generator: .init(), maximumConnectionUses: nil)

        // connection is idle
        let conn1ID = connections.createNewConnection(on: el1)
        let conn1: HTTPConnectionPool.Connection = .__testOnly_connection(id: conn1ID, eventLoop: el1)
        _ = connections.newHTTP2ConnectionEstablished(conn1, maxConcurrentStreams: 100)
        XCTAssertEqual(connections.closeConnectionIfIdle(conn1ID), conn1)

        // connection is not idle
        let conn2ID = connections.createNewConnection(on: el1)
        let conn2: HTTPConnectionPool.Connection = .__testOnly_connection(id: conn2ID, eventLoop: el1)
        let (conn2Index, _) = connections.newHTTP2ConnectionEstablished(conn2, maxConcurrentStreams: 100)

        let (leasedConn1, leasdConnContext1) = connections.leaseStreams(at: conn2Index, count: 1)
        XCTAssertEqual(leasedConn1, conn2)
        XCTAssertEqual(leasdConnContext1.wasIdle, true)
        XCTAssertNil(connections.closeConnectionIfIdle(conn2ID))
    }

    func testCloseConnectionIfIdleButLeasedRaceCondition() {
        let elg = EmbeddedEventLoopGroup(loops: 5)

        let el1 = elg.next()

        var connections = HTTPConnectionPool.HTTP2Connections(generator: .init(), maximumConnectionUses: nil)

        // connection is idle
        let conn1ID = connections.createNewConnection(on: el1)
        let conn1: HTTPConnectionPool.Connection = .__testOnly_connection(id: conn1ID, eventLoop: el1)
        _ = connections.newHTTP2ConnectionEstablished(conn1, maxConcurrentStreams: 100)

        // connection is leased
        guard let (leasedConn, leaseContext) = connections.leaseStream(onPreferred: el1) else {
            return XCTFail("lease unexpectedly failed")
        }
        XCTAssertEqual(leasedConn, conn1)
        XCTAssertEqual(leaseContext.wasIdle, true)

        // timeout arrives minimal to late
        XCTAssertEqual(connections.closeConnectionIfIdle(conn1ID), nil)
    }

    func testCloseConnectionIfIdleButClosedRaceCondition() {
        let elg = EmbeddedEventLoopGroup(loops: 5)

        let el1 = elg.next()

        var connections = HTTPConnectionPool.HTTP2Connections(generator: .init(), maximumConnectionUses: nil)

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

        var connections = HTTPConnectionPool.HTTP2Connections(generator: .init(), maximumConnectionUses: nil)

        // connection is idle
        let conn1ID = connections.createNewConnection(on: el1)
        let conn1: HTTPConnectionPool.Connection = .__testOnly_connection(id: conn1ID, eventLoop: el1)
        _ = connections.newHTTP2ConnectionEstablished(conn1, maxConcurrentStreams: 100)

        // we lease it just before timeout
        guard let (leasedConn, leaseContext) = connections.leaseStream(onRequired: el1) else {
            return XCTFail("lease unexpectedly failed")
        }
        XCTAssertEqual(leasedConn, conn1)
        XCTAssertEqual(leaseContext.wasIdle, true)

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

        var connections = HTTPConnectionPool.HTTP2Connections(generator: .init(), maximumConnectionUses: nil)
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
        guard let (leasedConn, leaseContext) = connections.leaseStream(onPreferred: el1) else {
            return XCTFail("Expected to be able to lease a connection")
        }
        XCTAssertEqual(leasedConn, .__testOnly_connection(id: 0, eventLoop: el1))
        XCTAssertEqual(leaseContext.wasIdle, true)

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
        XCTAssertEqual(context.cancel, [leasedConn])
        XCTAssertEqual(context.connectBackoff, [backingOffID])

        XCTAssertEqual(connections.stats.idleConnections, 0)
        XCTAssertEqual(connections.stats.backingOffConnections, 0)
        XCTAssertEqual(connections.stats.leasedStreams, 1)
        XCTAssertEqual(connections.stats.availableStreams, 99)
        XCTAssertEqual(connections.stats.startingConnections, 1)
        XCTAssertFalse(connections.isEmpty)

        let (releaseIndex, _) = connections.releaseStream(leasedConn.id)
        XCTAssertEqual(connections.closeConnection(at: releaseIndex), leasedConn)
        XCTAssertFalse(connections.isEmpty)

        let backoffEL = connections.backoffNextConnectionAttempt(startingID)
        XCTAssertIdentical(el6, backoffEL)
        guard let (failIndex, _) = connections.failConnection(startingID) else {
            return XCTFail("Expected that the connection is remembered")
        }
        connections.removeConnection(at: failIndex)
        XCTAssertTrue(connections.isEmpty)
    }

    func testLeasingAllConnections() {
        let elg = EmbeddedEventLoopGroup(loops: 4)
        var connections = HTTPConnectionPool.HTTP2Connections(generator: .init(), maximumConnectionUses: nil)
        let el1 = elg.next()

        let conn1ID = connections.createNewConnection(on: el1)
        let conn1: HTTPConnectionPool.Connection = .__testOnly_connection(id: conn1ID, eventLoop: el1)
        let (conn1Index, conn1CreatedContext) = connections.newHTTP2ConnectionEstablished(
            conn1,
            maxConcurrentStreams: 100
        )
        XCTAssertEqual(conn1CreatedContext.availableStreams, 100)
        let (leasedConn1, leasdConnContext1) = connections.leaseStreams(at: conn1Index, count: 100)
        XCTAssertEqual(leasedConn1, conn1)
        XCTAssertEqual(leasdConnContext1.wasIdle, true)

        XCTAssertNil(
            connections.leaseStream(onRequired: el1),
            "should not be able to lease stream because they are all already leased"
        )

        let (_, releaseContext) = connections.releaseStream(conn1ID)
        XCTAssertFalse(releaseContext.isIdle)
        XCTAssertEqual(releaseContext.availableStreams, 1)

        guard let (leasedConn, leaseContext) = connections.leaseStream(onRequired: el1) else {
            return XCTFail("lease unexpectedly failed")
        }
        XCTAssertEqual(leasedConn, conn1)
        XCTAssertEqual(leaseContext.wasIdle, false)

        XCTAssertNil(
            connections.leaseStream(onRequired: el1),
            "should not be able to lease stream because they are all already leased"
        )
    }

    func testGoAway() {
        let elg = EmbeddedEventLoopGroup(loops: 4)
        var connections = HTTPConnectionPool.HTTP2Connections(generator: .init(), maximumConnectionUses: nil)
        let el1 = elg.next()

        let conn1ID = connections.createNewConnection(on: el1)
        let conn1: HTTPConnectionPool.Connection = .__testOnly_connection(id: conn1ID, eventLoop: el1)
        let (conn1Index, conn1CreatedContext) = connections.newHTTP2ConnectionEstablished(
            conn1,
            maxConcurrentStreams: 10
        )
        XCTAssertEqual(conn1CreatedContext.availableStreams, 10)

        let (leasedConn1, leasdConnContext1) = connections.leaseStreams(at: conn1Index, count: 2)
        XCTAssertEqual(leasedConn1, conn1)
        XCTAssertEqual(leasdConnContext1.wasIdle, true)

        XCTAssertTrue(connections.goAwayReceived(conn1ID)?.eventLoop === el1)

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

        XCTAssertNil(
            connections.leaseStream(onRequired: el1),
            "we should not be able to lease a stream because the connection is draining"
        )

        // a server can potentially send more than one connection go away and we should not crash
        XCTAssertTrue(connections.goAwayReceived(conn1ID)?.eventLoop === el1)
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
        var connections = HTTPConnectionPool.HTTP2Connections(generator: .init(), maximumConnectionUses: nil)
        let el1 = elg.next()

        let conn1ID = connections.createNewConnection(on: el1)
        let conn1: HTTPConnectionPool.Connection = .__testOnly_connection(id: conn1ID, eventLoop: el1)
        let (conn1Index, conn1CreatedContext) = connections.newHTTP2ConnectionEstablished(
            conn1,
            maxConcurrentStreams: 1
        )
        XCTAssertEqual(conn1CreatedContext.availableStreams, 1)

        let (leasedConn1, leasdConnContext1) = connections.leaseStreams(at: conn1Index, count: 1)
        XCTAssertEqual(leasedConn1, conn1)
        XCTAssertEqual(leasdConnContext1.wasIdle, true)

        XCTAssertNil(connections.leaseStream(onRequired: el1), "all streams are in use")

        guard let (_, newSettingsContext1) = connections.newHTTP2MaxConcurrentStreamsReceived(conn1ID, newMaxStreams: 2)
        else {
            return XCTFail("Expected to get a new settings context")
        }
        XCTAssertEqual(newSettingsContext1.availableStreams, 1)
        XCTAssertTrue(newSettingsContext1.eventLoop === el1)
        XCTAssertFalse(newSettingsContext1.isIdle)

        guard let (leasedConn2, leaseContext2) = connections.leaseStream(onRequired: el1) else {
            return XCTFail("lease unexpectedly failed")
        }
        XCTAssertEqual(leasedConn2, conn1)
        XCTAssertEqual(leaseContext2.wasIdle, false)

        guard let (_, newSettingsContext2) = connections.newHTTP2MaxConcurrentStreamsReceived(conn1ID, newMaxStreams: 1)
        else {
            return XCTFail("Expected to get a new settings context")
        }
        XCTAssertEqual(newSettingsContext2.availableStreams, 0)
        XCTAssertTrue(newSettingsContext2.eventLoop === el1)
        XCTAssertFalse(newSettingsContext2.isIdle)

        // release a connection
        let (_, release1Context) = connections.releaseStream(conn1ID)
        XCTAssertFalse(release1Context.isIdle)
        XCTAssertEqual(release1Context.availableStreams, 0)

        XCTAssertNil(connections.leaseStream(onRequired: el1), "all streams are in use")

        // release a connection
        let (_, release2Context) = connections.releaseStream(conn1ID)
        XCTAssertTrue(release2Context.isIdle)
        XCTAssertEqual(release2Context.availableStreams, 1)

        guard let (leasedConn3, leaseContext3) = connections.leaseStream(onRequired: el1) else {
            return XCTFail("lease unexpectedly failed")
        }
        XCTAssertEqual(leasedConn3, conn1)
        XCTAssertEqual(leaseContext3.wasIdle, true)
    }

    func testEventsAfterConnectionIsClosed() {
        let elg = EmbeddedEventLoopGroup(loops: 2)
        var connections = HTTPConnectionPool.HTTP2Connections(generator: .init(), maximumConnectionUses: nil)
        let el1 = elg.next()

        let conn1ID = connections.createNewConnection(on: el1)
        let conn1: HTTPConnectionPool.Connection = .__testOnly_connection(id: conn1ID, eventLoop: el1)
        let (conn1Index, conn1CreatedContext) = connections.newHTTP2ConnectionEstablished(
            conn1,
            maxConcurrentStreams: 1
        )
        XCTAssertEqual(conn1CreatedContext.availableStreams, 1)

        let (leasedConn1, leasdConnContext1) = connections.leaseStreams(at: conn1Index, count: 1)
        XCTAssertEqual(leasedConn1, conn1)
        XCTAssertEqual(leasdConnContext1.wasIdle, true)

        XCTAssertNil(connections.leaseStream(onRequired: el1), "all streams are in use")

        let (_, releaseContext) = connections.releaseStream(conn1ID)
        XCTAssertTrue(releaseContext.eventLoop === el1)
        XCTAssertEqual(releaseContext.availableStreams, 1)
        XCTAssertEqual(releaseContext.connectionID, conn1ID)
        XCTAssertEqual(releaseContext.isIdle, true)

        // schedule timeout... this should remove the connection from http2Connections

        XCTAssertEqual(connections.closeConnectionIfIdle(conn1ID), conn1)

        // events race with the complete shutdown

        XCTAssertNil(connections.newHTTP2MaxConcurrentStreamsReceived(conn1ID, newMaxStreams: 2))
        XCTAssertNil(connections.goAwayReceived(conn1ID))

        // finally close event
        XCTAssertNil(connections.failConnection(conn1ID))
    }

    func testLeaseOnPreferredEventLoopWithoutAnyAvailable() {
        let elg = EmbeddedEventLoopGroup(loops: 4)
        var connections = HTTPConnectionPool.HTTP2Connections(generator: .init(), maximumConnectionUses: nil)
        let el1 = elg.next()

        let conn1ID = connections.createNewConnection(on: el1)
        let conn1: HTTPConnectionPool.Connection = .__testOnly_connection(id: conn1ID, eventLoop: el1)
        let (conn1Index, conn1CreatedContext) = connections.newHTTP2ConnectionEstablished(
            conn1,
            maxConcurrentStreams: 1
        )
        XCTAssertEqual(conn1CreatedContext.availableStreams, 1)
        let (leasedConn1, leasdConnContext1) = connections.leaseStreams(at: conn1Index, count: 1)
        XCTAssertEqual(leasedConn1, conn1)
        XCTAssertEqual(leasdConnContext1.wasIdle, true)

        XCTAssertNil(connections.leaseStream(onPreferred: el1), "all streams are in use")
    }

    func testMigrationFromHTTP1() {
        let elg = EmbeddedEventLoopGroup(loops: 4)
        var connections = HTTPConnectionPool.HTTP2Connections(generator: .init(), maximumConnectionUses: nil)
        let el1 = elg.next()
        let el2 = elg.next()
        let conn1ID: HTTPConnectionPool.Connection.ID = 1
        let conn2ID: HTTPConnectionPool.Connection.ID = 2

        connections.migrateFromHTTP1(
            starting: [(conn1ID, el1)],
            backingOff: [(conn2ID, el2)]
        )
        XCTAssertTrue(
            connections.createConnectionsAfterMigrationIfNeeded(
                requiredEventLoopsOfPendingRequests: [el1, el2]
            ).isEmpty
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
        let (conn1Index, conn1CreatedContext) = connections.newHTTP2ConnectionEstablished(
            conn1,
            maxConcurrentStreams: 100
        )
        XCTAssertEqual(conn1CreatedContext.availableStreams, 100)

        let (leasedConn1, leasdConnContext1) = connections.leaseStreams(at: conn1Index, count: 2)
        XCTAssertEqual(leasedConn1, conn1)
        XCTAssertEqual(leasdConnContext1.wasIdle, true)

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

    func testMigrationToHTTP1() {
        let elg = EmbeddedEventLoopGroup(loops: 4)
        let generator = HTTPConnectionPool.Connection.ID.Generator()
        var connections = HTTPConnectionPool.HTTP2Connections(generator: generator, maximumConnectionUses: nil)
        let el1 = elg.next()
        let el2 = elg.next()
        let el3 = elg.next()
        let el4 = elg.next()

        let conn1ID = generator.next()
        let conn2ID = generator.next()
        let conn3ID = generator.next()
        let conn4ID = generator.next()

        connections.migrateFromHTTP1(
            starting: [(conn1ID, el1), (conn2ID, el2), (conn3ID, el3)],
            backingOff: [(conn4ID, el4)]
        )

        let conn1: HTTPConnectionPool.Connection = .__testOnly_connection(id: conn1ID, eventLoop: el1)
        let (conn1Index, conn1CreatedContext) = connections.newHTTP2ConnectionEstablished(
            conn1,
            maxConcurrentStreams: 100
        )
        XCTAssertEqual(conn1CreatedContext.availableStreams, 100)

        let (leasedConn1, leasdConnContext1) = connections.leaseStreams(at: conn1Index, count: 2)
        XCTAssertEqual(leasedConn1, conn1)
        XCTAssertEqual(leasdConnContext1.wasIdle, true)

        let conn2: HTTPConnectionPool.Connection = .__testOnly_connection(id: conn2ID, eventLoop: el2)
        let (_, conn2CreatedContext) = connections.newHTTP2ConnectionEstablished(conn2, maxConcurrentStreams: 100)
        XCTAssertEqual(conn2CreatedContext.availableStreams, 100)

        XCTAssertEqual(
            connections.stats,
            .init(
                startingConnections: 1,
                backingOffConnections: 1,
                idleConnections: 1,
                availableConnections: 2,
                drainingConnections: 0,
                leasedStreams: 2,
                availableStreams: 198
            )
        )

        let migrationContext = connections.migrateToHTTP1()
        XCTAssertEqual(migrationContext.close, [conn2])
        XCTAssertEqual(migrationContext.starting.map { $0.0 }, [conn3ID])
        XCTAssertEqual(migrationContext.starting.map { $0.1.id }, [el3.id])
        XCTAssertEqual(migrationContext.backingOff.map { $0.0 }, [conn4ID])
        XCTAssertEqual(migrationContext.backingOff.map { $0.1.id }, [el4.id])

        XCTAssertEqual(
            connections.stats,
            .init(
                startingConnections: 0,
                backingOffConnections: 0,
                idleConnections: 0,
                availableConnections: 1,
                drainingConnections: 0,
                leasedStreams: 2,
                availableStreams: 98
            )
        )
    }

    func testMigrationFromHTTP1WithPendingRequestsWithRequiredEventLoop() {
        let elg = EmbeddedEventLoopGroup(loops: 4)
        let generator = HTTPConnectionPool.Connection.ID.Generator()
        var connections = HTTPConnectionPool.HTTP2Connections(generator: generator, maximumConnectionUses: nil)
        let el1 = elg.next()
        let el2 = elg.next()
        let el3 = elg.next()
        let conn1ID = generator.next()
        let conn2ID = generator.next()

        connections.migrateFromHTTP1(
            starting: [(conn1ID, el1)],
            backingOff: [(conn2ID, el2)]
        )
        let newConnections = connections.createConnectionsAfterMigrationIfNeeded(
            requiredEventLoopsOfPendingRequests: [el1, el2, el3]
        )

        XCTAssertEqual(newConnections.count, 1)

        guard let (conn3ID, eventLoop) = newConnections.first else {
            return XCTFail("expected to start a new connection")
        }
        XCTAssertTrue(eventLoop === el3)

        let conn3: HTTPConnectionPool.Connection = .__testOnly_connection(id: conn3ID, eventLoop: el3)
        let (_, context) = connections.newHTTP2ConnectionEstablished(conn3, maxConcurrentStreams: 100)
        XCTAssertEqual(context.availableStreams, 100)
        XCTAssertEqual(context.eventLoop.id, el3.id)
        XCTAssertEqual(context.isIdle, true)
        XCTAssertEqual(context.connectionID, conn3ID)
    }

    func testMigrationFromHTTP1WithAlreadyEstablishedHTTP2Connection() {
        let elg = EmbeddedEventLoopGroup(loops: 4)
        let generator = HTTPConnectionPool.Connection.ID.Generator()
        var connections = HTTPConnectionPool.HTTP2Connections(generator: generator, maximumConnectionUses: nil)
        let el1 = elg.next()
        let el2 = elg.next()
        let el3 = elg.next()

        let conn1ID = connections.createNewConnection(on: el1)
        let conn1: HTTPConnectionPool.Connection = .__testOnly_connection(id: conn1ID, eventLoop: el1)
        let (index, _) = connections.newHTTP2ConnectionEstablished(conn1, maxConcurrentStreams: 100)
        _ = connections.leaseStreams(at: index, count: 1)

        let conn2ID = generator.next()
        let conn3ID = generator.next()

        connections.migrateFromHTTP1(
            starting: [(conn2ID, el2)],
            backingOff: [(conn3ID, el3)]
        )

        XCTAssertTrue(
            connections.createConnectionsAfterMigrationIfNeeded(
                requiredEventLoopsOfPendingRequests: [el1, el2, el3]
            ).isEmpty,
            "we still have an active connection for el1 and should not create a new one"
        )

        guard let (leasedConn, _) = connections.leaseStream(onRequired: el1) else {
            return XCTFail("could not lease stream on el1")
        }
        XCTAssertEqual(leasedConn, conn1)
    }
}
