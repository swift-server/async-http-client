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
import NIOHTTP1
import NIOPosix
import XCTest

@testable import AsyncHTTPClient

private typealias Action = HTTPConnectionPool.StateMachine.Action
private typealias ConnectionAction = HTTPConnectionPool.StateMachine.ConnectionAction
private typealias RequestAction = HTTPConnectionPool.StateMachine.RequestAction

class HTTPConnectionPool_HTTP2StateMachineTests: XCTestCase {
    func testCreatingOfConnection() {
        let elg = EmbeddedEventLoopGroup(loops: 1)
        let el1 = elg.next()
        var connections = MockConnectionPool()
        var queuer = MockRequestQueuer()
        var state = HTTPConnectionPool.HTTP2StateMachine(
            idGenerator: .init(),
            retryConnectionEstablishment: true,
            lifecycleState: .running,
            maximumConnectionUses: nil
        )

        /// first request should create a new connection
        let mockRequest = MockHTTPScheduableRequest(eventLoop: el1)
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
            let mockRequest = MockHTTPScheduableRequest(eventLoop: el1)
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
            let mockRequest = MockHTTPScheduableRequest(eventLoop: el1, requiresEventLoopForChannel: true)
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
        XCTAssertEqual(
            shutdownAction.connection,
            .cleanupConnections(
                .init(
                    close: [conn],
                    cancel: [],
                    connectBackoff: []
                ),
                isShutdown: .yes(unclean: false)
            )
        )
    }

    func testConnectionFailureBackoff() {
        let elg = EmbeddedEventLoopGroup(loops: 4)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }

        var state = HTTPConnectionPool.HTTP2StateMachine(
            idGenerator: .init(),
            retryConnectionEstablishment: true,
            lifecycleState: .running,
            maximumConnectionUses: nil
        )

        let mockRequest = MockHTTPScheduableRequest(eventLoop: elg.next())
        let request = HTTPConnectionPool.Request(mockRequest)

        let action = state.executeRequest(request)
        XCTAssertEqual(.scheduleRequestTimeout(for: request, on: mockRequest.eventLoop), action.request)

        // 1. connection attempt
        guard case .createConnection(let connectionID, on: let connectionEL) = action.connection else {
            return XCTFail("Unexpected connection action: \(action.connection)")
        }
        XCTAssert(connectionEL === mockRequest.eventLoop)  // XCTAssertIdentical not available on Linux

        let failedConnect1 = state.failedToCreateNewConnection(
            HTTPClientError.connectTimeout,
            connectionID: connectionID
        )
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
        XCTAssert(connectionEL === newEventLoop)  // XCTAssertIdentical not available on Linux

        let failedConnect2 = state.failedToCreateNewConnection(
            HTTPClientError.connectTimeout,
            connectionID: newConnectionID
        )
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
        // XCTAssertIdentical not available on Linux
        XCTAssert(requestToFail.__testOnly_wrapped_request() === mockRequest)
        XCTAssertEqual(requestError as? HTTPClientError, .connectTimeout)
        XCTAssertEqual(failRequest.connection, .none)

        // 4. retry connection, but no more queued requests.
        XCTAssertEqual(state.connectionCreationBackoffDone(newConnectionID), .none)
    }

    func testConnectionFailureWhileShuttingDown() {
        struct SomeError: Error, Equatable {}
        let elg = EmbeddedEventLoopGroup(loops: 4)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }

        var state = HTTPConnectionPool.HTTP2StateMachine(
            idGenerator: .init(),
            retryConnectionEstablishment: false,
            lifecycleState: .running,
            maximumConnectionUses: nil
        )

        let mockRequest = MockHTTPScheduableRequest(eventLoop: elg.next())
        let request = HTTPConnectionPool.Request(mockRequest)

        let action = state.executeRequest(request)
        XCTAssertEqual(.scheduleRequestTimeout(for: request, on: mockRequest.eventLoop), action.request)

        // 1. connection attempt
        guard case .createConnection(let connectionID, on: let connectionEL) = action.connection else {
            return XCTFail("Unexpected connection action: \(action.connection)")
        }
        XCTAssert(connectionEL === mockRequest.eventLoop)  // XCTAssertIdentical not available on Linux

        // 2. initialise shutdown
        let shutdownAction = state.shutdown()
        XCTAssertEqual(shutdownAction.connection, .cleanupConnections(.init(), isShutdown: .no))
        guard case .failRequestsAndCancelTimeouts(let requestsToFail, let requestError) = shutdownAction.request else {
            return XCTFail("Unexpected request action: \(action.request)")
        }
        XCTAssertEqualTypeAndValue(requestError, HTTPClientError.cancelled)
        XCTAssertEqualTypeAndValue(requestsToFail, [request])

        // 3. connection attempt fails
        let failedConnectAction = state.failedToCreateNewConnection(SomeError(), connectionID: connectionID)
        XCTAssertEqual(failedConnectAction.request, .none)
        XCTAssertEqual(failedConnectAction.connection, .cleanupConnections(.init(), isShutdown: .yes(unclean: true)))
    }

    func testConnectionFailureWithoutRetry() {
        struct SomeError: Error, Equatable {}
        let elg = EmbeddedEventLoopGroup(loops: 4)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }

        var state = HTTPConnectionPool.HTTP2StateMachine(
            idGenerator: .init(),
            retryConnectionEstablishment: false,
            lifecycleState: .running,
            maximumConnectionUses: nil
        )

        let mockRequest = MockHTTPScheduableRequest(eventLoop: elg.next())
        let request = HTTPConnectionPool.Request(mockRequest)

        let action = state.executeRequest(request)
        XCTAssertEqual(.scheduleRequestTimeout(for: request, on: mockRequest.eventLoop), action.request)

        // 1. connection attempt
        guard case .createConnection(let connectionID, on: let connectionEL) = action.connection else {
            return XCTFail("Unexpected connection action: \(action.connection)")
        }
        XCTAssert(connectionEL === mockRequest.eventLoop)  // XCTAssertIdentical not available on Linux

        let failedConnectAction = state.failedToCreateNewConnection(SomeError(), connectionID: connectionID)
        XCTAssertEqual(failedConnectAction.connection, .none)
        guard case .failRequestsAndCancelTimeouts(let requestsToFail, let requestError) = failedConnectAction.request
        else {
            return XCTFail("Unexpected request action: \(action.request)")
        }
        XCTAssertEqualTypeAndValue(requestError, SomeError())
        XCTAssertEqualTypeAndValue(requestsToFail, [request])
    }

    func testCancelRequestWorks() {
        let elg = EmbeddedEventLoopGroup(loops: 4)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }

        var state = HTTPConnectionPool.HTTP2StateMachine(
            idGenerator: .init(),
            retryConnectionEstablishment: true,
            lifecycleState: .running,
            maximumConnectionUses: nil
        )

        let mockRequest = MockHTTPScheduableRequest(eventLoop: elg.next())
        let request = HTTPConnectionPool.Request(mockRequest)

        let executeAction = state.executeRequest(request)
        XCTAssertEqual(.scheduleRequestTimeout(for: request, on: mockRequest.eventLoop), executeAction.request)

        // 1. connection attempt
        guard case .createConnection(let connectionID, on: let connectionEL) = executeAction.connection else {
            return XCTFail("Unexpected connection action: \(executeAction.connection)")
        }
        XCTAssert(connectionEL === mockRequest.eventLoop)  // XCTAssertIdentical not available on Linux

        // 2. cancel request
        let cancelAction = state.cancelRequest(request.id)
        XCTAssertEqual(cancelAction.request, .failRequest(request, HTTPClientError.cancelled, cancelTimeout: true))
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
            idGenerator: .init(),
            retryConnectionEstablishment: true,
            lifecycleState: .running,
            maximumConnectionUses: nil
        )

        let mockRequest = MockHTTPScheduableRequest(eventLoop: elg.next())
        let request = HTTPConnectionPool.Request(mockRequest)

        let executeAction = state.executeRequest(request)
        XCTAssertEqual(.scheduleRequestTimeout(for: request, on: mockRequest.eventLoop), executeAction.request)

        // 1. connection attempt
        guard case .createConnection(let connectionID, on: let connectionEL) = executeAction.connection else {
            return XCTFail("Unexpected connection action: \(executeAction.connection)")
        }
        XCTAssert(connectionEL === mockRequest.eventLoop)  // XCTAssertIdentical not available on Linux

        // 2. connection succeeds
        let connection: HTTPConnectionPool.Connection = .__testOnly_connection(
            id: connectionID,
            eventLoop: connectionEL
        )
        let connectedAction = state.newHTTP2ConnectionEstablished(connection, maxConcurrentStreams: 100)
        guard case .executeRequestsAndCancelTimeouts([request], connection) = connectedAction.request else {
            return XCTFail("Unexpected request action: \(connectedAction.request)")
        }
        XCTAssert(request.__testOnly_wrapped_request() === mockRequest)  // XCTAssertIdentical not available on Linux
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
        let finalMockRequest = MockHTTPScheduableRequest(eventLoop: elg.next())
        let finalRequest = HTTPConnectionPool.Request(finalMockRequest)
        let failAction = state.executeRequest(finalRequest)
        XCTAssertEqual(failAction.connection, .none)
        XCTAssertEqual(
            failAction.request,
            .failRequest(finalRequest, HTTPClientError.alreadyShutdown, cancelTimeout: false)
        )

        // 5. close open connection
        let closeAction = state.http2ConnectionClosed(connectionID)
        XCTAssertEqual(closeAction.connection, .cleanupConnections(.init(), isShutdown: .yes(unclean: true)))
        XCTAssertEqual(closeAction.request, .none)
    }

    func testHTTP1ToHTTP2MigrationAndShutdownIfFirstConnectionIsHTTP1() {
        let elg = EmbeddedEventLoopGroup(loops: 4)
        let el1 = elg.next()

        let idGenerator = HTTPConnectionPool.Connection.ID.Generator()
        var http1State = HTTPConnectionPool.HTTP1StateMachine(
            idGenerator: idGenerator,
            maximumConcurrentConnections: 8,
            retryConnectionEstablishment: true,
            maximumConnectionUses: nil,
            preWarmedHTTP1ConnectionCount: 0,
            lifecycleState: .running
        )

        let mockRequest1 = MockHTTPScheduableRequest(eventLoop: el1)
        let request1 = HTTPConnectionPool.Request(mockRequest1)
        let mockRequest2 = MockHTTPScheduableRequest(eventLoop: el1)
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
        var http2State = HTTPConnectionPool.HTTP2StateMachine(
            idGenerator: idGenerator,
            retryConnectionEstablishment: true,
            lifecycleState: .running,
            maximumConnectionUses: nil
        )

        let http2ConnectAction = http2State.migrateFromHTTP1(
            http1Connections: http1State.connections,
            http2Connections: http1State.http2Connections,
            requests: http1State.requests,
            newHTTP2Connection: conn2,
            maxConcurrentStreams: 100
        )
        XCTAssertEqual(
            http2ConnectAction.connection,
            .migration(createConnections: [], closeConnections: [], scheduleTimeout: nil)
        )
        guard case .executeRequestsAndCancelTimeouts([request2], conn2) = http2ConnectAction.request else {
            return XCTFail("Unexpected request action \(http2ConnectAction.request)")
        }

        // second request is done first
        let closeAction = http2State.http2ConnectionStreamClosed(conn2ID)
        XCTAssertEqual(closeAction.request, .none)
        XCTAssertEqual(closeAction.connection, .scheduleTimeoutTimer(conn2ID, on: el1))

        let shutdownAction = http2State.shutdown()
        XCTAssertEqual(shutdownAction.request, .none)
        XCTAssertEqual(
            shutdownAction.connection,
            .cleanupConnections(
                .init(
                    close: [conn2],
                    cancel: [],
                    connectBackoff: []
                ),
                isShutdown: .no
            )
        )

        let releaseAction = http2State.http1ConnectionReleased(conn1ID)
        XCTAssertEqual(releaseAction.request, .none)
        XCTAssertEqual(releaseAction.connection, .closeConnection(conn1, isShutdown: .yes(unclean: true)))
    }

    func testSchedulingAndCancelingOfIdleTimeout() {
        let elg = EmbeddedEventLoopGroup(loops: 1)
        let el1 = elg.next()

        // establish one idle http2 connection
        let idGenerator = HTTPConnectionPool.Connection.ID.Generator()
        var http1Conns = HTTPConnectionPool.HTTP1Connections(
            maximumConcurrentConnections: 8,
            generator: idGenerator,
            maximumConnectionUses: nil,
            preWarmedHTTP1ConnectionCount: 0
        )
        let conn1ID = http1Conns.createNewConnection(on: el1)
        var state = HTTPConnectionPool.HTTP2StateMachine(
            idGenerator: idGenerator,
            retryConnectionEstablishment: true,
            lifecycleState: .running,
            maximumConnectionUses: nil
        )

        let conn1 = HTTPConnectionPool.Connection.__testOnly_connection(id: conn1ID, eventLoop: el1)
        let connectAction = state.migrateFromHTTP1(
            http1Connections: http1Conns,
            requests: .init(),
            newHTTP2Connection: conn1,
            maxConcurrentStreams: 100
        )

        XCTAssertEqual(connectAction.request, .none)
        XCTAssertEqual(
            connectAction.connection,
            .migration(
                createConnections: [],
                closeConnections: [],
                scheduleTimeout: (conn1ID, el1)
            )
        )

        // execute request on idle connection
        let mockRequest1 = MockHTTPScheduableRequest(eventLoop: el1)
        let request1 = HTTPConnectionPool.Request(mockRequest1)
        let request1Action = state.executeRequest(request1)
        XCTAssertEqual(request1Action.request, .executeRequest(request1, conn1, cancelTimeout: false))
        XCTAssertEqual(request1Action.connection, .cancelTimeoutTimer(conn1ID))

        // close stream
        let closeStream1Action = state.http2ConnectionStreamClosed(conn1ID)
        XCTAssertEqual(closeStream1Action.request, .none)
        XCTAssertEqual(closeStream1Action.connection, .scheduleTimeoutTimer(conn1ID, on: el1))

        // execute request on idle connection with required event loop
        let mockRequest2 = MockHTTPScheduableRequest(eventLoop: el1, requiresEventLoopForChannel: true)
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
        var http1Conns = HTTPConnectionPool.HTTP1Connections(
            maximumConcurrentConnections: 8,
            generator: idGenerator,
            maximumConnectionUses: nil,
            preWarmedHTTP1ConnectionCount: 0
        )
        let conn1ID = http1Conns.createNewConnection(on: el1)
        var state = HTTPConnectionPool.HTTP2StateMachine(
            idGenerator: idGenerator,
            retryConnectionEstablishment: true,
            lifecycleState: .running,
            maximumConnectionUses: nil
        )

        let conn1 = HTTPConnectionPool.Connection.__testOnly_connection(id: conn1ID, eventLoop: el1)
        let connectAction = state.migrateFromHTTP1(
            http1Connections: http1Conns,
            requests: .init(),
            newHTTP2Connection: conn1,
            maxConcurrentStreams: 100
        )
        XCTAssertEqual(connectAction.request, .none)
        XCTAssertEqual(
            connectAction.connection,
            .migration(
                createConnections: [],
                closeConnections: [],
                scheduleTimeout: (conn1ID, el1)
            )
        )

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
        var http1Conns = HTTPConnectionPool.HTTP1Connections(
            maximumConcurrentConnections: 8,
            generator: idGenerator,
            maximumConnectionUses: nil,
            preWarmedHTTP1ConnectionCount: 0
        )
        let conn1ID = http1Conns.createNewConnection(on: el1)
        var state = HTTPConnectionPool.HTTP2StateMachine(
            idGenerator: idGenerator,
            retryConnectionEstablishment: true,
            lifecycleState: .running,
            maximumConnectionUses: nil
        )
        let conn1 = HTTPConnectionPool.Connection.__testOnly_connection(id: conn1ID, eventLoop: el1)
        let connectAction = state.migrateFromHTTP1(
            http1Connections: http1Conns,
            requests: .init(),
            newHTTP2Connection: conn1,
            maxConcurrentStreams: 100
        )
        XCTAssertEqual(connectAction.request, .none)
        XCTAssertEqual(
            connectAction.connection,
            .migration(
                createConnections: [],
                closeConnections: [],
                scheduleTimeout: (conn1ID, el1)
            )
        )

        // create new http2 connection
        let mockRequest1 = MockHTTPScheduableRequest(eventLoop: el2, requiresEventLoopForChannel: true)
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
        var http1Conns = HTTPConnectionPool.HTTP1Connections(
            maximumConcurrentConnections: 8,
            generator: idGenerator,
            maximumConnectionUses: nil,
            preWarmedHTTP1ConnectionCount: 0
        )
        let conn1ID = http1Conns.createNewConnection(on: el1)
        var state = HTTPConnectionPool.HTTP2StateMachine(
            idGenerator: idGenerator,
            retryConnectionEstablishment: true,
            lifecycleState: .running,
            maximumConnectionUses: nil
        )

        let conn1 = HTTPConnectionPool.Connection.__testOnly_connection(id: conn1ID, eventLoop: el1)

        let connectAction = state.migrateFromHTTP1(
            http1Connections: http1Conns,
            requests: .init(),
            newHTTP2Connection: conn1,
            maxConcurrentStreams: 100
        )
        XCTAssertEqual(connectAction.request, .none)
        XCTAssertEqual(
            connectAction.connection,
            .migration(
                createConnections: [],
                closeConnections: [],
                scheduleTimeout: (conn1ID, el1)
            )
        )

        let goAwayAction = state.http2ConnectionGoAwayReceived(conn1ID)
        XCTAssertEqual(goAwayAction.request, .none)
        XCTAssertEqual(goAwayAction.connection, .none, "Connection is automatically closed by HTTP2IdleHandler")
    }

    func testGoAwayWithLeasedStream() {
        let elg = EmbeddedEventLoopGroup(loops: 1)
        let el1 = elg.next()

        // establish one idle http2 connection
        let idGenerator = HTTPConnectionPool.Connection.ID.Generator()
        var http1Conns = HTTPConnectionPool.HTTP1Connections(
            maximumConcurrentConnections: 8,
            generator: idGenerator,
            maximumConnectionUses: nil,
            preWarmedHTTP1ConnectionCount: 0
        )
        let conn1ID = http1Conns.createNewConnection(on: el1)
        var state = HTTPConnectionPool.HTTP2StateMachine(
            idGenerator: idGenerator,
            retryConnectionEstablishment: true,
            lifecycleState: .running,
            maximumConnectionUses: nil
        )

        let conn1 = HTTPConnectionPool.Connection.__testOnly_connection(id: conn1ID, eventLoop: el1)
        let connectAction = state.migrateFromHTTP1(
            http1Connections: http1Conns,
            requests: .init(),
            newHTTP2Connection: conn1,
            maxConcurrentStreams: 100
        )
        XCTAssertEqual(connectAction.request, .none)
        XCTAssertEqual(
            connectAction.connection,
            .migration(
                createConnections: [],
                closeConnections: [],
                scheduleTimeout: (conn1ID, el1)
            )
        )

        // execute request on idle connection
        let mockRequest1 = MockHTTPScheduableRequest(eventLoop: el1)
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
        var http1Conns = HTTPConnectionPool.HTTP1Connections(
            maximumConcurrentConnections: 8,
            generator: idGenerator,
            maximumConnectionUses: nil,
            preWarmedHTTP1ConnectionCount: 0
        )
        let conn1ID = http1Conns.createNewConnection(on: el1)
        var state = HTTPConnectionPool.HTTP2StateMachine(
            idGenerator: idGenerator,
            retryConnectionEstablishment: true,
            lifecycleState: .running,
            maximumConnectionUses: nil
        )

        let conn1 = HTTPConnectionPool.Connection.__testOnly_connection(id: conn1ID, eventLoop: el1)
        let connectAction1 = state.migrateFromHTTP1(
            http1Connections: http1Conns,
            requests: .init(),
            newHTTP2Connection: conn1,
            maxConcurrentStreams: 1
        )
        XCTAssertEqual(connectAction1.request, .none)
        XCTAssertEqual(
            connectAction1.connection,
            .migration(
                createConnections: [],
                closeConnections: [],
                scheduleTimeout: (conn1ID, el1)
            )
        )

        // execute request
        let mockRequest1 = MockHTTPScheduableRequest(eventLoop: el1)
        let request1 = HTTPConnectionPool.Request(mockRequest1)
        let request1Action = state.executeRequest(request1)
        XCTAssertEqual(request1Action.request, .executeRequest(request1, conn1, cancelTimeout: false))
        XCTAssertEqual(request1Action.connection, .cancelTimeoutTimer(conn1ID))

        // queue request
        let mockRequest2 = MockHTTPScheduableRequest(eventLoop: el1)
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

    func testMigrationFromHTTP1ToHTTP2() {
        let elg = EmbeddedEventLoopGroup(loops: 1)
        let el1 = elg.next()
        var connections = MockConnectionPool()
        var queuer = MockRequestQueuer()
        var state = HTTPConnectionPool.StateMachine(
            idGenerator: .init(),
            maximumConcurrentHTTP1Connections: 8,
            retryConnectionEstablishment: true,
            preferHTTP1: true,
            maximumConnectionUses: nil,
            preWarmedHTTP1ConnectionCount: 0
        )

        /// first 8 request should create a new connection
        var connectionIDs: [HTTPConnectionPool.Connection.ID] = []
        for _ in 0..<8 {
            let mockRequest = MockHTTPScheduableRequest(eventLoop: el1)
            let request = HTTPConnectionPool.Request(mockRequest)
            let action = state.executeRequest(request)
            guard case .createConnection(let connID, let eventLoop) = action.connection else {
                return XCTFail("Unexpected connection action \(action.connection)")
            }
            connectionIDs.append(connID)
            XCTAssertTrue(eventLoop === el1)
            XCTAssertEqual(action.request, .scheduleRequestTimeout(for: request, on: mockRequest.eventLoop))
            XCTAssertNoThrow(try connections.createConnection(connID, on: el1))
            XCTAssertNoThrow(try queuer.queue(mockRequest, id: request.id))
        }

        guard let conn1ID = connectionIDs.first else {
            return XCTFail("could not create connection")
        }

        /// after we reached the `maximumConcurrentHTTP1Connections`, we will not create new connections
        for _ in 0..<8 {
            let mockRequest = MockHTTPScheduableRequest(eventLoop: el1)
            let request = HTTPConnectionPool.Request(mockRequest)
            let action = state.executeRequest(request)
            XCTAssertEqual(action.connection, .none)
            XCTAssertEqual(action.request, .scheduleRequestTimeout(for: request, on: mockRequest.eventLoop))

            XCTAssertNoThrow(try queuer.queue(mockRequest, id: request.id))
        }

        /// first new HTTP2 connection should migrate from HTTP1 to HTTP2 and execute requests
        let conn1: HTTPConnectionPool.Connection = .__testOnly_connection(id: conn1ID, eventLoop: el1)
        XCTAssertNoThrow(try connections.succeedConnectionCreationHTTP2(conn1ID, maxConcurrentStreams: 10))
        let migrationAction = state.newHTTP2ConnectionCreated(conn1, maxConcurrentStreams: 10)
        guard case .executeRequestsAndCancelTimeouts(let requests, let conn) = migrationAction.request else {
            return XCTFail("unexpected request action \(migrationAction.request)")
        }
        XCTAssertEqual(conn, conn1)
        XCTAssertEqual(requests.count, 10)

        for request in requests {
            XCTAssertNoThrow(try queuer.get(request.id, request: request.__testOnly_wrapped_request()))
            XCTAssertNoThrow(try connections.execute(request.__testOnly_wrapped_request(), on: conn1))
        }

        XCTAssertEqual(
            migrationAction.connection,
            .migration(
                createConnections: [],
                closeConnections: [],
                scheduleTimeout: nil
            )
        )

        /// remaining connections should be closed immediately without executing any request
        for connID in connectionIDs.dropFirst() {
            let conn: HTTPConnectionPool.Connection = .__testOnly_connection(id: connID, eventLoop: el1)
            XCTAssertNoThrow(try connections.succeedConnectionCreationHTTP2(connID, maxConcurrentStreams: 10))
            let action = state.newHTTP2ConnectionCreated(conn, maxConcurrentStreams: 10)
            XCTAssertEqual(action.request, .none)
            XCTAssertEqual(action.connection, .closeConnection(conn, isShutdown: .no))
            XCTAssertNoThrow(try connections.closeConnection(conn))
        }

        /// closing a stream while we have requests queued should result in one request execution action
        for _ in 0..<6 {
            XCTAssertNoThrow(try connections.finishExecution(conn1ID))
            let action = state.http2ConnectionStreamClosed(conn1ID)
            XCTAssertEqual(action.connection, .none)
            guard case .executeRequestsAndCancelTimeouts(let requests, conn) = action.request else {
                return XCTFail("Unexpected request action \(action.request)")
            }
            XCTAssertEqual(requests.count, 1)
            for request in requests {
                XCTAssertNoThrow(try queuer.cancel(request.id))
                XCTAssertNoThrow(try connections.execute(request.__testOnly_wrapped_request(), on: conn1))
            }
        }
        XCTAssertTrue(queuer.isEmpty)
    }

    func testMigrationFromHTTP1ToHTTP2WhileShuttingDown() {
        let elg = EmbeddedEventLoopGroup(loops: 1)
        let el1 = elg.next()
        var connections = MockConnectionPool()
        var queuer = MockRequestQueuer()
        var state = HTTPConnectionPool.StateMachine(
            idGenerator: .init(),
            maximumConcurrentHTTP1Connections: 8,
            retryConnectionEstablishment: true,
            preferHTTP1: false,
            maximumConnectionUses: nil,
            preWarmedHTTP1ConnectionCount: 0
        )

        /// create a new connection
        let mockRequest = MockHTTPScheduableRequest(eventLoop: el1)
        let request = HTTPConnectionPool.Request(mockRequest)
        let action = state.executeRequest(request)
        guard case .createConnection(let conn1ID, let eventLoop) = action.connection else {
            return XCTFail("Unexpected connection action \(action.connection)")
        }

        XCTAssertTrue(eventLoop === el1)
        XCTAssertEqual(action.request, .scheduleRequestTimeout(for: request, on: mockRequest.eventLoop))
        XCTAssertNoThrow(try connections.createConnection(conn1ID, on: el1))
        XCTAssertNoThrow(try queuer.queue(mockRequest, id: request.id))

        /// we now no longer want anything of it
        let shutdownAction = state.shutdown()
        guard case .failRequestsAndCancelTimeouts(let requestsToCancel, let error) = shutdownAction.request else {
            return XCTFail("unexpected shutdown action \(shutdownAction)")
        }
        XCTAssertEqualTypeAndValue(error, HTTPClientError.cancelled)

        for request in requestsToCancel {
            XCTAssertNoThrow(try queuer.cancel(request.id))
        }
        XCTAssertTrue(queuer.isEmpty)

        /// new HTTP2 connection should migrate from HTTP1 to HTTP2, close the connection and shutdown the pool
        let conn1: HTTPConnectionPool.Connection = .__testOnly_connection(id: conn1ID, eventLoop: el1)
        XCTAssertNoThrow(try connections.succeedConnectionCreationHTTP2(conn1ID, maxConcurrentStreams: 10))
        let migrationAction = state.newHTTP2ConnectionCreated(conn1, maxConcurrentStreams: 10)
        XCTAssertEqual(migrationAction.request, .none)
        XCTAssertEqual(migrationAction.connection, .closeConnection(conn1, isShutdown: .yes(unclean: true)))
        XCTAssertNoThrow(try connections.closeConnection(conn1))
        XCTAssertTrue(connections.isEmpty)
    }

    func testMigrationFromHTTP1ToHTTP2WithAlreadyStartedHTTP1Connections() {
        let elg = EmbeddedEventLoopGroup(loops: 1)
        let el1 = elg.next()
        var connections = MockConnectionPool()
        var queuer = MockRequestQueuer()
        var state = HTTPConnectionPool.StateMachine(
            idGenerator: .init(),
            maximumConcurrentHTTP1Connections: 8,
            retryConnectionEstablishment: true,
            preferHTTP1: true,
            maximumConnectionUses: nil,
            preWarmedHTTP1ConnectionCount: 0
        )

        /// first 8 request should create a new connection
        var connectionIDs: [HTTPConnectionPool.Connection.ID] = []
        for _ in 0..<8 {
            let mockRequest = MockHTTPScheduableRequest(eventLoop: el1)
            let request = HTTPConnectionPool.Request(mockRequest)
            let action = state.executeRequest(request)
            guard case .createConnection(let connID, let eventLoop) = action.connection else {
                return XCTFail("Unexpected connection action \(action.connection)")
            }
            connectionIDs.append(connID)
            XCTAssertTrue(eventLoop === el1)
            XCTAssertEqual(action.request, .scheduleRequestTimeout(for: request, on: mockRequest.eventLoop))
            XCTAssertNoThrow(try connections.createConnection(connID, on: el1))
            XCTAssertNoThrow(try queuer.queue(mockRequest, id: request.id))
        }

        /// after we reached the `maximumConcurrentHTTP1Connections`, we will not create new connections
        for _ in 0..<8 {
            let mockRequest = MockHTTPScheduableRequest(eventLoop: el1)
            let request = HTTPConnectionPool.Request(mockRequest)
            let action = state.executeRequest(request)
            XCTAssertEqual(action.connection, .none)
            XCTAssertEqual(action.request, .scheduleRequestTimeout(for: request, on: mockRequest.eventLoop))
            XCTAssertNoThrow(try queuer.queue(mockRequest, id: request.id))
        }

        let http1ConnIDs = connectionIDs.prefix(4)
        let succesfullHTTP1ConnIDs = http1ConnIDs.prefix(2)
        let failedHTTP1ConnIDs = http1ConnIDs.dropFirst(2)

        /// new http1 connection should execute 1 request
        for connID in succesfullHTTP1ConnIDs {
            let conn: HTTPConnectionPool.Connection = .__testOnly_connection(id: connID, eventLoop: el1)
            XCTAssertNoThrow(try connections.succeedConnectionCreationHTTP1(connID))
            let action = state.newHTTP1ConnectionCreated(conn)
            guard case .executeRequest(let request, conn, cancelTimeout: true) = action.request else {
                return XCTFail("unexpected request action \(action.request)")
            }
            XCTAssertEqual(action.connection, .none)
            XCTAssertNoThrow(try queuer.get(request.id, request: request.__testOnly_wrapped_request()))
            XCTAssertNoThrow(try connections.execute(request.__testOnly_wrapped_request(), on: conn))
        }

        /// failing connection should backoff connection
        for connID in failedHTTP1ConnIDs {
            XCTAssertNoThrow(try connections.failConnectionCreation(connID))
            struct SomeError: Error {}
            let action = state.failedToCreateNewConnection(SomeError(), connectionID: connID)
            guard case .scheduleBackoffTimer(connID, backoff: _, let el) = action.connection else {
                return XCTFail("unexpected connection action \(action.connection)")
            }
            XCTAssertEqual(action.request, .none)
            XCTAssertTrue(el === el1)
            XCTAssertNoThrow(try connections.startConnectionBackoffTimer(connID))
        }

        let http2ConnectionIDs = Array(connectionIDs.dropFirst(4))

        guard let firstHTTP2ConnID = http2ConnectionIDs.first else {
            return XCTFail("could not create connection")
        }

        /// first new HTTP2 connection should migrate from HTTP1 to HTTP2 and execute requests
        let http2Conn: HTTPConnectionPool.Connection = .__testOnly_connection(id: firstHTTP2ConnID, eventLoop: el1)
        XCTAssertNoThrow(try connections.succeedConnectionCreationHTTP2(firstHTTP2ConnID, maxConcurrentStreams: 10))
        let migrationAction = state.newHTTP2ConnectionCreated(http2Conn, maxConcurrentStreams: 10)
        guard case .executeRequestsAndCancelTimeouts(let requests, let conn) = migrationAction.request else {
            return XCTFail("unexpected request action \(migrationAction.request)")
        }
        XCTAssertEqual(
            migrationAction.connection,
            .migration(createConnections: [], closeConnections: [], scheduleTimeout: nil)
        )

        XCTAssertEqual(conn, http2Conn)
        XCTAssertEqual(requests.count, 10)

        for request in requests {
            XCTAssertNoThrow(try queuer.get(request.id, request: request.__testOnly_wrapped_request()))
            XCTAssertNoThrow(try connections.execute(request.__testOnly_wrapped_request(), on: http2Conn))
        }

        /// remaining connections should be closed immediately without executing any request
        for connID in http2ConnectionIDs.dropFirst() {
            let conn: HTTPConnectionPool.Connection = .__testOnly_connection(id: connID, eventLoop: el1)
            XCTAssertNoThrow(try connections.succeedConnectionCreationHTTP2(connID, maxConcurrentStreams: 10))
            let action = state.newHTTP2ConnectionCreated(conn, maxConcurrentStreams: 10)
            XCTAssertEqual(action.request, .none)
            XCTAssertEqual(action.connection, .closeConnection(conn, isShutdown: .no))
            XCTAssertNoThrow(try connections.closeConnection(conn))
        }

        /// after a request has finished on a http1 connection, the connection should be closed
        /// because we are now in http/2 mode
        for http1ConnectionID in succesfullHTTP1ConnIDs {
            XCTAssertNoThrow(try connections.finishExecution(http1ConnectionID))
            let action = state.http1ConnectionReleased(http1ConnectionID)
            XCTAssertEqual(action.request, .none)
            guard case .closeConnection(let conn, isShutdown: .no) = action.connection else {
                return XCTFail("unexpected connection action \(migrationAction.connection)")
            }
            XCTAssertEqual(conn.id, http1ConnectionID)
        }

        /// if a backoff timer fires for an old http1 connection we should not start a new connection
        /// because we are already in http2 mode
        for http1ConnectionID in failedHTTP1ConnIDs {
            XCTAssertNoThrow(try connections.connectionBackoffTimerDone(http1ConnectionID))
            let action = state.connectionCreationBackoffDone(http1ConnectionID)
            XCTAssertEqual(action, .none)
        }

        /// closing a stream while we have requests queued should result in one request execution action
        for _ in 0..<4 {
            XCTAssertNoThrow(try connections.finishExecution(http2Conn.id))
            let action = state.http2ConnectionStreamClosed(http2Conn.id)
            XCTAssertEqual(action.connection, .none)
            guard case .executeRequestsAndCancelTimeouts(let requests, http2Conn) = action.request else {
                return XCTFail("Unexpected request action \(action.request)")
            }
            XCTAssertEqual(requests.count, 1)
            for request in requests {
                XCTAssertNoThrow(try queuer.get(request.id, request: request.__testOnly_wrapped_request()))
                XCTAssertNoThrow(try connections.execute(request.__testOnly_wrapped_request(), on: http2Conn))
            }
        }

        XCTAssertTrue(queuer.isEmpty)
    }

    func testHTTP2toHTTP1Migration() {
        let elg = EmbeddedEventLoopGroup(loops: 2)
        let el1 = elg.next()
        let el2 = elg.next()
        var connections = MockConnectionPool()
        var queuer = MockRequestQueuer()
        var state = HTTPConnectionPool.StateMachine(
            idGenerator: .init(),
            maximumConcurrentHTTP1Connections: 8,
            retryConnectionEstablishment: true,
            preferHTTP1: false,
            maximumConnectionUses: nil,
            preWarmedHTTP1ConnectionCount: 0
        )

        // create http2 connection
        let mockRequest = MockHTTPScheduableRequest(eventLoop: el1)
        let request1 = HTTPConnectionPool.Request(mockRequest)
        let action1 = state.executeRequest(request1)
        guard case .createConnection(let http2ConnID, let http2EventLoop) = action1.connection else {
            return XCTFail("Unexpected connection action \(action1.connection)")
        }
        XCTAssertTrue(http2EventLoop === el1)
        XCTAssertEqual(action1.request, .scheduleRequestTimeout(for: request1, on: mockRequest.eventLoop))
        XCTAssertNoThrow(try connections.createConnection(http2ConnID, on: el1))
        XCTAssertNoThrow(try queuer.queue(mockRequest, id: request1.id))
        let http2Conn: HTTPConnectionPool.Connection = .__testOnly_connection(id: http2ConnID, eventLoop: el1)
        XCTAssertNoThrow(try connections.succeedConnectionCreationHTTP2(http2ConnID, maxConcurrentStreams: 10))
        let executeAction1 = state.newHTTP2ConnectionCreated(http2Conn, maxConcurrentStreams: 10)
        guard case .executeRequestsAndCancelTimeouts(let requests, http2Conn) = executeAction1.request else {
            return XCTFail("unexpected request action \(executeAction1.request)")
        }

        XCTAssertEqual(requests.count, 1)
        for request in requests {
            XCTAssertNoThrow(try queuer.get(request.id, request: request.__testOnly_wrapped_request()))
            XCTAssertNoThrow(try connections.execute(request.__testOnly_wrapped_request(), on: http2Conn))
        }

        // a request with new required event loop should create a new connection
        let mockRequestWithRequiredEventLoop = MockHTTPScheduableRequest(
            eventLoop: el2,
            requiresEventLoopForChannel: true
        )
        let requestWithRequiredEventLoop = HTTPConnectionPool.Request(mockRequestWithRequiredEventLoop)
        let action2 = state.executeRequest(requestWithRequiredEventLoop)
        guard case .createConnection(let http1ConnId, let http1EventLoop) = action2.connection else {
            return XCTFail("Unexpected connection action \(action2.connection)")
        }
        XCTAssertTrue(http1EventLoop === el2)
        XCTAssertEqual(
            action2.request,
            .scheduleRequestTimeout(for: requestWithRequiredEventLoop, on: mockRequestWithRequiredEventLoop.eventLoop)
        )
        XCTAssertNoThrow(try connections.createConnection(http1ConnId, on: el2))
        XCTAssertNoThrow(try queuer.queue(mockRequestWithRequiredEventLoop, id: requestWithRequiredEventLoop.id))

        // if we established a new http/1 connection we should migrate back to http/1
        let http1Conn: HTTPConnectionPool.Connection = .__testOnly_connection(id: http1ConnId, eventLoop: el2)
        XCTAssertNoThrow(try connections.succeedConnectionCreationHTTP1(http1ConnId))
        let migrationAction2 = state.newHTTP1ConnectionCreated(http1Conn)
        guard case .executeRequest(let request2, http1Conn, cancelTimeout: true) = migrationAction2.request else {
            return XCTFail("unexpected request action \(migrationAction2.request)")
        }
        guard
            case .migration(let createConnections, closeConnections: [], scheduleTimeout: nil) = migrationAction2
                .connection
        else {
            return XCTFail("unexpected connection action \(migrationAction2.connection)")
        }
        XCTAssertEqual(createConnections.map { $0.1.id }, [el2.id])
        XCTAssertNoThrow(try queuer.get(request2.id, request: request2.__testOnly_wrapped_request()))
        XCTAssertNoThrow(try connections.execute(request2.__testOnly_wrapped_request(), on: http1Conn))

        // in http/1 state, we should close idle http2 connections
        XCTAssertNoThrow(try connections.finishExecution(http2Conn.id))
        let releaseAction = state.http2ConnectionStreamClosed(http2Conn.id)
        XCTAssertEqual(releaseAction.connection, .closeConnection(http2Conn, isShutdown: .no))
        XCTAssertEqual(releaseAction.request, .none)
        XCTAssertNoThrow(try connections.closeConnection(http2Conn))
    }

    func testHTTP2toHTTP1MigrationDuringShutdown() {
        let elg = EmbeddedEventLoopGroup(loops: 2)
        let el1 = elg.next()
        let el2 = elg.next()
        var connections = MockConnectionPool()
        var queuer = MockRequestQueuer()
        var state = HTTPConnectionPool.StateMachine(
            idGenerator: .init(),
            maximumConcurrentHTTP1Connections: 8,
            retryConnectionEstablishment: true,
            preferHTTP1: false,
            maximumConnectionUses: nil,
            preWarmedHTTP1ConnectionCount: 0
        )

        // create http2 connection
        let mockRequest = MockHTTPScheduableRequest(eventLoop: el1)
        let request1 = HTTPConnectionPool.Request(mockRequest)
        let action1 = state.executeRequest(request1)
        guard case .createConnection(let http2ConnID, let http2EventLoop) = action1.connection else {
            return XCTFail("Unexpected connection action \(action1.connection)")
        }
        XCTAssertTrue(http2EventLoop === el1)
        XCTAssertEqual(action1.request, .scheduleRequestTimeout(for: request1, on: mockRequest.eventLoop))
        XCTAssertNoThrow(try connections.createConnection(http2ConnID, on: el1))
        XCTAssertNoThrow(try queuer.queue(mockRequest, id: request1.id))
        let http2Conn: HTTPConnectionPool.Connection = .__testOnly_connection(id: http2ConnID, eventLoop: el1)
        XCTAssertNoThrow(try connections.succeedConnectionCreationHTTP2(http2ConnID, maxConcurrentStreams: 10))
        let executeAction1 = state.newHTTP2ConnectionCreated(http2Conn, maxConcurrentStreams: 10)
        guard case .executeRequestsAndCancelTimeouts(let requests, http2Conn) = executeAction1.request else {
            return XCTFail("unexpected request action \(executeAction1.request)")
        }

        XCTAssertEqual(requests.count, 1)
        for request in requests {
            XCTAssertNoThrow(try queuer.get(request.id, request: request.__testOnly_wrapped_request()))
            XCTAssertNoThrow(try connections.execute(request.__testOnly_wrapped_request(), on: http2Conn))
        }

        // a request with new required event loop should create a new connection
        let mockRequestWithRequiredEventLoop = MockHTTPScheduableRequest(
            eventLoop: el2,
            requiresEventLoopForChannel: true
        )
        let requestWithRequiredEventLoop = HTTPConnectionPool.Request(mockRequestWithRequiredEventLoop)
        let action2 = state.executeRequest(requestWithRequiredEventLoop)
        guard case .createConnection(let http1ConnId, let http1EventLoop) = action2.connection else {
            return XCTFail("Unexpected connection action \(action2.connection)")
        }
        XCTAssertTrue(http1EventLoop === el2)
        XCTAssertEqual(
            action2.request,
            .scheduleRequestTimeout(for: requestWithRequiredEventLoop, on: mockRequestWithRequiredEventLoop.eventLoop)
        )
        XCTAssertNoThrow(try connections.createConnection(http1ConnId, on: el2))
        XCTAssertNoThrow(try queuer.queue(mockRequestWithRequiredEventLoop, id: requestWithRequiredEventLoop.id))

        /// we now no longer want anything of it
        let shutdownAction = state.shutdown()
        guard case .failRequestsAndCancelTimeouts(let requestsToCancel, let error) = shutdownAction.request else {
            return XCTFail("unexpected shutdown action \(shutdownAction)")
        }
        XCTAssertEqualTypeAndValue(error, HTTPClientError.cancelled)

        for request in requestsToCancel {
            XCTAssertNoThrow(try queuer.cancel(request.id))
        }
        XCTAssertTrue(queuer.isEmpty)

        // if we established a new http/1 connection we should migrate to http/1,
        // close the connection and shutdown the pool
        let http1Conn: HTTPConnectionPool.Connection = .__testOnly_connection(id: http1ConnId, eventLoop: el2)
        XCTAssertNoThrow(try connections.succeedConnectionCreationHTTP1(http1ConnId))
        let migrationAction2 = state.newHTTP1ConnectionCreated(http1Conn)
        XCTAssertEqual(migrationAction2.request, .none)
        XCTAssertEqual(
            migrationAction2.connection,
            .migration(createConnections: [], closeConnections: [http1Conn], scheduleTimeout: nil)
        )

        // in http/1 state, we should close idle http2 connections
        XCTAssertNoThrow(try connections.finishExecution(http2Conn.id))
        let releaseAction = state.http2ConnectionStreamClosed(http2Conn.id)
        XCTAssertEqual(releaseAction.connection, .closeConnection(http2Conn, isShutdown: .yes(unclean: true)))
        XCTAssertEqual(releaseAction.request, .none)
        XCTAssertNoThrow(try connections.closeConnection(http2Conn))
    }

    func testConnectionIsImmediatelyCreatedAfterBackoffTimerFires() {
        let elg = EmbeddedEventLoopGroup(loops: 2)
        let el1 = elg.next()
        let el2 = elg.next()
        var connections = MockConnectionPool()
        var queuer = MockRequestQueuer()
        var state = HTTPConnectionPool.StateMachine(
            idGenerator: .init(),
            maximumConcurrentHTTP1Connections: 8,
            retryConnectionEstablishment: true,
            preferHTTP1: false,
            maximumConnectionUses: nil,
            preWarmedHTTP1ConnectionCount: 0
        )

        var connectionIDs: [HTTPConnectionPool.Connection.ID] = []
        for el in [el1, el2] {
            let mockRequest = MockHTTPScheduableRequest(eventLoop: el, requiresEventLoopForChannel: true)
            let request = HTTPConnectionPool.Request(mockRequest)
            let action = state.executeRequest(request)
            guard case .createConnection(let connID, let eventLoop) = action.connection else {
                return XCTFail("Unexpected connection action \(action.connection)")
            }
            connectionIDs.append(connID)
            XCTAssertTrue(eventLoop === el)
            XCTAssertEqual(action.request, .scheduleRequestTimeout(for: request, on: mockRequest.eventLoop))
            XCTAssertNoThrow(try connections.createConnection(connID, on: el))
            XCTAssertNoThrow(try queuer.queue(mockRequest, id: request.id))
        }

        // fail the connection for el2
        for connectionID in connectionIDs.dropFirst() {
            struct SomeError: Error {}
            XCTAssertNoThrow(try connections.failConnectionCreation(connectionID))
            let action = state.failedToCreateNewConnection(SomeError(), connectionID: connectionID)
            XCTAssertEqual(action.request, .none)
            guard case .scheduleBackoffTimer(connectionID, backoff: _, on: _) = action.connection else {
                return XCTFail("unexpected connection action \(connectionID)")
            }
            XCTAssertNoThrow(try connections.startConnectionBackoffTimer(connectionID))
        }
        let http2ConnID1 = connectionIDs[0]
        let http2ConnID2 = connectionIDs[1]

        // let the first connection on el1 succeed as a http2 connection
        let http2Conn1: HTTPConnectionPool.Connection = .__testOnly_connection(id: http2ConnID1, eventLoop: el1)
        XCTAssertNoThrow(try connections.succeedConnectionCreationHTTP2(http2ConnID1, maxConcurrentStreams: 10))
        let connectionAction = state.newHTTP2ConnectionCreated(http2Conn1, maxConcurrentStreams: 10)
        guard case .executeRequestsAndCancelTimeouts(let requests, http2Conn1) = connectionAction.request else {
            return XCTFail("unexpected request action \(connectionAction.request)")
        }
        XCTAssertEqual(requests.count, 1)
        for request in requests {
            XCTAssertNoThrow(try queuer.get(request.id, request: request.__testOnly_wrapped_request()))
            XCTAssertNoThrow(try connections.execute(request.__testOnly_wrapped_request(), on: http2Conn1))
        }

        // we now have 1 active connection on el1 and 2 backing off connections on el2
        // with 2 queued requests with a requirement to be executed on el2

        // if the backoff timer fires for a connection on el2, we should immediately start a new connection
        XCTAssertNoThrow(try connections.connectionBackoffTimerDone(http2ConnID2))
        let action2 = state.connectionCreationBackoffDone(http2ConnID2)
        XCTAssertEqual(action2.request, .none)
        guard case .createConnection(let newHttp2ConnID2, let eventLoop2) = action2.connection else {
            return XCTFail("Unexpected connection action \(action2.connection)")
        }
        XCTAssertTrue(eventLoop2 === el2)
        XCTAssertNoThrow(try connections.createConnection(newHttp2ConnID2, on: el2))
    }

    func testMaxConcurrentStreamsIsRespected() {
        let elg = EmbeddedEventLoopGroup(loops: 4)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }

        guard var (connections, state) = try? MockConnectionPool.http2(elg: elg, maxConcurrentStreams: 100) else {
            return XCTFail("Test setup failed")
        }

        let generalPurposeConnection = connections.randomParkedConnection()!
        var queuer = MockRequestQueuer()

        // schedule 1000 requests on the pool. The first 100 will be executed right away. All others
        // shall be queued.
        for i in 0..<1000 {
            let requestEL = elg.next()
            let mockRequest = MockHTTPScheduableRequest(eventLoop: requestEL)
            let request = HTTPConnectionPool.Request(mockRequest)

            let executeAction = state.executeRequest(request)
            switch i {
            case 0:
                XCTAssertEqual(executeAction.connection, .cancelTimeoutTimer(generalPurposeConnection.id))
                XCTAssertNoThrow(try connections.activateConnection(generalPurposeConnection.id))
                XCTAssertEqual(
                    executeAction.request,
                    .executeRequest(request, generalPurposeConnection, cancelTimeout: false)
                )
                XCTAssertNoThrow(try connections.execute(mockRequest, on: generalPurposeConnection))
            case 1..<100:
                XCTAssertEqual(
                    executeAction.request,
                    .executeRequest(request, generalPurposeConnection, cancelTimeout: false)
                )
                XCTAssertEqual(executeAction.connection, .none)
                XCTAssertNoThrow(try connections.execute(mockRequest, on: generalPurposeConnection))
            case 100..<1000:
                XCTAssertEqual(executeAction.request, .scheduleRequestTimeout(for: request, on: requestEL))
                XCTAssertEqual(executeAction.connection, .none)
                XCTAssertNoThrow(try queuer.queue(mockRequest, id: request.id))
            default:
                XCTFail("Unexpected")
            }
        }

        // let's end processing 500 requests. For every finished request, we will execute another one
        // right away
        while queuer.count > 500 {
            XCTAssertNoThrow(try connections.finishExecution(generalPurposeConnection.id))
            let finishAction = state.http2ConnectionStreamClosed(generalPurposeConnection.id)
            XCTAssertEqual(finishAction.connection, .none)
            guard case .executeRequestsAndCancelTimeouts(let requests, generalPurposeConnection) = finishAction.request
            else {
                return XCTFail("Unexpected request action: \(finishAction.request)")
            }
            guard requests.count == 1, let request = requests.first else {
                return XCTFail("Expected to get exactly one request!")
            }
            let mockRequest = request.__testOnly_wrapped_request()
            XCTAssertNoThrow(try queuer.get(request.id, request: mockRequest))
            XCTAssertNoThrow(try connections.execute(mockRequest, on: generalPurposeConnection))
        }

        XCTAssertEqual(queuer.count, 500)

        // Next the server allows for more concurrent streams
        let newMaxStreams = 200
        XCTAssertNoThrow(
            try connections.newHTTP2ConnectionSettingsReceived(
                generalPurposeConnection.id,
                maxConcurrentStreams: newMaxStreams
            )
        )
        let newMaxStreamsAction = state.newHTTP2MaxConcurrentStreamsReceived(
            generalPurposeConnection.id,
            newMaxStreams: newMaxStreams
        )
        XCTAssertEqual(newMaxStreamsAction.connection, .none)
        guard
            case .executeRequestsAndCancelTimeouts(let requests, generalPurposeConnection) = newMaxStreamsAction.request
        else {
            return XCTFail(
                "Unexpected request action after new max concurrent stream setting: \(newMaxStreamsAction.request)"
            )
        }
        XCTAssertEqual(requests.count, 100, "Expected to execute 100 more requests")
        for request in requests {
            let mockRequest = request.__testOnly_wrapped_request()
            XCTAssertNoThrow(try connections.execute(mockRequest, on: generalPurposeConnection))
            XCTAssertNoThrow(try queuer.get(request.id, request: mockRequest))
        }

        XCTAssertEqual(queuer.count, 400)

        // let's end processing 100 requests. For every finished request, we will execute another one
        // right away
        while queuer.count > 300 {
            XCTAssertNoThrow(try connections.finishExecution(generalPurposeConnection.id))
            let finishAction = state.http2ConnectionStreamClosed(generalPurposeConnection.id)
            XCTAssertEqual(finishAction.connection, .none)
            guard case .executeRequestsAndCancelTimeouts(let requests, generalPurposeConnection) = finishAction.request
            else {
                return XCTFail("Unexpected request action: \(finishAction.request)")
            }
            guard requests.count == 1, let request = requests.first else {
                return XCTFail("Expected to get exactly one request!")
            }
            let mockRequest = request.__testOnly_wrapped_request()
            XCTAssertNoThrow(try queuer.get(request.id, request: mockRequest))
            XCTAssertNoThrow(try connections.execute(mockRequest, on: generalPurposeConnection))
        }

        // Next the server allows for fewer concurrent streams
        let fewerMaxStreams = 50
        XCTAssertNoThrow(
            try connections.newHTTP2ConnectionSettingsReceived(
                generalPurposeConnection.id,
                maxConcurrentStreams: fewerMaxStreams
            )
        )
        let fewerMaxStreamsAction = state.newHTTP2MaxConcurrentStreamsReceived(
            generalPurposeConnection.id,
            newMaxStreams: fewerMaxStreams
        )
        XCTAssertEqual(fewerMaxStreamsAction.connection, .none)
        XCTAssertEqual(fewerMaxStreamsAction.request, .none)

        // for the next 150 requests that are finished, no new request must be executed.
        for _ in 0..<150 {
            XCTAssertNoThrow(try connections.finishExecution(generalPurposeConnection.id))
            XCTAssertEqual(state.http2ConnectionStreamClosed(generalPurposeConnection.id), .none)
        }

        XCTAssertEqual(queuer.count, 300)

        // let's end all remaining requests. For every finished request, we will execute another one
        // right away
        while queuer.count > 0 {
            XCTAssertNoThrow(try connections.finishExecution(generalPurposeConnection.id))
            let finishAction = state.http2ConnectionStreamClosed(generalPurposeConnection.id)
            XCTAssertEqual(finishAction.connection, .none)
            guard case .executeRequestsAndCancelTimeouts(let requests, generalPurposeConnection) = finishAction.request
            else {
                return XCTFail("Unexpected request action: \(finishAction.request)")
            }
            guard requests.count == 1, let request = requests.first else {
                return XCTFail("Expected to get exactly one request!")
            }
            let mockRequest = request.__testOnly_wrapped_request()
            XCTAssertNoThrow(try queuer.get(request.id, request: mockRequest))
            XCTAssertNoThrow(try connections.execute(mockRequest, on: generalPurposeConnection))
        }

        // Now we only need to drain the remaining 50 requests on the connection
        var timeoutTimerScheduled = false
        for remaining in stride(from: 50, through: 1, by: -1) {
            XCTAssertNoThrow(try connections.finishExecution(generalPurposeConnection.id))
            let finishAction = state.http2ConnectionStreamClosed(generalPurposeConnection.id)
            XCTAssertEqual(finishAction.request, .none)
            switch remaining {
            case 1:
                timeoutTimerScheduled = true
                XCTAssertEqual(
                    finishAction.connection,
                    .scheduleTimeoutTimer(generalPurposeConnection.id, on: generalPurposeConnection.eventLoop)
                )
                XCTAssertNoThrow(try connections.parkConnection(generalPurposeConnection.id))
            case 2...50:
                XCTAssertEqual(finishAction.connection, .none)
            default:
                XCTFail("Unexpected value: \(remaining)")
            }
        }
        XCTAssertTrue(timeoutTimerScheduled)
        XCTAssertNotNil(connections.randomParkedConnection())
        XCTAssertEqual(connections.count, 1)
    }

    func testEventsAfterConnectionIsClosed() {
        let elg = EmbeddedEventLoopGroup(loops: 2)
        guard var (connections, state) = try? MockConnectionPool.http2(elg: elg, maxConcurrentStreams: 100) else {
            return XCTFail("Test setup failed")
        }

        let connection = connections.randomParkedConnection()!
        XCTAssertNoThrow(try connections.closeConnection(connection))

        let idleTimeoutAction = state.connectionIdleTimeout(connection.id, on: connection.eventLoop)
        XCTAssertEqual(idleTimeoutAction.connection, .closeConnection(connection, isShutdown: .no))
        XCTAssertEqual(idleTimeoutAction.request, .none)

        XCTAssertEqual(state.newHTTP2MaxConcurrentStreamsReceived(connection.id, newMaxStreams: 50), .none)
        XCTAssertEqual(state.http2ConnectionGoAwayReceived(connection.id), .none)

        XCTAssertEqual(state.http2ConnectionClosed(connection.id), .none)
    }

    func testFailConnectionRacesAgainstConnectionCreationFailed() {
        let elg = EmbeddedEventLoopGroup(loops: 4)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }

        var state = HTTPConnectionPool.StateMachine(
            idGenerator: .init(),
            maximumConcurrentHTTP1Connections: 2,
            retryConnectionEstablishment: true,
            preferHTTP1: false,
            maximumConnectionUses: nil,
            preWarmedHTTP1ConnectionCount: 0
        )

        let mockRequest = MockHTTPScheduableRequest(eventLoop: elg.next())
        let request = HTTPConnectionPool.Request(mockRequest)

        let executeAction = state.executeRequest(request)
        XCTAssertEqual(.scheduleRequestTimeout(for: request, on: mockRequest.eventLoop), executeAction.request)

        // 1. connection attempt
        guard case .createConnection(let connectionID, on: let connectionEL) = executeAction.connection else {
            return XCTFail("Unexpected connection action: \(executeAction.connection)")
        }
        XCTAssert(connectionEL === mockRequest.eventLoop)  // XCTAssertIdentical not available on Linux

        // 2. connection fails – first with closed callback

        XCTAssertEqual(state.http2ConnectionClosed(connectionID), .none)

        // 3. connection fails – with make connection callback

        let action = state.failedToCreateNewConnection(
            IOError(errnoCode: -1, reason: "Test failure"),
            connectionID: connectionID
        )
        XCTAssertEqual(action.request, .none)
        guard case .scheduleBackoffTimer(connectionID, _, on: let backoffTimerEL) = action.connection else {
            XCTFail("Unexpected connection action: \(action.connection)")
            return
        }
        XCTAssertIdentical(connectionEL, backoffTimerEL)
    }

}

/// Should be used if you have a value of statically unknown type and want to compare its value to another `Equatable` value.
/// The assert will fail if both values don't have the same type or don't have the same value.
/// - Note: if the type of both values are statically know, prefer `XCTAssertEqual`.
/// - Parameters:
///   - lhs: value of a statically unknown type
///   - rhs: value of statically known and `Equatable` type
func XCTAssertEqualTypeAndValue<Left, Right: Equatable>(
    _ lhs: @autoclosure () throws -> Left,
    _ rhs: @autoclosure () throws -> Right,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertNoThrow(
        try {
            let lhs = try lhs()
            let rhs = try rhs()
            guard let lhsAsRhs = lhs as? Right else {
                XCTFail("could not cast \(lhs) of type \(type(of: lhs)) to \(type(of: rhs))", file: file, line: line)
                return
            }
            XCTAssertEqual(lhsAsRhs, rhs, file: file, line: line)
        }(),
        file: file,
        line: line
    )
}
