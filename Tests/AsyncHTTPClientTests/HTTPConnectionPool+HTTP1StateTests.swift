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

class HTTPConnectionPool_HTTP1StateMachineTests: XCTestCase {
    func testCreatingAndFailingConnections() {
        struct SomeError: Error, Equatable {}
        let elg = EmbeddedEventLoopGroup(loops: 4)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }

        var state = HTTPConnectionPool.StateMachine(
            idGenerator: .init(),
            maximumConcurrentHTTP1Connections: 8,
            retryConnectionEstablishment: true,
            preferHTTP1: true,
            maximumConnectionUses: nil,
            preWarmedHTTP1ConnectionCount: 0
        )

        var connections = MockConnectionPool()
        var queuer = MockRequestQueuer()

        // for the first eight requests, the pool should try to create new connections.

        for _ in 0..<8 {
            let mockRequest = MockHTTPScheduableRequest(eventLoop: elg.next())
            let request = HTTPConnectionPool.Request(mockRequest)
            let action = state.executeRequest(request)
            guard case .createConnection(let connectionID, let connectionEL) = action.connection else {
                return XCTFail("Unexpected connection action")
            }
            XCTAssertEqual(.scheduleRequestTimeout(for: request, on: mockRequest.eventLoop), action.request)
            XCTAssert(connectionEL === mockRequest.eventLoop)

            XCTAssertNoThrow(try connections.createConnection(connectionID, on: connectionEL))
            XCTAssertNoThrow(try queuer.queue(mockRequest, id: request.id))
        }

        // the next eight requests should only be queued.

        for _ in 0..<8 {
            let mockRequest = MockHTTPScheduableRequest(eventLoop: elg.next())
            let request = HTTPConnectionPool.Request(mockRequest)
            let action = state.executeRequest(request)
            guard case .none = action.connection else {
                return XCTFail("Unexpected connection action")
            }
            XCTAssertEqual(.scheduleRequestTimeout(for: request, on: mockRequest.eventLoop), action.request)
            XCTAssertNoThrow(try queuer.queue(mockRequest, id: request.id))
        }

        // timeout all queued requests except for two

        // fail all connection attempts
        while let randomConnectionID = connections.randomStartingConnection() {
            XCTAssertNoThrow(try connections.failConnectionCreation(randomConnectionID))
            let action = state.failedToCreateNewConnection(SomeError(), connectionID: randomConnectionID)

            // After a failed connection attempt, must not fail a request. Instead we should retry
            // to create the connection with a backoff and a small jitter. The request should only
            // be failed, once the connection setup timeout is hit or the request reaches it
            // deadline.

            XCTAssertEqual(action.request, .none)

            guard case .scheduleBackoffTimer(randomConnectionID, backoff: _, on: _) = action.connection else {
                return XCTFail("Unexpected request action: \(action.request)")
            }

            XCTAssertNoThrow(try connections.startConnectionBackoffTimer(randomConnectionID))
        }

        // cancel all queued requests
        while let request = queuer.timeoutRandomRequest() {
            let cancelAction = state.cancelRequest(request.0)
            XCTAssertEqual(cancelAction.connection, .none)
            XCTAssertEqual(cancelAction.request, .failRequest(.init(request.1), SomeError(), cancelTimeout: true))
        }

        // connection backoff done
        while let connectionID = connections.randomBackingOffConnection() {
            XCTAssertNoThrow(try connections.connectionBackoffTimerDone(connectionID))
            let backoffAction = state.connectionCreationBackoffDone(connectionID)
            XCTAssertEqual(backoffAction.connection, .none)
            XCTAssertEqual(backoffAction.request, .none)
        }

        XCTAssert(queuer.isEmpty)
        XCTAssert(connections.isEmpty)
    }

    func testCreatingAndFailingConnectionsWithoutRetry() {
        struct SomeError: Error, Equatable {}
        let elg = EmbeddedEventLoopGroup(loops: 4)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }

        var state = HTTPConnectionPool.StateMachine(
            idGenerator: .init(),
            maximumConcurrentHTTP1Connections: 8,
            retryConnectionEstablishment: false,
            preferHTTP1: true,
            maximumConnectionUses: nil,
            preWarmedHTTP1ConnectionCount: 0
        )

        var connections = MockConnectionPool()
        var queuer = MockRequestQueuer()

        // for the first eight requests, the pool should try to create new connections.

        for _ in 0..<8 {
            let mockRequest = MockHTTPScheduableRequest(eventLoop: elg.next())
            let request = HTTPConnectionPool.Request(mockRequest)
            let action = state.executeRequest(request)
            guard case .createConnection(let connectionID, let connectionEL) = action.connection else {
                return XCTFail("Unexpected connection action")
            }
            XCTAssertEqual(.scheduleRequestTimeout(for: request, on: mockRequest.eventLoop), action.request)
            XCTAssert(connectionEL === mockRequest.eventLoop)

            XCTAssertNoThrow(try connections.createConnection(connectionID, on: connectionEL))
            XCTAssertNoThrow(try queuer.queue(mockRequest, id: request.id))
        }

        // the next eight requests should only be queued.

        for _ in 0..<8 {
            let mockRequest = MockHTTPScheduableRequest(eventLoop: elg.next())
            let request = HTTPConnectionPool.Request(mockRequest)
            let action = state.executeRequest(request)
            guard case .none = action.connection else {
                return XCTFail("Unexpected connection action")
            }
            XCTAssertEqual(.scheduleRequestTimeout(for: request, on: mockRequest.eventLoop), action.request)
            XCTAssertNoThrow(try queuer.queue(mockRequest, id: request.id))
        }

        // the first failure should cancel all requests because we have disabled connection establishtment retry
        let randomConnectionID = connections.randomStartingConnection()!
        XCTAssertNoThrow(try connections.failConnectionCreation(randomConnectionID))
        let action = state.failedToCreateNewConnection(SomeError(), connectionID: randomConnectionID)
        XCTAssertEqual(action.connection, .none)
        guard case .failRequestsAndCancelTimeouts(let requestsToFail, let requestError) = action.request else {
            return XCTFail("Unexpected request action: \(action.request)")
        }
        XCTAssertEqualTypeAndValue(requestError, SomeError())
        for requestToFail in requestsToFail {
            XCTAssertNoThrow(try queuer.fail(requestToFail.id, request: requestToFail.__testOnly_wrapped_request()))
        }

        // all requests have been canceled and therefore nothing should happen if a connection fails
        while let randomConnectionID = connections.randomStartingConnection() {
            XCTAssertNoThrow(try connections.failConnectionCreation(randomConnectionID))
            let action = state.failedToCreateNewConnection(SomeError(), connectionID: randomConnectionID)

            XCTAssertEqual(action, .none)
        }

        XCTAssert(queuer.isEmpty)
        XCTAssert(connections.isEmpty)
    }

    func testConnectionFailureBackoff() {
        let elg = EmbeddedEventLoopGroup(loops: 4)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }

        var state = HTTPConnectionPool.StateMachine(
            idGenerator: .init(),
            maximumConcurrentHTTP1Connections: 2,
            retryConnectionEstablishment: true,
            preferHTTP1: true,
            maximumConnectionUses: nil,
            preWarmedHTTP1ConnectionCount: 0
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

    func testCancelRequestWorks() {
        let elg = EmbeddedEventLoopGroup(loops: 4)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }

        var state = HTTPConnectionPool.StateMachine(
            idGenerator: .init(),
            maximumConcurrentHTTP1Connections: 2,
            retryConnectionEstablishment: true,
            preferHTTP1: true,
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

        // 2. cancel request

        let cancelAction = state.cancelRequest(request.id)
        XCTAssertEqual(cancelAction.request, .failRequest(request, HTTPClientError.cancelled, cancelTimeout: true))
        XCTAssertEqual(cancelAction.connection, .none)

        // 3. request timeout triggers to late
        XCTAssertEqual(state.timeoutRequest(request.id), .none, "To late timeout is ignored")

        // 4. succeed connection attempt
        let connectedAction = state.newHTTP1ConnectionCreated(
            .__testOnly_connection(id: connectionID, eventLoop: connectionEL)
        )
        XCTAssertEqual(connectedAction.request, .none, "Request must not be executed")
        XCTAssertEqual(connectedAction.connection, .scheduleTimeoutTimer(connectionID, on: connectionEL))
    }

    func testExecuteOnShuttingDownPool() {
        let elg = EmbeddedEventLoopGroup(loops: 4)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }

        var state = HTTPConnectionPool.StateMachine(
            idGenerator: .init(),
            maximumConcurrentHTTP1Connections: 2,
            retryConnectionEstablishment: true,
            preferHTTP1: true,
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

        // 2. connection succeeds
        let connection: HTTPConnectionPool.Connection = .__testOnly_connection(
            id: connectionID,
            eventLoop: connectionEL
        )
        let connectedAction = state.newHTTP1ConnectionCreated(connection)
        guard case .executeRequest(request, connection, cancelTimeout: true) = connectedAction.request else {
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
        let closeAction = state.http1ConnectionClosed(connectionID)
        XCTAssertEqual(closeAction.connection, .cleanupConnections(.init(), isShutdown: .yes(unclean: true)))
        XCTAssertEqual(closeAction.request, .none)
    }

    func testRequestsAreQueuedIfAllConnectionsAreInUseAndRequestsAreDequeuedInOrder() {
        let elg = EmbeddedEventLoopGroup(loops: 4)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }

        guard var (connections, state) = try? MockConnectionPool.http1(elg: elg, numberOfConnections: 8) else {
            return XCTFail("Test setup failed")
        }

        XCTAssertEqual(connections.parked, 8)

        // Add eight requests to fill all connections
        for _ in 0..<8 {
            let eventLoop = elg.next()
            guard
                let expectedConnection = connections.newestParkedConnection(for: eventLoop)
                    ?? connections.newestParkedConnection
            else {
                return XCTFail("Expected to still have connections available")
            }

            let mockRequest = MockHTTPScheduableRequest(eventLoop: eventLoop)
            let request = HTTPConnectionPool.Request(mockRequest)
            let action = state.executeRequest(request)

            XCTAssertEqual(action.connection, .cancelTimeoutTimer(expectedConnection.id))
            guard case .executeRequest(let returnedRequest, expectedConnection, cancelTimeout: false) = action.request
            else {
                return XCTFail("Expected to execute a request next, but got: \(action.request)")
            }

            XCTAssert(mockRequest === returnedRequest.__testOnly_wrapped_request())

            XCTAssertNoThrow(try connections.activateConnection(expectedConnection.id))
            XCTAssertNoThrow(try connections.execute(mockRequest, on: expectedConnection))
        }

        // Add 100 requests to fill request queue
        var queuedRequestsOrder = CircularBuffer<MockRequestQueuer.RequestID>()
        var queuer = MockRequestQueuer()
        for _ in 0..<100 {
            let eventLoop = elg.next()
            let mockRequest = MockHTTPScheduableRequest(eventLoop: eventLoop, requiresEventLoopForChannel: false)
            let request = HTTPConnectionPool.Request(mockRequest)
            let action = state.executeRequest(request)

            XCTAssertEqual(action.connection, .none)
            XCTAssertEqual(.scheduleRequestTimeout(for: request, on: mockRequest.eventLoop), action.request)

            XCTAssertNoThrow(try queuer.queue(mockRequest, id: request.id))
            queuedRequestsOrder.append(request.id)
        }

        while let connection = connections.randomLeasedConnection() {
            XCTAssertNoThrow(try connections.finishExecution(connection.id))
            let action = state.http1ConnectionReleased(connection.id)

            switch action.connection {
            case .scheduleTimeoutTimer(connection.id, on: let timerEL):
                // if all queued requests are processed, the connection will be parked
                XCTAssert(queuedRequestsOrder.isEmpty)
                XCTAssertEqual(action.request, .none)
                XCTAssert(connection.eventLoop === timerEL)
                XCTAssertNoThrow(try connections.parkConnection(connection.id))
            case .none:
                guard case .executeRequest(let request, connection, cancelTimeout: true) = action.request else {
                    return XCTFail("Unexpected request action: \(action.request)")
                }
                XCTAssertEqual(request.id, queuedRequestsOrder.popFirst())
                let mockRequest = request.__testOnly_wrapped_request()
                XCTAssertNoThrow(try connections.execute(queuer.get(request.id, request: mockRequest), on: connection))

            default:
                XCTFail("Unexpected connection action: \(action)")
            }
        }

        XCTAssertEqual(connections.parked, 8)
        XCTAssert(queuer.isEmpty)
    }

    func testBestConnectionIsPicked() {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 64)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }

        guard var (connections, state) = try? MockConnectionPool.http1(elg: elg, numberOfConnections: 8) else {
            return XCTFail("Test setup failed")
        }

        for index in 1...300 {
            // Every iteration we start with eight parked connections
            XCTAssertEqual(connections.parked, 8)

            var reqEventLoop: EventLoop = elg.next()
            for _ in 0..<((0..<63).randomElement()!) {
                // pick a random eventLoop for the next request
                reqEventLoop = elg.next()
            }

            // 10% of the cases enforce the eventLoop
            let elRequired = (0..<10).randomElement().flatMap { $0 == 0 ? true : false }!
            let mockRequest = MockHTTPScheduableRequest(
                eventLoop: reqEventLoop,
                requiresEventLoopForChannel: elRequired
            )
            let request = HTTPConnectionPool.Request(mockRequest)

            let action = state.executeRequest(request)

            switch action.connection {
            case .createConnection(let connectionID, on: let connEventLoop):
                XCTAssertTrue(elRequired)
                XCTAssertNil(connections.newestParkedConnection(for: reqEventLoop))
                XCTAssert(connEventLoop === reqEventLoop)
                XCTAssertEqual(action.request, .scheduleRequestTimeout(for: request, on: reqEventLoop))

                let connection: HTTPConnectionPool.Connection = .__testOnly_connection(
                    id: connectionID,
                    eventLoop: connEventLoop
                )
                let createdAction = state.newHTTP1ConnectionCreated(connection)
                XCTAssertEqual(createdAction.request, .executeRequest(request, connection, cancelTimeout: true))
                XCTAssertEqual(createdAction.connection, .none)

                let doneAction = state.http1ConnectionReleased(connectionID)
                XCTAssertEqual(doneAction.request, .none)
                XCTAssertEqual(doneAction.connection, .closeConnection(connection, isShutdown: .no))
                XCTAssertEqual(state.http1ConnectionClosed(connectionID), .none)

            case .cancelTimeoutTimer(let connectionID):
                guard
                    let expectedConnection = connections.newestParkedConnection(for: reqEventLoop)
                        ?? connections.newestParkedConnection
                else {
                    return XCTFail("Expected to have connections available")
                }

                if elRequired {
                    XCTAssert(expectedConnection.eventLoop === reqEventLoop)
                }

                XCTAssertEqual(
                    connectionID,
                    expectedConnection.id,
                    "Request is scheduled on the connection we expected"
                )
                XCTAssertNoThrow(try connections.activateConnection(connectionID))

                guard case .executeRequest(let request, let connection, cancelTimeout: false) = action.request else {
                    return XCTFail("Expected to execute a request, but got: \(action.request)")
                }
                XCTAssertEqual(connection, expectedConnection)
                XCTAssertNoThrow(try connections.execute(request.__testOnly_wrapped_request(), on: connection))
                XCTAssertNoThrow(try connections.finishExecution(connection.id))

                XCTAssertEqual(
                    state.http1ConnectionReleased(connection.id),
                    .init(request: .none, connection: .scheduleTimeoutTimer(connection.id, on: connection.eventLoop))
                )
                XCTAssertNoThrow(try connections.parkConnection(connectionID))

            default:
                XCTFail("Unexpected connection action in iteration \(index): \(action.connection)")
            }
        }

        XCTAssertEqual(connections.parked, 8)
    }

    func testConnectionAbortIsIgnoredIfThereAreNoQueuedRequests() {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }

        guard var (connections, state) = try? MockConnectionPool.http1(elg: elg, numberOfConnections: 8) else {
            return XCTFail("Test setup failed")
        }

        XCTAssertEqual(connections.parked, 8)

        // close a leased connection == abort
        let mockRequest = MockHTTPScheduableRequest(eventLoop: elg.next())
        let request = HTTPConnectionPool.Request(mockRequest)
        guard let connectionToAbort = connections.newestParkedConnection else {
            return XCTFail("Expected to have a parked connection")
        }
        let action = state.executeRequest(request)
        XCTAssertEqual(action.connection, .cancelTimeoutTimer(connectionToAbort.id))
        XCTAssertNoThrow(try connections.activateConnection(connectionToAbort.id))
        XCTAssertEqual(action.request, .executeRequest(request, connectionToAbort, cancelTimeout: false))
        XCTAssertNoThrow(try connections.execute(mockRequest, on: connectionToAbort))
        XCTAssertEqual(connections.parked, 7)
        XCTAssertEqual(connections.used, 1)
        XCTAssertNoThrow(try connections.abortConnection(connectionToAbort.id))
        XCTAssertEqual(state.http1ConnectionClosed(connectionToAbort.id), .none)
        XCTAssertEqual(connections.parked, 7)
        XCTAssertEqual(connections.used, 0)
    }

    func testConnectionCloseLeadsToTumbleWeedIfThereNoQueuedRequests() {
        let elg = EmbeddedEventLoopGroup(loops: 1)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }

        guard var (connections, state) = try? MockConnectionPool.http1(elg: elg, numberOfConnections: 8) else {
            return XCTFail("Test setup failed")
        }

        XCTAssertEqual(connections.parked, 8)

        // close a parked connection
        guard let connectionToClose = connections.randomParkedConnection() else {
            return XCTFail("Expected to have a parked connection")
        }
        XCTAssertNoThrow(try connections.closeConnection(connectionToClose))
        XCTAssertEqual(state.http1ConnectionClosed(connectionToClose.id), .none)
        XCTAssertEqual(connections.parked, 7)
    }

    func testConnectionAbortLeadsToNewConnectionsIfThereAreQueuedRequests() {
        let elg = EmbeddedEventLoopGroup(loops: 8)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }

        guard var (connections, state) = try? MockConnectionPool.http1(elg: elg, numberOfConnections: 8) else {
            return XCTFail("Test setup failed")
        }

        XCTAssertEqual(connections.parked, 8)

        // Add eight requests to fill all connections
        for _ in 0..<8 {
            let eventLoop = elg.next()
            guard
                let expectedConnection = connections.newestParkedConnection(for: eventLoop)
                    ?? connections.newestParkedConnection
            else {
                return XCTFail("Expected to still have connections available")
            }

            let mockRequest = MockHTTPScheduableRequest(eventLoop: eventLoop)
            let request = HTTPConnectionPool.Request(mockRequest)
            let action = state.executeRequest(request)

            XCTAssertEqual(action.connection, .cancelTimeoutTimer(expectedConnection.id))
            XCTAssertEqual(action.request, .executeRequest(request, expectedConnection, cancelTimeout: false))

            XCTAssertNoThrow(try connections.activateConnection(expectedConnection.id))
            XCTAssertNoThrow(try connections.execute(mockRequest, on: expectedConnection))
        }

        // Add 100 requests to fill request queue
        var queuedRequestsOrder = CircularBuffer<MockRequestQueuer.RequestID>()
        var queuer = MockRequestQueuer()
        for _ in 0..<100 {
            let eventLoop = elg.next()

            let mockRequest = MockHTTPScheduableRequest(eventLoop: eventLoop, requiresEventLoopForChannel: false)
            let request = HTTPConnectionPool.Request(mockRequest)
            let action = state.executeRequest(request)

            XCTAssertEqual(.none, action.connection)
            XCTAssertEqual(.scheduleRequestTimeout(for: request, on: mockRequest.eventLoop), action.request)
            XCTAssertNoThrow(try queuer.queue(mockRequest, id: request.id))
            queuedRequestsOrder.append(request.id)
        }

        while let closedConnection = connections.randomLeasedConnection() {
            XCTAssertNoThrow(try connections.abortConnection(closedConnection.id))
            XCTAssertEqual(connections.parked, 0)
            let action = state.http1ConnectionClosed(closedConnection.id)

            switch action.connection {
            case .createConnection(let newConnectionID, on: let eventLoop):
                XCTAssertEqual(action.request, .none)
                XCTAssertNoThrow(try connections.createConnection(newConnectionID, on: eventLoop))
                XCTAssertEqual(connections.starting, 1)

                var maybeNewConnection: HTTPConnectionPool.Connection?
                XCTAssertNoThrow(maybeNewConnection = try connections.succeedConnectionCreationHTTP1(newConnectionID))
                guard let newConnection = maybeNewConnection else { return XCTFail("Expected to get a new connection") }
                let afterRecreationAction = state.newHTTP1ConnectionCreated(newConnection)
                XCTAssertEqual(afterRecreationAction.connection, .none)
                guard
                    case .executeRequest(let request, newConnection, cancelTimeout: true) = afterRecreationAction
                        .request
                else {
                    return XCTFail("Unexpected request action: \(action.request)")
                }

                XCTAssertEqual(request.id, queuedRequestsOrder.popFirst())
                XCTAssertNoThrow(
                    try connections.execute(
                        queuer.get(request.id, request: request.__testOnly_wrapped_request()),
                        on: newConnection
                    )
                )

            case .none:
                XCTAssert(queuer.isEmpty)
            default:
                XCTFail("Unexpected connection action: \(action.connection)")
            }
        }
    }

    func testParkedConnectionTimesOut() {
        let elg = EmbeddedEventLoopGroup(loops: 1)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }

        guard var (connections, state) = try? MockConnectionPool.http1(elg: elg, numberOfConnections: 1) else {
            return XCTFail("Test setup failed")
        }

        guard let connection = connections.randomParkedConnection() else {
            return XCTFail("Expected to have one parked connection")
        }

        let action = state.connectionIdleTimeout(connection.id, on: connection.eventLoop)
        XCTAssertEqual(action.connection, .closeConnection(connection, isShutdown: .no))
        XCTAssertEqual(action.request, .none)
        XCTAssertNoThrow(try connections.closeConnection(connection))
    }

    func testConnectionPoolFullOfParkedConnectionsIsShutdownImmediately() {
        let elg = EmbeddedEventLoopGroup(loops: 8)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }

        guard var (connections, state) = try? MockConnectionPool.http1(elg: elg, numberOfConnections: 8) else {
            return XCTFail("Test setup failed")
        }

        XCTAssertEqual(connections.parked, 8)
        let action = state.shutdown()
        XCTAssertEqual(.none, action.request)

        guard case .cleanupConnections(let closeContext, isShutdown: .yes(unclean: false)) = action.connection else {
            return XCTFail("Unexpected connection event: \(action.connection)")
        }

        XCTAssertEqual(closeContext.close.count, 8)

        for connection in closeContext.close {
            XCTAssertNoThrow(try connections.closeConnection(connection))
        }

        XCTAssertEqual(connections.count, 0)
    }

    func testParkedConnectionTimesOutButIsAlsoClosedByRemote() {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }

        guard var (connections, state) = try? MockConnectionPool.http1(elg: elg, numberOfConnections: 1) else {
            return XCTFail("Test setup failed")
        }

        guard let connection = connections.randomParkedConnection() else {
            return XCTFail("Expected to have one parked connection")
        }

        // triggered by remote peer
        XCTAssertNoThrow(try connections.abortConnection(connection.id))
        XCTAssertEqual(state.http1ConnectionClosed(connection.id), .none)

        // triggered by timer
        XCTAssertEqual(state.connectionIdleTimeout(connection.id, on: connection.eventLoop), .none)
    }

    func testConnectionBackoffVsShutdownRace() {
        let elg = EmbeddedEventLoopGroup(loops: 2)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }

        var state = HTTPConnectionPool.StateMachine(
            idGenerator: .init(),
            maximumConcurrentHTTP1Connections: 6,
            retryConnectionEstablishment: true,
            preferHTTP1: true,
            maximumConnectionUses: nil,
            preWarmedHTTP1ConnectionCount: 0
        )

        let mockRequest = MockHTTPScheduableRequest(eventLoop: elg.next(), requiresEventLoopForChannel: false)
        let request = HTTPConnectionPool.Request(mockRequest)

        let executeAction = state.executeRequest(request)
        guard case .createConnection(let connectionID, on: let connEL) = executeAction.connection else {
            return XCTFail("Expected to create a connection")
        }

        XCTAssertEqual(executeAction.request, .scheduleRequestTimeout(for: request, on: mockRequest.eventLoop))

        let failAction = state.failedToCreateNewConnection(HTTPClientError.cancelled, connectionID: connectionID)
        guard case .scheduleBackoffTimer(connectionID, backoff: _, on: let timerEL) = failAction.connection else {
            return XCTFail("Expected to create a backoff timer")
        }
        XCTAssert(timerEL === connEL)
        XCTAssertEqual(failAction.request, .none)

        let shutdownAction = state.shutdown()
        guard case .cleanupConnections(let context, isShutdown: .yes(unclean: true)) = shutdownAction.connection else {
            return XCTFail("Expected to cleanup")
        }
        XCTAssertEqual(context.close.count, 0)
        XCTAssertEqual(context.cancel.count, 0)
        XCTAssertEqual(context.connectBackoff, [connectionID])
        XCTAssertEqual(shutdownAction.request, .failRequestsAndCancelTimeouts([request], HTTPClientError.cancelled))

        XCTAssertEqual(state.connectionCreationBackoffDone(connectionID), .none)
    }

    func testRequestThatTimesOutIsFailedWithLastConnectionCreationError() {
        let elg = EmbeddedEventLoopGroup(loops: 1)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }

        var state = HTTPConnectionPool.StateMachine(
            idGenerator: .init(),
            maximumConcurrentHTTP1Connections: 6,
            retryConnectionEstablishment: true,
            preferHTTP1: true,
            maximumConnectionUses: nil,
            preWarmedHTTP1ConnectionCount: 0
        )

        let mockRequest = MockHTTPScheduableRequest(eventLoop: elg.next(), requiresEventLoopForChannel: false)
        let request = HTTPConnectionPool.Request(mockRequest)

        let executeAction = state.executeRequest(request)
        guard case .createConnection(let connectionID, on: let connEL) = executeAction.connection else {
            return XCTFail("Expected to create a connection")
        }

        XCTAssertEqual(executeAction.request, .scheduleRequestTimeout(for: request, on: mockRequest.eventLoop))

        let failAction = state.failedToCreateNewConnection(
            HTTPClientError.httpProxyHandshakeTimeout,
            connectionID: connectionID
        )
        guard case .scheduleBackoffTimer(connectionID, backoff: _, on: let timerEL) = failAction.connection else {
            return XCTFail("Expected to create a backoff timer")
        }
        XCTAssert(timerEL === connEL)
        XCTAssertEqual(failAction.request, .none)

        let timeoutAction = state.timeoutRequest(request.id)
        XCTAssertEqual(
            timeoutAction.request,
            .failRequest(request, HTTPClientError.httpProxyHandshakeTimeout, cancelTimeout: false)
        )
        XCTAssertEqual(timeoutAction.connection, .none)
    }

    func testRequestThatTimesOutBeforeAConnectionIsEstablishedIsFailedWithConnectTimeoutError() {
        let eventLoop = EmbeddedEventLoop()
        defer { XCTAssertNoThrow(try eventLoop.syncShutdownGracefully()) }

        var state = HTTPConnectionPool.StateMachine(
            idGenerator: .init(),
            maximumConcurrentHTTP1Connections: 6,
            retryConnectionEstablishment: true,
            preferHTTP1: true,
            maximumConnectionUses: nil,
            preWarmedHTTP1ConnectionCount: 0
        )

        let mockRequest = MockHTTPScheduableRequest(eventLoop: eventLoop.next(), requiresEventLoopForChannel: false)
        let request = HTTPConnectionPool.Request(mockRequest)

        let executeAction = state.executeRequest(request)
        guard case .createConnection(_, on: _) = executeAction.connection else {
            return XCTFail("Expected to create a connection")
        }
        XCTAssertEqual(executeAction.request, .scheduleRequestTimeout(for: request, on: mockRequest.eventLoop))

        let timeoutAction = state.timeoutRequest(request.id)
        XCTAssertEqual(
            timeoutAction.request,
            .failRequest(request, HTTPClientError.connectTimeout, cancelTimeout: false)
        )
        XCTAssertEqual(timeoutAction.connection, .none)
    }

    func testRequestThatTimesOutAfterAConnectionWasEstablishedSuccessfullyTimesOutWithGenericError() {
        let elg = EmbeddedEventLoopGroup(loops: 1)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }

        var state = HTTPConnectionPool.StateMachine(
            idGenerator: .init(),
            maximumConcurrentHTTP1Connections: 6,
            retryConnectionEstablishment: true,
            preferHTTP1: true,
            maximumConnectionUses: nil,
            preWarmedHTTP1ConnectionCount: 0
        )

        let mockRequest1 = MockHTTPScheduableRequest(eventLoop: elg.next(), requiresEventLoopForChannel: false)
        let request1 = HTTPConnectionPool.Request(mockRequest1)

        let executeAction1 = state.executeRequest(request1)
        guard case .createConnection(let connectionID1, on: let connEL1) = executeAction1.connection else {
            return XCTFail("Expected to create a connection")
        }
        XCTAssert(mockRequest1.eventLoop === connEL1)

        XCTAssertEqual(executeAction1.request, .scheduleRequestTimeout(for: request1, on: mockRequest1.eventLoop))

        let mockRequest2 = MockHTTPScheduableRequest(eventLoop: elg.next(), requiresEventLoopForChannel: false)
        let request2 = HTTPConnectionPool.Request(mockRequest2)

        let executeAction2 = state.executeRequest(request2)
        guard case .createConnection(let connectionID2, on: let connEL2) = executeAction2.connection else {
            return XCTFail("Expected to create a connection")
        }
        XCTAssert(mockRequest2.eventLoop === connEL2)

        XCTAssertEqual(executeAction2.request, .scheduleRequestTimeout(for: request2, on: connEL1))

        let failAction = state.failedToCreateNewConnection(
            HTTPClientError.httpProxyHandshakeTimeout,
            connectionID: connectionID1
        )
        guard case .scheduleBackoffTimer(connectionID1, backoff: _, on: let timerEL) = failAction.connection else {
            return XCTFail("Expected to create a backoff timer")
        }
        XCTAssert(timerEL === connEL2)
        XCTAssertEqual(failAction.request, .none)

        let conn2 = HTTPConnectionPool.Connection.__testOnly_connection(id: connectionID2, eventLoop: connEL2)
        let createdAction = state.newHTTP1ConnectionCreated(conn2)

        XCTAssertEqual(createdAction.request, .executeRequest(request1, conn2, cancelTimeout: true))
        XCTAssertEqual(createdAction.connection, .none)

        let timeoutAction = state.timeoutRequest(request2.id)
        XCTAssertEqual(
            timeoutAction.request,
            .failRequest(request2, HTTPClientError.getConnectionFromPoolTimeout, cancelTimeout: false)
        )
        XCTAssertEqual(timeoutAction.connection, .none)
    }

    func testPrewarmingSimpleFlow() throws {
        let elg = EmbeddedEventLoopGroup(loops: 4)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }

        var state = HTTPConnectionPool.StateMachine(
            idGenerator: .init(),
            maximumConcurrentHTTP1Connections: 8,
            retryConnectionEstablishment: true,
            preferHTTP1: true,
            maximumConnectionUses: nil,
            preWarmedHTTP1ConnectionCount: 4
        )

        var connectionIDs = [HTTPConnectionPool.Connection.ID]()
        var connections = MockConnectionPool()

        // attempt to send one request.
        let mockRequest = MockHTTPScheduableRequest(eventLoop: elg.next())
        let request = HTTPConnectionPool.Request(mockRequest)
        var action = state.executeRequest(request)
        guard case .createConnection(var connectionID, var connectionEL) = action.connection else {
            return XCTFail("Unexpected connection action")
        }
        connectionIDs.append(connectionID)
        XCTAssertEqual(.scheduleRequestTimeout(for: request, on: mockRequest.eventLoop), action.request)

        XCTAssertNoThrow(try connections.createConnection(connectionID, on: connectionEL))

        // We're going to end up creating 5 connections immediately, even though only one is leased: the other 4 are pre-warmed.
        for connectionIndex in 0..<5 {
            let conn = try connections.succeedConnectionCreationHTTP1(connectionID)
            let createdAction = state.newHTTP1ConnectionCreated(conn)

            switch createdAction.request {
            case .executeRequest(_, let connection, _):
                try connections.execute(mockRequest, on: connection)
            case .none:
                try connections.parkConnection(connectionID)
            default:
                return XCTFail(
                    "Unexpected request action \(createdAction.request), connection index: \(connectionIndex)"
                )
            }

            if connectionIndex == 0,
                case .createConnection(let newConnectionID, let newConnectionEL) = createdAction.connection
            {
                (connectionID, connectionEL) = (newConnectionID, newConnectionEL)
                connectionIDs.append(connectionID)
                XCTAssertNoThrow(try connections.createConnection(connectionID, on: connectionEL))
            } else if connectionIndex < 4,
                case .scheduleTimeoutTimerAndCreateConnection(let timeoutID, let newConnectionID, let newConnectionEL) =
                    createdAction.connection
            {
                XCTAssertEqual(connectionID, timeoutID)
                (connectionID, connectionEL) = (newConnectionID, newConnectionEL)
                connectionIDs.append(connectionID)
                XCTAssertNoThrow(try connections.createConnection(connectionID, on: connectionEL))
            } else if connectionIndex == 4, case .scheduleTimeoutTimer = createdAction.connection {
                // Expected, the loop will terminate now.
                ()
            } else {
                return XCTFail(
                    "Unexpected connection action: \(createdAction.connection) with index \(connectionIndex)"
                )
            }
        }

        XCTAssertEqual(connections.count, 5)
        XCTAssertEqual(connections.parked, 4)
        XCTAssertEqual(connectionIDs.count, 5)

        // Now we complete the first request.
        try connections.finishExecution(connectionIDs[0])
        action = state.http1ConnectionReleased(connectionIDs[0])
        guard case .scheduleTimeoutTimer = action.connection else {
            return XCTFail("Unexpected action: \(action.connection)")
        }
        try connections.parkConnection(connectionIDs[0])

        XCTAssertEqual(connections.count, 5)
        XCTAssertEqual(connections.parked, 5)
        XCTAssertEqual(connectionIDs.count, 5)
    }

    func testPrewarmingCreatesUpToTheMax() throws {
        let elg = EmbeddedEventLoopGroup(loops: 4)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }

        var state = HTTPConnectionPool.StateMachine(
            idGenerator: .init(),
            maximumConcurrentHTTP1Connections: 8,
            retryConnectionEstablishment: true,
            preferHTTP1: true,
            maximumConnectionUses: nil,
            preWarmedHTTP1ConnectionCount: 4
        )

        var connections = MockConnectionPool()

        // Attempt to send one request. Complete the connection creation immediately, deferring the next connection creation, and then complete the
        // request.
        let mockRequest = MockHTTPScheduableRequest(eventLoop: elg.next())
        let request = HTTPConnectionPool.Request(mockRequest)
        var action = state.executeRequest(request)
        guard case .createConnection(var connectionID, var connectionEL) = action.connection else {
            return XCTFail("Unexpected connection action")
        }
        XCTAssertEqual(.scheduleRequestTimeout(for: request, on: mockRequest.eventLoop), action.request)

        XCTAssertNoThrow(try connections.createConnection(connectionID, on: connectionEL))
        var conn = try connections.succeedConnectionCreationHTTP1(connectionID)
        var createdAction = state.newHTTP1ConnectionCreated(conn)
        guard case .createConnection(var newConnectionID, var newConnectionEL) = createdAction.connection else {
            return XCTFail("Unexpected connection action")
        }
        try connections.execute(mockRequest, on: conn)
        try connections.finishExecution(connectionID)
        action = state.http1ConnectionReleased(connectionID)

        // Here the state machine has _again_ asked us to create a connection. This is because the pre-warming
        // phase takes any opportunity to do that.
        guard
            case .scheduleTimeoutTimerAndCreateConnection(_, let veryDelayedConnectionID, let veryDelayedLoop) = action
                .connection
        else {
            return XCTFail("Unexpected action: \(action.connection)")
        }
        try connections.parkConnection(connectionID)

        // At this stage we're gonna end up creating 3 connections. No outstanding requests are present, so
        // we only need the pre-warmed set, which includes the one we already made.
        //
        // The first will ask for another connection
        (connectionID, connectionEL) = (newConnectionID, newConnectionEL)
        XCTAssertNoThrow(try connections.createConnection(connectionID, on: connectionEL))
        conn = try connections.succeedConnectionCreationHTTP1(connectionID)
        createdAction = state.newHTTP1ConnectionCreated(conn)
        try connections.parkConnection(connectionID)

        guard
            case .scheduleTimeoutTimerAndCreateConnection(_, let nextConnectionID, let nextConnectionEL) = createdAction
                .connection
        else {
            return XCTFail("Unexpected connection action: \(createdAction.connection)")
        }
        (newConnectionID, newConnectionEL) = (nextConnectionID, nextConnectionEL)

        // The second one only asks for a timeout.
        (connectionID, connectionEL) = (newConnectionID, newConnectionEL)
        XCTAssertNoThrow(try connections.createConnection(connectionID, on: connectionEL))
        conn = try connections.succeedConnectionCreationHTTP1(connectionID)
        createdAction = state.newHTTP1ConnectionCreated(conn)
        try connections.parkConnection(connectionID)

        guard case .scheduleTimeoutTimer = createdAction.connection else {
            return XCTFail("Unexpected connection action")
        }

        // Now we should complete the delayed connection request. This will also only ask for a timer.
        (connectionID, connectionEL) = (veryDelayedConnectionID, veryDelayedLoop)
        XCTAssertNoThrow(try connections.createConnection(connectionID, on: connectionEL))
        conn = try connections.succeedConnectionCreationHTTP1(connectionID)
        createdAction = state.newHTTP1ConnectionCreated(conn)
        try connections.parkConnection(connectionID)

        guard case .scheduleTimeoutTimer = createdAction.connection else {
            return XCTFail("Unexpected connection action")
        }

        XCTAssertEqual(connections.count, 4)
        XCTAssertEqual(connections.parked, 4)

        // Now we start sending requests. The first 4 requests will be accompanied by requests to create new connections,
        // because as each connection goes out, the pre-warming creates another. We'll let them succeed.
        for _ in 0..<4 {
            let eventLoop = elg.next()

            let mockRequest = MockHTTPScheduableRequest(eventLoop: eventLoop)
            let request = HTTPConnectionPool.Request(mockRequest)
            let action = state.executeRequest(request)

            guard
                case .createConnectionAndCancelTimeoutTimer(
                    let newConnectionID,
                    let newConnectionLoop,
                    let activatedConnectionID
                ) = action.connection
            else {
                return XCTFail("Unexpected connection action: \(action)")
            }

            guard case .executeRequest(_, let connection, _) = action.request else {
                return XCTFail("Expected to execute a request next, but got: \(action.request)")
            }

            try connections.activateConnection(activatedConnectionID)
            try connections.execute(mockRequest, on: connection)

            // Now create the new connection.
            XCTAssertNoThrow(try connections.createConnection(newConnectionID, on: newConnectionLoop))
            conn = try connections.succeedConnectionCreationHTTP1(newConnectionID)
            createdAction = state.newHTTP1ConnectionCreated(conn)
            try connections.parkConnection(newConnectionID)
        }

        XCTAssertEqual(connections.count, 8)
        XCTAssertEqual(connections.parked, 4)

        // The next 4 should _not_ ask to create new connections. We're at the cap, and prewarming can't exceed it.
        for _ in 0..<4 {
            let eventLoop = elg.next()

            let mockRequest = MockHTTPScheduableRequest(eventLoop: eventLoop)
            let request = HTTPConnectionPool.Request(mockRequest)
            let action = state.executeRequest(request)

            guard case .cancelTimeoutTimer(let activatedConnectionID) = action.connection else {
                return XCTFail("Unexpected connection action: \(action)")
            }

            guard case .executeRequest(_, let connection, _) = action.request else {
                return XCTFail("Expected to execute a request next, but got: \(action.request)")
            }

            try connections.activateConnection(activatedConnectionID)
            try connections.execute(mockRequest, on: connection)
        }

        XCTAssertEqual(connections.count, 8)
        XCTAssertEqual(connections.parked, 0)

        while let connectionID = connections.randomActiveConnection() {
            try connections.finishExecution(connectionID)
            action = state.http1ConnectionReleased(connectionID)

            guard case .scheduleTimeoutTimer = action.connection else {
                return XCTFail("Unexpected connection action: \(action.connection)")
            }
        }

        XCTAssertEqual(connections.count, 8)
        XCTAssertEqual(connections.parked, 0)
    }

    func testPrewarmingAffectsConnectionFailure() throws {
        struct SomeError: Error {}
        let elg = EmbeddedEventLoopGroup(loops: 4)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }

        var state = HTTPConnectionPool.StateMachine(
            idGenerator: .init(),
            maximumConcurrentHTTP1Connections: 8,
            retryConnectionEstablishment: true,
            preferHTTP1: true,
            maximumConnectionUses: nil,
            preWarmedHTTP1ConnectionCount: 4
        )

        var connections = MockConnectionPool()

        // Attempt to send one request. Complete the connection creation immediately, deferring the next connection creation, and then complete the
        // request.
        let mockRequest = MockHTTPScheduableRequest(eventLoop: elg.next())
        let request = HTTPConnectionPool.Request(mockRequest)
        var action = state.executeRequest(request)
        guard case .createConnection(var connectionID, var connectionEL) = action.connection else {
            return XCTFail("Unexpected connection action")
        }
        XCTAssertEqual(.scheduleRequestTimeout(for: request, on: mockRequest.eventLoop), action.request)

        XCTAssertNoThrow(try connections.createConnection(connectionID, on: connectionEL))
        var conn = try connections.succeedConnectionCreationHTTP1(connectionID)
        var createdAction = state.newHTTP1ConnectionCreated(conn)
        guard case .createConnection(var newConnectionID, var newConnectionEL) = createdAction.connection else {
            return XCTFail("Unexpected connection action")
        }
        try connections.execute(mockRequest, on: conn)
        try connections.finishExecution(connectionID)
        action = state.http1ConnectionReleased(connectionID)

        // Here the state machine has _again_ asked us to create a connection. This is because the pre-warming
        // phase takes any opportunity to do that.
        guard
            case .scheduleTimeoutTimerAndCreateConnection(_, let veryDelayedConnectionID, let veryDelayedLoop) = action
                .connection
        else {
            return XCTFail("Unexpected action: \(action.connection)")
        }
        try connections.parkConnection(connectionID)

        // At this stage we're gonna end up creating 3 connections. No outstanding requests are present, so
        // we only need the pre-warmed set, which includes the one we already made.
        //
        // The first will ask for another connection
        (connectionID, connectionEL) = (newConnectionID, newConnectionEL)
        XCTAssertNoThrow(try connections.createConnection(connectionID, on: connectionEL))
        conn = try connections.succeedConnectionCreationHTTP1(connectionID)
        createdAction = state.newHTTP1ConnectionCreated(conn)
        try connections.parkConnection(connectionID)

        guard
            case .scheduleTimeoutTimerAndCreateConnection(_, let nextConnectionID, let nextConnectionEL) = createdAction
                .connection
        else {
            return XCTFail("Unexpected connection action: \(createdAction.connection)")
        }
        (newConnectionID, newConnectionEL) = (nextConnectionID, nextConnectionEL)

        // The second one only asks for a timeout.
        (connectionID, connectionEL) = (newConnectionID, newConnectionEL)
        XCTAssertNoThrow(try connections.createConnection(connectionID, on: connectionEL))
        conn = try connections.succeedConnectionCreationHTTP1(connectionID)
        createdAction = state.newHTTP1ConnectionCreated(conn)
        try connections.parkConnection(connectionID)

        guard case .scheduleTimeoutTimer = createdAction.connection else {
            return XCTFail("Unexpected connection action")
        }

        // Now we should complete the delayed connection request. This will also only ask for a timer.
        (connectionID, connectionEL) = (veryDelayedConnectionID, veryDelayedLoop)
        XCTAssertNoThrow(try connections.createConnection(connectionID, on: connectionEL))
        conn = try connections.succeedConnectionCreationHTTP1(connectionID)
        createdAction = state.newHTTP1ConnectionCreated(conn)
        try connections.parkConnection(connectionID)

        guard case .scheduleTimeoutTimer = createdAction.connection else {
            return XCTFail("Unexpected connection action")
        }

        XCTAssertEqual(connections.count, 4)
        XCTAssertEqual(connections.parked, 4)

        // Now, one of these connections idle-fails.
        let parked = connections.randomParkedConnection()!
        try connections.closeConnection(parked)
        action = state.http1ConnectionClosed(parked.id)

        guard case .createConnection(var id, on: let loop) = action.connection else {
            return XCTFail("Unexpected connection action: \(action.connection)")
        }

        // A reasonable request. But it fails!
        //
        // Let's do this next bit a few times to convince ourselves it's a real problem.
        for _ in 0..<8 {
            // We're asked to schedule a backoff timer.
            action = state.failedToCreateNewConnection(SomeError(), connectionID: id)
            guard case .scheduleBackoffTimer(let backoffID, _, _) = action.connection else {
                return XCTFail("Unexpected connection action: \(action.connection)")
            }
            XCTAssertEqual(backoffID, id)

            // Once it passes, ask what to do. We'll be asked, again, to create a connection.
            action = state.connectionCreationBackoffDone(backoffID)
            guard case .createConnection(let backedOffID, on: let backedOffLoop) = action.connection else {
                return XCTFail("Unexpected connection action: \(action.connection)")
            }
            XCTAssertNotEqual(backedOffID, id)
            XCTAssertIdentical(backedOffLoop, loop)
            id = backedOffID
        }

        // Finally it works.
        XCTAssertNoThrow(try connections.createConnection(id, on: loop))
        conn = try connections.succeedConnectionCreationHTTP1(id)
        createdAction = state.newHTTP1ConnectionCreated(conn)
        try connections.parkConnection(id)

        guard case .scheduleTimeoutTimer = createdAction.connection else {
            return XCTFail("Unexpected connection action")
        }
    }

    func testIdleConnectionTimeoutHandlingWithPrewarming() throws {
        let elg = EmbeddedEventLoopGroup(loops: 4)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }

        var state = HTTPConnectionPool.StateMachine(
            idGenerator: .init(),
            maximumConcurrentHTTP1Connections: 8,
            retryConnectionEstablishment: true,
            preferHTTP1: true,
            maximumConnectionUses: nil,
            preWarmedHTTP1ConnectionCount: 4
        )

        var connections = MockConnectionPool()

        // Attempt to send one request. Complete the connection creation immediately, deferring the next connection creation, and then complete the
        // request.
        var mockRequest = MockHTTPScheduableRequest(eventLoop: elg.next())
        var request = HTTPConnectionPool.Request(mockRequest)
        var action = state.executeRequest(request)
        guard case .createConnection(var connectionID, var connectionEL) = action.connection else {
            return XCTFail("Unexpected connection action")
        }
        XCTAssertEqual(.scheduleRequestTimeout(for: request, on: mockRequest.eventLoop), action.request)

        XCTAssertNoThrow(try connections.createConnection(connectionID, on: connectionEL))
        var conn = try connections.succeedConnectionCreationHTTP1(connectionID)
        var createdAction = state.newHTTP1ConnectionCreated(conn)
        guard case .createConnection(var newConnectionID, var newConnectionEL) = createdAction.connection else {
            return XCTFail("Unexpected connection action")
        }
        try connections.execute(mockRequest, on: conn)
        try connections.finishExecution(connectionID)
        action = state.http1ConnectionReleased(connectionID)

        // Here the state machine has _again_ asked us to create a connection. This is because the pre-warming
        // phase takes any opportunity to do that.
        guard
            case .scheduleTimeoutTimerAndCreateConnection(_, let veryDelayedConnectionID, let veryDelayedLoop) = action
                .connection
        else {
            return XCTFail("Unexpected action: \(action.connection)")
        }
        try connections.parkConnection(connectionID)

        // At this stage we're gonna end up creating 3 connections. No outstanding requests are present, so
        // we only need the pre-warmed set, which includes the one we already made.
        //
        // The first will ask for another connection
        (connectionID, connectionEL) = (newConnectionID, newConnectionEL)
        XCTAssertNoThrow(try connections.createConnection(connectionID, on: connectionEL))
        conn = try connections.succeedConnectionCreationHTTP1(connectionID)
        createdAction = state.newHTTP1ConnectionCreated(conn)
        try connections.parkConnection(connectionID)

        guard
            case .scheduleTimeoutTimerAndCreateConnection(_, let nextConnectionID, let nextConnectionEL) = createdAction
                .connection
        else {
            return XCTFail("Unexpected connection action: \(createdAction.connection)")
        }
        (newConnectionID, newConnectionEL) = (nextConnectionID, nextConnectionEL)

        // The second one only asks for a timeout.
        (connectionID, connectionEL) = (newConnectionID, newConnectionEL)
        XCTAssertNoThrow(try connections.createConnection(connectionID, on: connectionEL))
        conn = try connections.succeedConnectionCreationHTTP1(connectionID)
        createdAction = state.newHTTP1ConnectionCreated(conn)
        try connections.parkConnection(connectionID)

        guard case .scheduleTimeoutTimer = createdAction.connection else {
            return XCTFail("Unexpected connection action")
        }

        // Now we should complete the delayed connection request. This will also only ask for a timer.
        (connectionID, connectionEL) = (veryDelayedConnectionID, veryDelayedLoop)
        XCTAssertNoThrow(try connections.createConnection(connectionID, on: connectionEL))
        conn = try connections.succeedConnectionCreationHTTP1(connectionID)
        createdAction = state.newHTTP1ConnectionCreated(conn)
        try connections.parkConnection(connectionID)

        guard case .scheduleTimeoutTimer = createdAction.connection else {
            return XCTFail("Unexpected connection action")
        }

        XCTAssertEqual(connections.count, 4)
        XCTAssertEqual(connections.parked, 4)

        // Now, the idle timeout timer fires. We can do this a few times, it'll keep
        // re-arming.
        for _ in 0..<8 {
            action = state.connectionIdleTimeout(connectionID, on: connectionEL)
            guard case .scheduleTimeoutTimer = createdAction.connection else {
                return XCTFail("Unexpected connection action")
            }
        }

        // Let's force another connection to be created for a request.
        mockRequest = MockHTTPScheduableRequest(eventLoop: elg.next())
        request = HTTPConnectionPool.Request(mockRequest)
        action = state.executeRequest(request)
        guard
            case .createConnectionAndCancelTimeoutTimer(let extraConnectionID, let extraConnectionEL, _) = action
                .connection
        else {
            return XCTFail("Unexpected connection action: \(action.connection)")
        }
        guard case .executeRequest(_, let requestConnection, _) = action.request else {
            return XCTFail("Unexpected request action")
        }

        XCTAssertNoThrow(try connections.createConnection(extraConnectionID, on: extraConnectionEL))
        conn = try connections.succeedConnectionCreationHTTP1(extraConnectionID)
        createdAction = state.newHTTP1ConnectionCreated(conn)
        guard case .scheduleTimeoutTimer = createdAction.connection else {
            return XCTFail("Unexpected connection action: \(createdAction.connection)")
        }
        try connections.activateConnection(requestConnection.id)
        try connections.execute(mockRequest, on: requestConnection)
        try connections.finishExecution(requestConnection.id)
        try connections.parkConnection(requestConnection.id)
        action = state.http1ConnectionReleased(requestConnection.id)

        // Back to idle.
        guard case .scheduleTimeoutTimer = action.connection else {
            return XCTFail("Unexpected action: \(action.connection)")
        }
        try connections.parkConnection(extraConnectionID)

        XCTAssertEqual(connections.count, 5)
        XCTAssertEqual(connections.parked, 5)

        // This time when the idle timeout fires, we're actually asked to close the connection.
        action = state.connectionIdleTimeout(connectionID, on: connectionEL)
        guard case .closeConnection = action.connection else {
            return XCTFail("Unexpected connection action: \(createdAction.connection)")
        }
    }

    func testPrewarmingForcesReCreationOfConnectionsWhenTheyHitMaxUses() throws {
        let elg = EmbeddedEventLoopGroup(loops: 4)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }

        // The scenario we want to hit can only happen when there is never a spare pre-warmed connection
        // in the pool _and_ we can't create more. The easiest way to test this is to just
        // create pre-warmed connections up to the pool limit, which they won't pass.
        var state = HTTPConnectionPool.StateMachine(
            idGenerator: .init(),
            maximumConcurrentHTTP1Connections: 8,
            retryConnectionEstablishment: true,
            preferHTTP1: true,
            maximumConnectionUses: 1,
            preWarmedHTTP1ConnectionCount: 8
        )

        var connections = MockConnectionPool()

        // Attempt to send one request. Complete the connection creation immediately, deferring the next connection creation, but don't
        // complete the request.
        let mockRequest = MockHTTPScheduableRequest(eventLoop: elg.next())
        let request = HTTPConnectionPool.Request(mockRequest)
        var action = state.executeRequest(request)
        guard case .createConnection(var connectionID, var connectionEL) = action.connection else {
            return XCTFail("Unexpected connection action")
        }
        XCTAssertEqual(.scheduleRequestTimeout(for: request, on: mockRequest.eventLoop), action.request)

        XCTAssertNoThrow(try connections.createConnection(connectionID, on: connectionEL))
        var conn = try connections.succeedConnectionCreationHTTP1(connectionID)
        var createdAction = state.newHTTP1ConnectionCreated(conn)
        try connections.parkConnection(connectionID)
        guard case .createConnection(var newConnectionID, var newConnectionEL) = createdAction.connection else {
            return XCTFail("Unexpected connection action")
        }
        guard case .executeRequest(_, let requestConn, _) = createdAction.request else {
            return XCTFail("Unexpected request action: \(action.request)")
        }

        // At this stage we're gonna end up creating 7 more connections. No outstanding requests are present, so
        // we only need the pre-warmed set, which includes the one we already made.
        //
        // The first six will ask for another connection.
        for _ in 0..<6 {
            (connectionID, connectionEL) = (newConnectionID, newConnectionEL)
            XCTAssertNoThrow(try connections.createConnection(connectionID, on: connectionEL))
            conn = try connections.succeedConnectionCreationHTTP1(connectionID)
            createdAction = state.newHTTP1ConnectionCreated(conn)
            try connections.parkConnection(connectionID)

            guard
                case .scheduleTimeoutTimerAndCreateConnection(_, let nextConnectionID, let nextConnectionEL) =
                    createdAction.connection
            else {
                return XCTFail("Unexpected connection action: \(createdAction.connection)")
            }
            (newConnectionID, newConnectionEL) = (nextConnectionID, nextConnectionEL)
        }

        // The seventh one only asks for a timeout.
        (connectionID, connectionEL) = (newConnectionID, newConnectionEL)
        XCTAssertNoThrow(try connections.createConnection(connectionID, on: connectionEL))
        conn = try connections.succeedConnectionCreationHTTP1(connectionID)
        createdAction = state.newHTTP1ConnectionCreated(conn)
        try connections.parkConnection(connectionID)

        guard case .scheduleTimeoutTimer = createdAction.connection else {
            return XCTFail("Unexpected connection action: \(createdAction.connection)")
        }

        XCTAssertEqual(connections.count, 8)
        XCTAssertEqual(connections.parked, 8)

        // Now we're gonna actually complete that request from earlier.
        try connections.activateConnection(requestConn.id)
        try connections.execute(mockRequest, on: requestConn)
        try connections.finishExecution(requestConn.id)
        action = state.http1ConnectionReleased(requestConn.id)

        // Here the state machine has asked us to close the connection and create a new one. That's because we've hit the
        // max usages limit.
        guard case .closeConnectionAndCreateConnection(let toClose, _, _) = action.connection else {
            return XCTFail("Unexpected action: \(action.connection)")
        }
        try connections.closeConnection(toClose)

        // We won't bother doing it though, it's enough that it asked.
    }

    func testFailConnectionRacesAgainstConnectionCreationFailed() {
        let elg = EmbeddedEventLoopGroup(loops: 4)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }

        var state = HTTPConnectionPool.StateMachine(
            idGenerator: .init(),
            maximumConcurrentHTTP1Connections: 2,
            retryConnectionEstablishment: true,
            preferHTTP1: true,
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

        XCTAssertEqual(state.http1ConnectionClosed(connectionID), .none)

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
