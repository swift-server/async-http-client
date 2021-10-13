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
import NIOHTTP1
import NIOPosix
import XCTest

private typealias Action = HTTPConnectionPool.StateMachine.Action
private typealias ConnectionAction = HTTPConnectionPool.StateMachine.ConnectionAction
private typealias RequestAction = HTTPConnectionPool.StateMachine.RequestAction

class HTTPConnectionPool_HTTP2StateMachineTests: XCTestCase {
    func testCreatingOfConnection() {
        let elg = EmbeddedEventLoopGroup(loops: 1)
        let el1 = elg.next()
        var connections = MockConnectionPool()
        var queuer = MockRequestQueuer()
        var state = HTTPConnectionPool.HTTP2StateMachine(idGenerator: .init())

        /// first request should create a new connection
        let mockRequest = MockHTTPRequest(eventLoop: el1)
        let request = HTTPConnectionPool.Request(mockRequest)
        let executeAction = state.executeRequest(request)

        guard case .createConnection(let connID, let eventLoop) = executeAction.connection else {
            return XCTFail("Unexpected connection action \(executeAction.connection)")
        }
        XCTAssertTrue(eventLoop === el1)

        XCTAssertEqual(executeAction.request, .scheduleRequestTimeout(for: request, on: mockRequest.eventLoop))

        XCTAssertNoThrow(try connections.createConnection(connID, on: el1))
        XCTAssertNoThrow(try queuer.queue(mockRequest, id: request.id))

        /// subsequent requests should not create a connection
        for _ in 0..<9 {
            let mockRequest = MockHTTPRequest(eventLoop: el1)
            let request = HTTPConnectionPool.Request(mockRequest)
            let action = state.executeRequest(request)

            XCTAssertEqual(action.connection, .none)
            XCTAssertEqual(action.request, .scheduleRequestTimeout(for: request, on: mockRequest.eventLoop))

            XCTAssertNoThrow(try queuer.queue(mockRequest, id: request.id))
        }

        /// connection establishment should result in 5 request executions because we set max concurrent streams to 5
        var maybeConn: HTTPConnectionPool.Connection?
        XCTAssertNoThrow(maybeConn = try connections.succeedConnectionCreationHTTP2(connID, maxConcurrentStreams: 5))
        guard let conn = maybeConn else {
            return XCTFail("unexpected throw")
        }
        let action = state.newHTTP2ConnectionEstablished(conn, maxConcurrentStreams: 5)

        XCTAssertEqual(action.connection, .none)
        guard case .executeRequestsAndCancelTimeouts(let requests, conn) = action.request else {
            return XCTFail("Unexpected request action \(action.request)")
        }
        XCTAssertEqual(requests.count, 5)

        for request in requests {
            XCTAssertNoThrow(try queuer.get(request.id, request: request.__testOnly_wrapped_request()))
        }

        /// closing a stream while we have requests queued should result in one request execution action
        for _ in 0..<5 {
            let action = state.http2ConnectionStreamClosed(connID)
            XCTAssertEqual(action.connection, .none)
            guard case .executeRequestsAndCancelTimeouts(let requests, conn) = action.request else {
                return XCTFail("Unexpected request action \(action.request)")
            }
            XCTAssertEqual(requests.count, 1)
            for request in requests {
                XCTAssertNoThrow(try queuer.cancel(request.id))
            }
        }
        XCTAssertTrue(queuer.isEmpty)

        /// closing streams without any queued requests shouldn't do anything if it's *not* the last stream
        for _ in 0..<4 {
            let action = state.http2ConnectionStreamClosed(connID)
            XCTAssertEqual(action.request, .none)
            XCTAssertEqual(action.connection, .none)
        }

        /// 4 streams are available and therefore request should be executed immediately
        for _ in 0..<4 {
            let mockRequest = MockHTTPRequest(eventLoop: el1, requiresEventLoopForChannel: true)
            let request = HTTPConnectionPool.Request(mockRequest)
            let action = state.executeRequest(request)

            XCTAssertEqual(action.connection, .none)
            XCTAssertEqual(action.request, .executeRequest(request, conn, cancelTimeout: false))
        }

        /// closing streams without any queued requests shouldn't do anything if it's *not* the last stream
        for _ in 0..<4 {
            let action = state.http2ConnectionStreamClosed(connID)
            XCTAssertEqual(action.request, .none)
            XCTAssertEqual(action.connection, .none)
        }

        /// closing the last stream should schedule a idle timeout
        let streamCloseAction = state.http2ConnectionStreamClosed(connID)
        XCTAssertEqual(streamCloseAction.request, .none)
        XCTAssertEqual(streamCloseAction.connection, .scheduleTimeoutTimer(connID, on: el1))

        /// shutdown should only close one connection
        let shutdownAction = state.shutdown()
        XCTAssertEqual(shutdownAction.request, .none)
        XCTAssertEqual(shutdownAction.connection, .cleanupConnections(
            .init(
                close: [conn],
                cancel: [],
                connectBackoff: []
            ),
            isShutdown: .yes(unclean: false)
        ))
    }

    func testConnectionFailureBackoff() {
        let elg = EmbeddedEventLoopGroup(loops: 4)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }

        var state = HTTPConnectionPool.HTTP2StateMachine(
            idGenerator: .init()
        )

        let mockRequest = MockHTTPRequest(eventLoop: elg.next())
        let request = HTTPConnectionPool.Request(mockRequest)

        let action = state.executeRequest(request)
        XCTAssertEqual(.scheduleRequestTimeout(for: request, on: mockRequest.eventLoop), action.request)

        // 1. connection attempt
        guard case .createConnection(let connectionID, on: let connectionEL) = action.connection else {
            return XCTFail("Unexpected connection action: \(action.connection)")
        }
        XCTAssert(connectionEL === mockRequest.eventLoop) // XCTAssertIdentical not available on Linux

        let failedConnect1 = state.failedToCreateNewConnection(HTTPClientError.connectTimeout, connectionID: connectionID)
        XCTAssertEqual(failedConnect1.request, .none)
        guard case .scheduleBackoffTimer(connectionID, let backoffTimeAmount1, _) = failedConnect1.connection else {
            return XCTFail("Unexpected connection action: \(failedConnect1.connection)")
        }

        // 2. connection attempt
        let backoffDoneAction = state.connectionCreationBackoffDone(connectionID)
        XCTAssertEqual(backoffDoneAction.request, .none)
        guard case .createConnection(let newConnectionID, on: let newEventLoop) = backoffDoneAction.connection else {
            return XCTFail("Unexpected connection action: \(backoffDoneAction.connection)")
        }
        XCTAssertGreaterThan(newConnectionID, connectionID)
        XCTAssert(connectionEL === newEventLoop) // XCTAssertIdentical not available on Linux

        let failedConnect2 = state.failedToCreateNewConnection(HTTPClientError.connectTimeout, connectionID: newConnectionID)
        XCTAssertEqual(failedConnect2.request, .none)
        guard case .scheduleBackoffTimer(newConnectionID, let backoffTimeAmount2, _) = failedConnect2.connection else {
            return XCTFail("Unexpected connection action: \(failedConnect2.connection)")
        }

        XCTAssertNotEqual(backoffTimeAmount2, backoffTimeAmount1)

        // 3. request times out
        let failRequest = state.timeoutRequest(request.id)
        guard case .failRequest(let requestToFail, let requestError, cancelTimeout: false) = failRequest.request else {
            return XCTFail("Unexpected request action: \(action.request)")
        }
        XCTAssert(requestToFail.__testOnly_wrapped_request() === mockRequest) // XCTAssertIdentical not available on Linux
        XCTAssertEqual(requestError as? HTTPClientError, .connectTimeout)
        XCTAssertEqual(failRequest.connection, .none)

        // 4. retry connection, but no more queued requests.
        XCTAssertEqual(state.connectionCreationBackoffDone(newConnectionID), .none)
    }

    func testCancelRequestWorks() {
        let elg = EmbeddedEventLoopGroup(loops: 4)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }

        var state = HTTPConnectionPool.HTTP2StateMachine(
            idGenerator: .init()
        )

        let mockRequest = MockHTTPRequest(eventLoop: elg.next())
        let request = HTTPConnectionPool.Request(mockRequest)

        let executeAction = state.executeRequest(request)
        XCTAssertEqual(.scheduleRequestTimeout(for: request, on: mockRequest.eventLoop), executeAction.request)

        // 1. connection attempt
        guard case .createConnection(let connectionID, on: let connectionEL) = executeAction.connection else {
            return XCTFail("Unexpected connection action: \(executeAction.connection)")
        }
        XCTAssert(connectionEL === mockRequest.eventLoop) // XCTAssertIdentical not available on Linux

        // 2. cancel request
        let cancelAction = state.cancelRequest(request.id)
        XCTAssertEqual(cancelAction.request, .cancelRequestTimeout(request.id))
        XCTAssertEqual(cancelAction.connection, .none)

        // 3. request timeout triggers to late
        XCTAssertEqual(state.timeoutRequest(request.id), .none, "To late timeout is ignored")

        // 4. succeed connection attempt
        let connectedAction = state.newHTTP2ConnectionEstablished(
            .__testOnly_connection(id: connectionID, eventLoop: connectionEL),
            maxConcurrentStreams: 100
        )
        XCTAssertEqual(connectedAction.request, .none, "Request must not be executed")
        XCTAssertEqual(connectedAction.connection, .scheduleTimeoutTimer(connectionID, on: connectionEL))
    }

    func testExecuteOnShuttingDownPool() {
        let elg = EmbeddedEventLoopGroup(loops: 4)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }

        var state = HTTPConnectionPool.HTTP2StateMachine(
            idGenerator: .init()
        )

        let mockRequest = MockHTTPRequest(eventLoop: elg.next())
        let request = HTTPConnectionPool.Request(mockRequest)

        let executeAction = state.executeRequest(request)
        XCTAssertEqual(.scheduleRequestTimeout(for: request, on: mockRequest.eventLoop), executeAction.request)

        // 1. connection attempt
        guard case .createConnection(let connectionID, on: let connectionEL) = executeAction.connection else {
            return XCTFail("Unexpected connection action: \(executeAction.connection)")
        }
        XCTAssert(connectionEL === mockRequest.eventLoop) // XCTAssertIdentical not available on Linux

        // 2. connection succeeds
        let connection: HTTPConnectionPool.Connection = .__testOnly_connection(id: connectionID, eventLoop: connectionEL)
        let connectedAction = state.newHTTP2ConnectionEstablished(connection, maxConcurrentStreams: 100)
        guard case .executeRequestsAndCancelTimeouts([request], connection) = connectedAction.request else {
            return XCTFail("Unexpected request action: \(connectedAction.request)")
        }
        XCTAssert(request.__testOnly_wrapped_request() === mockRequest) // XCTAssertIdentical not available on Linux
        XCTAssertEqual(connectedAction.connection, .none)

        // 3. shutdown
        let shutdownAction = state.shutdown()
        XCTAssertEqual(.none, shutdownAction.request)
        guard case .cleanupConnections(let cleanupContext, isShutdown: .no) = shutdownAction.connection else {
            return XCTFail("Unexpected connection action: \(shutdownAction.connection)")
        }

        XCTAssertEqual(cleanupContext.cancel.count, 1)
        XCTAssertEqual(cleanupContext.cancel.first?.id, connectionID)
        XCTAssertEqual(cleanupContext.close, [])
        XCTAssertEqual(cleanupContext.connectBackoff, [])

        // 4. execute another request
        let finalMockRequest = MockHTTPRequest(eventLoop: elg.next())
        let finalRequest = HTTPConnectionPool.Request(finalMockRequest)
        let failAction = state.executeRequest(finalRequest)
        XCTAssertEqual(failAction.connection, .none)
        XCTAssertEqual(failAction.request, .failRequest(finalRequest, HTTPClientError.alreadyShutdown, cancelTimeout: false))

        // 5. close open connection
        let closeAction = state.http2ConnectionClosed(connectionID)
        XCTAssertEqual(closeAction.connection, .cleanupConnections(.init(), isShutdown: .yes(unclean: true)))
        XCTAssertEqual(closeAction.request, .none)
    }

    func testHTTP1ToHTTP2MigrationAndShutdownIfFirstConnectionIsHTTP1() {
        let elg = EmbeddedEventLoopGroup(loops: 4)
        let el1 = elg.next()

        let idGenerator = HTTPConnectionPool.Connection.ID.Generator()
        var http1State = HTTPConnectionPool.HTTP1StateMachine(idGenerator: idGenerator, maximumConcurrentConnections: 8)

        let mockRequest1 = MockHTTPRequest(eventLoop: el1)
        let request1 = HTTPConnectionPool.Request(mockRequest1)
        let mockRequest2 = MockHTTPRequest(eventLoop: el1)
        let request2 = HTTPConnectionPool.Request(mockRequest2)

        let executeAction1 = http1State.executeRequest(request1)
        XCTAssertEqual(executeAction1.request, .scheduleRequestTimeout(for: request1, on: el1))
        guard case .createConnection(let conn1ID, _) = executeAction1.connection else {
            return XCTFail("unexpected connection action \(executeAction1.connection)")
        }
        let executeAction2 = http1State.executeRequest(request2)
        XCTAssertEqual(executeAction2.request, .scheduleRequestTimeout(for: request2, on: el1))
        guard case .createConnection(let conn2ID, _) = executeAction2.connection else {
            return XCTFail("unexpected connection action \(executeAction2.connection)")
        }

        // first connection is a HTTP1 connection
        let conn1: HTTPConnectionPool.Connection = .__testOnly_connection(id: conn1ID, eventLoop: el1)
        let conn1Action = http1State.newHTTP1ConnectionEstablished(conn1)
        XCTAssertEqual(conn1Action.connection, .none)
        XCTAssertEqual(conn1Action.request, .executeRequest(request1, conn1, cancelTimeout: true))

        // second connection is a HTTP2 connection and we need to migrate
        let conn2: HTTPConnectionPool.Connection = .__testOnly_connection(id: conn2ID, eventLoop: el1)
        var http2State = HTTPConnectionPool.HTTP2StateMachine(idGenerator: idGenerator)

        let http2ConnectAction = http2State.migrateFromHTTP1(http1State: http1State, newHTTP2Connection: conn2, maxConcurrentStreams: 100)
        XCTAssertEqual(http2ConnectAction.connection, .migration(createConnections: [], closeConnections: [], scheduleTimeout: nil))
        guard case .executeRequestsAndCancelTimeouts([request2], conn2) = http2ConnectAction.request else {
            return XCTFail("Unexpected request action \(http2ConnectAction.request)")
        }

        // second request is done first
        let closeAction = http2State.http2ConnectionStreamClosed(conn2ID)
        XCTAssertEqual(closeAction.request, .none)
        XCTAssertEqual(closeAction.connection, .scheduleTimeoutTimer(conn2ID, on: el1))

        let shutdownAction = http2State.shutdown()
        XCTAssertEqual(shutdownAction.request, .none)
        XCTAssertEqual(shutdownAction.connection, .cleanupConnections(.init(
            close: [conn2],
            cancel: [],
            connectBackoff: []
        ), isShutdown: .no))

        let releaseAction = http2State.http1ConnectionReleased(conn1ID)
        XCTAssertEqual(releaseAction.request, .none)
        XCTAssertEqual(releaseAction.connection, .closeConnection(conn1, isShutdown: .yes(unclean: true)))
    }

    func testSchedulingAndCancelingOfIdleTimeout() {
        let elg = EmbeddedEventLoopGroup(loops: 1)
        let el1 = elg.next()

        // establish one idle http2 connection
        let idGenerator = HTTPConnectionPool.Connection.ID.Generator()
        var http1Conns = HTTPConnectionPool.HTTP1Connections(maximumConcurrentConnections: 8, generator: idGenerator)
        let conn1ID = http1Conns.createNewConnection(on: el1)
        var state = HTTPConnectionPool.HTTP2StateMachine(idGenerator: idGenerator)

        let conn1 = HTTPConnectionPool.Connection.__testOnly_connection(id: conn1ID, eventLoop: el1)
        let connectAction = state.migrateFromHTTP1(http1Connections: http1Conns, requests: .init(), newHTTP2Connection: conn1, maxConcurrentStreams: 100)

        XCTAssertEqual(connectAction.request, .none)
        XCTAssertEqual(connectAction.connection, .migration(
            createConnections: [],
            closeConnections: [],
            scheduleTimeout: (conn1ID, el1)
        ))

        // execute request on idle connection
        let mockRequest1 = MockHTTPRequest(eventLoop: el1)
        let request1 = HTTPConnectionPool.Request(mockRequest1)
        let request1Action = state.executeRequest(request1)
        XCTAssertEqual(request1Action.request, .executeRequest(request1, conn1, cancelTimeout: false))
        XCTAssertEqual(request1Action.connection, .cancelTimeoutTimer(conn1ID))

        // close stream
        let closeStream1Action = state.http2ConnectionStreamClosed(conn1ID)
        XCTAssertEqual(closeStream1Action.request, .none)
        XCTAssertEqual(closeStream1Action.connection, .scheduleTimeoutTimer(conn1ID, on: el1))

        // execute request on idle connection with required event loop
        let mockRequest2 = MockHTTPRequest(eventLoop: el1, requiresEventLoopForChannel: true)
        let request2 = HTTPConnectionPool.Request(mockRequest2)
        let request2Action = state.executeRequest(request2)
        XCTAssertEqual(request2Action.request, .executeRequest(request2, conn1, cancelTimeout: false))
        XCTAssertEqual(request2Action.connection, .cancelTimeoutTimer(conn1ID))

        // close stream
        let closeStream2Action = state.http2ConnectionStreamClosed(conn1ID)
        XCTAssertEqual(closeStream2Action.request, .none)
        XCTAssertEqual(closeStream2Action.connection, .scheduleTimeoutTimer(conn1ID, on: el1))
    }

    func testConnectionTimeout() {
        let elg = EmbeddedEventLoopGroup(loops: 1)
        let el1 = elg.next()

        // establish one idle http2 connection
        let idGenerator = HTTPConnectionPool.Connection.ID.Generator()
        var http1Conns = HTTPConnectionPool.HTTP1Connections(maximumConcurrentConnections: 8, generator: idGenerator)
        let conn1ID = http1Conns.createNewConnection(on: el1)
        var state = HTTPConnectionPool.HTTP2StateMachine(idGenerator: idGenerator)

        let conn1 = HTTPConnectionPool.Connection.__testOnly_connection(id: conn1ID, eventLoop: el1)
        let connectAction = state.migrateFromHTTP1(http1Connections: http1Conns, requests: .init(), newHTTP2Connection: conn1, maxConcurrentStreams: 100)
        XCTAssertEqual(connectAction.request, .none)
        XCTAssertEqual(connectAction.connection, .migration(
            createConnections: [],
            closeConnections: [],
            scheduleTimeout: (conn1ID, el1)
        ))

        // let the connection timeout
        let timeoutAction = state.connectionIdleTimeout(conn1ID)
        XCTAssertEqual(timeoutAction.request, .none)
        XCTAssertEqual(timeoutAction.connection, .closeConnection(conn1, isShutdown: .no))
    }

    func testConnectionEstablishmentFailure() {
        struct SomeError: Error, Equatable {}

        let elg = EmbeddedEventLoopGroup(loops: 2)
        let el1 = elg.next()
        let el2 = elg.next()

        // establish one idle http2 connection
        let idGenerator = HTTPConnectionPool.Connection.ID.Generator()
        var http1Conns = HTTPConnectionPool.HTTP1Connections(maximumConcurrentConnections: 8, generator: idGenerator)
        let conn1ID = http1Conns.createNewConnection(on: el1)
        var state = HTTPConnectionPool.HTTP2StateMachine(idGenerator: idGenerator)
        let conn1 = HTTPConnectionPool.Connection.__testOnly_connection(id: conn1ID, eventLoop: el1)
        let connectAction = state.migrateFromHTTP1(http1Connections: http1Conns, requests: .init(), newHTTP2Connection: conn1, maxConcurrentStreams: 100)
        XCTAssertEqual(connectAction.request, .none)
        XCTAssertEqual(connectAction.connection, .migration(
            createConnections: [],
            closeConnections: [],
            scheduleTimeout: (conn1ID, el1)
        ))

        // create new http2 connection
        let mockRequest1 = MockHTTPRequest(eventLoop: el2, requiresEventLoopForChannel: true)
        let request1 = HTTPConnectionPool.Request(mockRequest1)
        let executeAction = state.executeRequest(request1)
        XCTAssertEqual(executeAction.request, .scheduleRequestTimeout(for: request1, on: el2))
        guard case .createConnection(let conn2ID, _) = executeAction.connection else {
            return XCTFail("unexpected connection action \(executeAction.connection)")
        }

        let action = state.failedToCreateNewConnection(SomeError(), connectionID: conn2ID)
        XCTAssertEqual(action.request, .none)
        guard case .scheduleBackoffTimer(conn2ID, _, let eventLoop) = action.connection else {
            return XCTFail("unexpected connection action \(action.connection)")
        }
        XCTAssertEqual(eventLoop.id, el2.id)
    }

    func testGoAwayOnIdleConnection() {
        let elg = EmbeddedEventLoopGroup(loops: 1)
        let el1 = elg.next()

        // establish one idle http2 connection
        let idGenerator = HTTPConnectionPool.Connection.ID.Generator()
        var http1Conns = HTTPConnectionPool.HTTP1Connections(maximumConcurrentConnections: 8, generator: idGenerator)
        let conn1ID = http1Conns.createNewConnection(on: el1)
        var state = HTTPConnectionPool.HTTP2StateMachine(idGenerator: idGenerator)

        let conn1 = HTTPConnectionPool.Connection.__testOnly_connection(id: conn1ID, eventLoop: el1)

        let connectAction = state.migrateFromHTTP1(
            http1Connections: http1Conns,
            requests: .init(),
            newHTTP2Connection: conn1,
            maxConcurrentStreams: 100
        )
        XCTAssertEqual(connectAction.request, .none)
        XCTAssertEqual(connectAction.connection, .migration(
            createConnections: [],
            closeConnections: [],
            scheduleTimeout: (conn1ID, el1)
        ))

        let goAwayAction = state.http2ConnectionGoAwayReceived(conn1ID)
        XCTAssertEqual(goAwayAction.request, .none)
        XCTAssertEqual(goAwayAction.connection, .none, "Connection is automatically closed by HTTP2IdleHandler")
    }

    func testGoAwayWithLeasedStream() {
        let elg = EmbeddedEventLoopGroup(loops: 1)
        let el1 = elg.next()

        // establish one idle http2 connection
        let idGenerator = HTTPConnectionPool.Connection.ID.Generator()
        var http1Conns = HTTPConnectionPool.HTTP1Connections(maximumConcurrentConnections: 8, generator: idGenerator)
        let conn1ID = http1Conns.createNewConnection(on: el1)
        var state = HTTPConnectionPool.HTTP2StateMachine(idGenerator: idGenerator)

        let conn1 = HTTPConnectionPool.Connection.__testOnly_connection(id: conn1ID, eventLoop: el1)
        let connectAction = state.migrateFromHTTP1(
            http1Connections: http1Conns,
            requests: .init(),
            newHTTP2Connection: conn1,
            maxConcurrentStreams: 100
        )
        XCTAssertEqual(connectAction.request, .none)
        XCTAssertEqual(connectAction.connection, .migration(
            createConnections: [],
            closeConnections: [],
            scheduleTimeout: (conn1ID, el1)
        ))

        // execute request on idle connection
        let mockRequest1 = MockHTTPRequest(eventLoop: el1)
        let request1 = HTTPConnectionPool.Request(mockRequest1)
        let request1Action = state.executeRequest(request1)
        XCTAssertEqual(request1Action.request, .executeRequest(request1, conn1, cancelTimeout: false))
        XCTAssertEqual(request1Action.connection, .cancelTimeoutTimer(conn1ID))

        let goAwayAction = state.http2ConnectionGoAwayReceived(conn1ID)
        XCTAssertEqual(goAwayAction.request, .none)
        XCTAssertEqual(goAwayAction.connection, .none)

        // close stream
        let closeStream1Action = state.http2ConnectionStreamClosed(conn1ID)
        XCTAssertEqual(closeStream1Action.request, .none)
        XCTAssertEqual(closeStream1Action.connection, .none, "Connection is automatically closed by HTTP2IdleHandler")
    }

    func testGoAwayWithPendingRequestsStartsNewConnection() {
        let elg = EmbeddedEventLoopGroup(loops: 1)
        let el1 = elg.next()

        // establish one idle http2 connection
        let idGenerator = HTTPConnectionPool.Connection.ID.Generator()
        var http1Conns = HTTPConnectionPool.HTTP1Connections(maximumConcurrentConnections: 8, generator: idGenerator)
        let conn1ID = http1Conns.createNewConnection(on: el1)
        var state = HTTPConnectionPool.HTTP2StateMachine(idGenerator: idGenerator)

        let conn1 = HTTPConnectionPool.Connection.__testOnly_connection(id: conn1ID, eventLoop: el1)
        let connectAction1 = state.migrateFromHTTP1(
            http1Connections: http1Conns,
            requests: .init(),
            newHTTP2Connection: conn1,
            maxConcurrentStreams: 1
        )
        XCTAssertEqual(connectAction1.request, .none)
        XCTAssertEqual(connectAction1.connection, .migration(
            createConnections: [],
            closeConnections: [],
            scheduleTimeout: (conn1ID, el1)
        ))

        // execute request
        let mockRequest1 = MockHTTPRequest(eventLoop: el1)
        let request1 = HTTPConnectionPool.Request(mockRequest1)
        let request1Action = state.executeRequest(request1)
        XCTAssertEqual(request1Action.request, .executeRequest(request1, conn1, cancelTimeout: false))
        XCTAssertEqual(request1Action.connection, .cancelTimeoutTimer(conn1ID))

        // queue request
        let mockRequest2 = MockHTTPRequest(eventLoop: el1)
        let request2 = HTTPConnectionPool.Request(mockRequest2)
        let request2Action = state.executeRequest(request2)
        XCTAssertEqual(request2Action.request, .scheduleRequestTimeout(for: request2, on: el1))
        XCTAssertEqual(request2Action.connection, .none)

        // go away should create a new connection
        let goAwayAction = state.http2ConnectionGoAwayReceived(conn1ID)
        XCTAssertEqual(goAwayAction.request, .none)
        guard case .createConnection(let conn2ID, let eventLoop) = goAwayAction.connection else {
            return XCTFail("unexpected connection action \(goAwayAction.connection)")
        }
        XCTAssertEqual(el1.id, eventLoop.id)

        // new connection should execute pending request
        let conn2 = HTTPConnectionPool.Connection.__testOnly_connection(id: conn2ID, eventLoop: el1)
        let connectAction2 = state.newHTTP2ConnectionEstablished(conn2, maxConcurrentStreams: 1)
        XCTAssertEqual(connectAction2.request, .executeRequestsAndCancelTimeouts([request2], conn2))
        XCTAssertEqual(connectAction2.connection, .none)

        // close stream from conn1
        let closeStream1Action = state.http2ConnectionStreamClosed(conn1ID)
        XCTAssertEqual(closeStream1Action.request, .none)
        XCTAssertEqual(closeStream1Action.connection, .none, "Connection is automatically closed by HTTP2IdleHandler")

        // close stream from conn2
        let closeStream2Action = state.http2ConnectionStreamClosed(conn2ID)
        XCTAssertEqual(closeStream2Action.request, .none)
        XCTAssertEqual(closeStream2Action.connection, .scheduleTimeoutTimer(conn2ID, on: el1))
    }
}
