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
import NIO
import NIOHTTP1
import XCTest

class HTTPConnectionPool_HTTP1StateMachineTests: XCTestCase {
    func testCreatingAndFailingConnections() {
        let elg = EmbeddedEventLoopGroup(loops: 4)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }

        var state = HTTPConnectionPool.StateMachine(
            eventLoopGroup: elg,
            idGenerator: .init(),
            maximumConcurrentHTTP1Connections: 8
        )

        var connections = MockConnectionPool()
        var queuer = MockRequestQueuer()

        // for the first eight requests, the pool should try to create new connections.

        for _ in 0..<8 {
            let mockRequest = MockHTTPRequest(eventLoop: elg.next())
            let request = HTTPConnectionPool.Request(mockRequest)
            let action = state.executeRequest(request)
            guard case .createConnection(let connectionID, let connectionEL) = action.connection else {
                return XCTFail("Unexpected connection action")
            }
            guard case .scheduleRequestTimeout(_, for: request.id, on: let queueEL) = action.request else {
                return XCTFail("Unexpected request action")
            }
            XCTAssert(queueEL === mockRequest.eventLoop)
            XCTAssert(connectionEL === mockRequest.eventLoop)

            XCTAssertNoThrow(try connections.createConnection(connectionID, on: connectionEL))
            XCTAssertNoThrow(try queuer.queue(mockRequest, id: request.id))
        }

        // the next eight requests should only be queued.

        for _ in 0..<8 {
            let mockRequest = MockHTTPRequest(eventLoop: elg.next())
            let request = HTTPConnectionPool.Request(mockRequest)
            let action = state.executeRequest(request)
            guard case .none = action.connection else {
                return XCTFail("Unexpected connection action")
            }
            guard case .scheduleRequestTimeout(_, for: request.id, on: let queueEL) = action.request else {
                return XCTFail("Unexpected request action")
            }
            XCTAssert(queueEL === mockRequest.eventLoop)
            XCTAssertNoThrow(try queuer.queue(mockRequest, id: request.id))
        }

        // timeout all queued requests except for two

        // fail all connection attempts
        while let randomConnectionID = connections.randomStartingConnection() {
            struct SomeError: Error, Equatable {}

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
            let cancelAction = state.cancelRequest(request)
            XCTAssertEqual(cancelAction.connection, .none)
            XCTAssertEqual(cancelAction.request, .cancelRequestTimeout(request))
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

    func testConnectionFailureBackoff() {
        let elg = EmbeddedEventLoopGroup(loops: 4)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }

        var state = HTTPConnectionPool.StateMachine(
            eventLoopGroup: elg,
            idGenerator: .init(),
            maximumConcurrentHTTP1Connections: 2
        )

        let mockRequest = MockHTTPRequest(eventLoop: elg.next())
        let request = HTTPConnectionPool.Request(mockRequest)

        let action = state.executeRequest(request)
        guard case .scheduleRequestTimeout(_, request.id, on: let returnedEL) = action.request else {
            return XCTFail("Unexpected request action: \(action.request)")
        }
        XCTAssert(returnedEL === mockRequest.eventLoop) // XCTAssertIdentical not available on Linux

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
        guard case .failRequest(let requestToFail, let requestError, cancelTimeout: nil) = failRequest.request else {
            return XCTFail("Unexpected request action: \(action.request)")
        }
        XCTAssert(requestToFail.__testOnly_wrapped_request() === mockRequest) // XCTAssertIdentical not available on Linux
        XCTAssertEqual(requestError as? HTTPClientError, .getConnectionFromPoolTimeout)
        XCTAssertEqual(failRequest.connection, .none)

        // 4. retry connection, but no more queued requests.
        XCTAssertEqual(state.connectionCreationBackoffDone(newConnectionID), .none)
    }

    func testCancelRequestWorks() {
        let elg = EmbeddedEventLoopGroup(loops: 4)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }

        var state = HTTPConnectionPool.StateMachine(
            eventLoopGroup: elg,
            idGenerator: .init(),
            maximumConcurrentHTTP1Connections: 2
        )

        let mockRequest = MockHTTPRequest(eventLoop: elg.next())
        let request = HTTPConnectionPool.Request(mockRequest)

        let executeAction = state.executeRequest(request)
        guard case .scheduleRequestTimeout(_, request.id, on: let returnedEL) = executeAction.request else {
            return XCTFail("Unexpected request action: \(executeAction.request)")
        }
        XCTAssert(returnedEL === mockRequest.eventLoop) // XCTAssertIdentical not available on Linux

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
        let connectedAction = state.newHTTP1ConnectionCreated(.__testOnly_connection(id: connectionID, eventLoop: connectionEL))
        XCTAssertEqual(connectedAction.request, .none, "Request must not be executed")
        XCTAssertEqual(connectedAction.connection, .scheduleTimeoutTimer(connectionID, on: connectionEL))
    }

    func testExecuteOnShuttingDownPool() {
        let elg = EmbeddedEventLoopGroup(loops: 4)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }

        var state = HTTPConnectionPool.StateMachine(
            eventLoopGroup: elg,
            idGenerator: .init(),
            maximumConcurrentHTTP1Connections: 2
        )

        let mockRequest = MockHTTPRequest(eventLoop: elg.next())
        let request = HTTPConnectionPool.Request(mockRequest)

        let executeAction = state.executeRequest(request)
        guard case .scheduleRequestTimeout(_, request.id, on: let returnedEL) = executeAction.request else {
            return XCTFail("Unexpected request action: \(executeAction.request)")
        }
        XCTAssert(returnedEL === mockRequest.eventLoop) // XCTAssertIdentical not available on Linux

        // 1. connection attempt
        guard case .createConnection(let connectionID, on: let connectionEL) = executeAction.connection else {
            return XCTFail("Unexpected connection action: \(executeAction.connection)")
        }
        XCTAssert(connectionEL === mockRequest.eventLoop) // XCTAssertIdentical not available on Linux

        // 2. connection succeeds
        let connection: HTTPConnectionPool.Connection = .__testOnly_connection(id: connectionID, eventLoop: connectionEL)
        let connectedAction = state.newHTTP1ConnectionCreated(connection)
        guard case .executeRequest(request, connection, cancelTimeout: request.id) = connectedAction.request else {
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
        XCTAssertEqual(failAction.request, .failRequest(finalRequest, HTTPClientError.alreadyShutdown, cancelTimeout: nil))

        // 5. close open connection
        let closeAction = state.connectionClosed(connectionID)
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
            guard let expectedConnection = connections.newestParkedConnection(for: eventLoop) ?? connections.newestParkedConnection else {
                return XCTFail("Expected to still have connections available")
            }

            let mockRequest = MockHTTPRequest(eventLoop: eventLoop)
            let request = HTTPConnectionPool.Request(mockRequest)
            let action = state.executeRequest(request)

            XCTAssertEqual(action.connection, .cancelTimeoutTimer(expectedConnection.id))
            guard case .executeRequest(let returnedRequest, expectedConnection, cancelTimeout: nil) = action.request else {
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

            // in 10% of the cases, we require an explicit EventLoop.
//            let elRequired = (0..<10).randomElement().flatMap { $0 == 0 ? true : false }!
            let elRequired = false
            let mockRequest = MockHTTPRequest(eventLoop: eventLoop, requiresEventLoopForChannel: elRequired)
            let request = HTTPConnectionPool.Request(mockRequest)
            let action = state.executeRequest(request)

            XCTAssertEqual(action.connection, .none)
            guard case .scheduleRequestTimeout(_, request.id, on: let timeoutEL) = action.request else {
                return XCTFail("Unexpected request action: \(action.request)")
            }

            XCTAssert(timeoutEL === mockRequest.eventLoop)

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
                guard case .executeRequest(let request, connection, cancelTimeout: .some(let requestID)) = action.request else {
                    return XCTFail("Unexpected request action: \(action.request)")
                }
                XCTAssertEqual(requestID, queuedRequestsOrder.popFirst())
                let mockRequest = request.__testOnly_wrapped_request()
                XCTAssertNoThrow(try connections.execute(queuer.get(requestID, request: mockRequest), on: connection))

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

            var eventLoop: EventLoop = elg.next()
            for _ in 0..<((0..<63).randomElement()!) {
                // pick a random eventLoop for the next request
                eventLoop = elg.next()
            }

            // 10% of the cases enforce the eventLoop
//            let elRequired = (0..<10).randomElement().flatMap { $0 == 0 ? true : false }!
            let elRequired = false
            let mockRequest = MockHTTPRequest(eventLoop: eventLoop, requiresEventLoopForChannel: elRequired)
            let request = HTTPConnectionPool.Request(mockRequest)

            let action = state.executeRequest(request)

            guard let expectedConnection = connections.newestParkedConnection(for: eventLoop) ?? connections.newestParkedConnection else {
                return XCTFail("Expected to have connections available")
            }

            switch action.connection {
            case .cancelTimeoutTimer(let connectionID):
                XCTAssertEqual(connectionID, expectedConnection.id, "Request is scheduled on the connection we expected")
                XCTAssertNoThrow(try connections.activateConnection(connectionID))

                guard case .executeRequest(let request, let connection, cancelTimeout: nil) = action.request else {
                    return XCTFail("Expected to execute a request, but got: \(action.request)")
                }
                XCTAssertEqual(connection, expectedConnection)
                XCTAssertNoThrow(try connections.execute(request.__testOnly_wrapped_request(), on: connection))
                XCTAssertNoThrow(try connections.finishExecution(connection.id))

                XCTAssertEqual(state.http1ConnectionReleased(connection.id),
                               .init(request: .none, connection: .scheduleTimeoutTimer(connection.id, on: connection.eventLoop)))
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
        let mockRequest = MockHTTPRequest(eventLoop: elg.next())
        let request = HTTPConnectionPool.Request(mockRequest)
        guard let connectionToAbort = connections.newestParkedConnection else {
            return XCTFail("Expected to have a parked connection")
        }
        let action = state.executeRequest(request)
        XCTAssertEqual(action.connection, .cancelTimeoutTimer(connectionToAbort.id))
        XCTAssertNoThrow(try connections.activateConnection(connectionToAbort.id))
        XCTAssertEqual(action.request, .executeRequest(request, connectionToAbort, cancelTimeout: nil))
        XCTAssertNoThrow(try connections.execute(mockRequest, on: connectionToAbort))
        XCTAssertEqual(connections.parked, 7)
        XCTAssertEqual(connections.used, 1)
        XCTAssertNoThrow(try connections.abortConnection(connectionToAbort.id))
        XCTAssertEqual(state.connectionClosed(connectionToAbort.id), .none)
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
        XCTAssertEqual(state.connectionClosed(connectionToClose.id), .none)
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
            guard let expectedConnection = connections.newestParkedConnection(for: eventLoop) ?? connections.newestParkedConnection else {
                return XCTFail("Expected to still have connections available")
            }

            let mockRequest = MockHTTPRequest(eventLoop: eventLoop)
            let request = HTTPConnectionPool.Request(mockRequest)
            let action = state.executeRequest(request)

            XCTAssertEqual(action.connection, .cancelTimeoutTimer(expectedConnection.id))
            XCTAssertEqual(action.request, .executeRequest(request, expectedConnection, cancelTimeout: nil))

            XCTAssertNoThrow(try connections.activateConnection(expectedConnection.id))
            XCTAssertNoThrow(try connections.execute(mockRequest, on: expectedConnection))
        }

        // Add 100 requests to fill request queue
        var queuedRequestsOrder = CircularBuffer<MockRequestQueuer.RequestID>()
        var queuer = MockRequestQueuer()
        for _ in 0..<100 {
            let eventLoop = elg.next()

            // in 10% of the cases, we require an explicit EventLoop.
//            let elRequired = (0..<10).randomElement().flatMap { $0 == 0 ? true : false }!
            let elRequired = false
            let mockRequest = MockHTTPRequest(eventLoop: eventLoop, requiresEventLoopForChannel: elRequired)
            let request = HTTPConnectionPool.Request(mockRequest)
            let action = state.executeRequest(request)

            XCTAssertEqual(action.connection, .none)
            guard case .scheduleRequestTimeout(_, request.id, on: let timeoutEL) = action.request else {
                return XCTFail("Unexpected request action: \(action.request)")
            }

            XCTAssert(mockRequest.eventLoop === timeoutEL)
            XCTAssertNoThrow(try queuer.queue(mockRequest, id: request.id))
            queuedRequestsOrder.append(request.id)
        }

        while let closedConnection = connections.randomLeasedConnection() {
            XCTAssertNoThrow(try connections.abortConnection(closedConnection.id))
            XCTAssertEqual(connections.parked, 0)
            let action = state.connectionClosed(closedConnection.id)

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
                guard case .executeRequest(let request, newConnection, cancelTimeout: .some(let requestID)) = afterRecreationAction.request else {
                    return XCTFail("Unexpected request action: \(action.request)")
                }

                XCTAssertEqual(requestID, queuedRequestsOrder.popFirst())
                XCTAssertNoThrow(try connections.execute(queuer.get(requestID, request: request.__testOnly_wrapped_request()), on: newConnection))

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

        let action = state.connectionIdleTimeout(connection.id)
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
        XCTAssertEqual(state.connectionClosed(connection.id), .none)

        // triggered by timer
        XCTAssertEqual(state.connectionIdleTimeout(connection.id), .none)
    }
}
