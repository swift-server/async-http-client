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
        var state = HTTPConnectionPool.HTTP2StateMaschine(idGenerator: .init())

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

        var state = HTTPConnectionPool.HTTP2StateMaschine(
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

        var state = HTTPConnectionPool.HTTP2StateMaschine(
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
}
