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

class HTTPConnectionPool_HTTP1StateMachineTests: XCTestCase {
    func testCreatingAndFailingConnections() {
        struct SomeError: Error, Equatable {}
        let elg = EmbeddedEventLoopGroup(loops: 4)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }

        var state = HTTPConnectionPool.StateMachine(
            idGenerator: .init(),
            maximumConcurrentHTTP1Connections: 8,
            retryConnectionEstablishment: true,
            maximumConnectionUses: nil
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
            maximumConnectionUses: nil
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

        var state = HTTPConnectionPool.StateMachine(
            idGenerator: .init(),
            maximumConcurrentHTTP1Connections: 2,
            retryConnectionEstablishment: true,
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
        XCTAssert(connectionEL === mockRequest.eventLoop) // XCTAssertIdentical not available on Linux

        // 2. cancel request

        let cancelAction = state.cancelRequest(request.id)
        XCTAssertEqual(cancelAction.request, .failRequest(request, HTTPClientError.cancelled, cancelTimeout: true))
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
            idGenerator: .init(),
            maximumConcurrentHTTP1Connections: 2,
            retryConnectionEstablishment: true,
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
        XCTAssert(connectionEL === mockRequest.eventLoop) // XCTAssertIdentical not available on Linux

        // 2. connection succeeds
        let connection: HTTPConnectionPool.Connection = .__testOnly_connection(id: connectionID, eventLoop: connectionEL)
        let connectedAction = state.newHTTP1ConnectionCreated(connection)
        guard case .executeRequest(request, connection, cancelTimeout: true) = connectedAction.request else {
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
        let finalMockRequest = MockHTTPScheduableRequest(eventLoop: elg.next())
        let finalRequest = HTTPConnectionPool.Request(finalMockRequest)
        let failAction = state.executeRequest(finalRequest)
        XCTAssertEqual(failAction.connection, .none)
        XCTAssertEqual(failAction.request, .failRequest(finalRequest, HTTPClientError.alreadyShutdown, cancelTimeout: false))

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
            guard let expectedConnection = connections.newestParkedConnection(for: eventLoop) ?? connections.newestParkedConnection else {
                return XCTFail("Expected to still have connections available")
            }

            let mockRequest = MockHTTPScheduableRequest(eventLoop: eventLoop)
            let request = HTTPConnectionPool.Request(mockRequest)
            let action = state.executeRequest(request)

            XCTAssertEqual(action.connection, .cancelTimeoutTimer(expectedConnection.id))
            guard case .executeRequest(let returnedRequest, expectedConnection, cancelTimeout: false) = action.request else {
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
            let mockRequest = MockHTTPScheduableRequest(eventLoop: reqEventLoop, requiresEventLoopForChannel: elRequired)
            let request = HTTPConnectionPool.Request(mockRequest)

            let action = state.executeRequest(request)

            switch action.connection {
            case .createConnection(let connectionID, on: let connEventLoop):
                XCTAssertTrue(elRequired)
                XCTAssertNil(connections.newestParkedConnection(for: reqEventLoop))
                XCTAssert(connEventLoop === reqEventLoop)
                XCTAssertEqual(action.request, .scheduleRequestTimeout(for: request, on: reqEventLoop))

                let connection: HTTPConnectionPool.Connection = .__testOnly_connection(id: connectionID, eventLoop: connEventLoop)
                let createdAction = state.newHTTP1ConnectionCreated(connection)
                XCTAssertEqual(createdAction.request, .executeRequest(request, connection, cancelTimeout: true))
                XCTAssertEqual(createdAction.connection, .none)

                let doneAction = state.http1ConnectionReleased(connectionID)
                XCTAssertEqual(doneAction.request, .none)
                XCTAssertEqual(doneAction.connection, .closeConnection(connection, isShutdown: .no))
                XCTAssertEqual(state.http1ConnectionClosed(connectionID), .none)

            case .cancelTimeoutTimer(let connectionID):
                guard let expectedConnection = connections.newestParkedConnection(for: reqEventLoop) ?? connections.newestParkedConnection else {
                    return XCTFail("Expected to have connections available")
                }

                if elRequired {
                    XCTAssert(expectedConnection.eventLoop === reqEventLoop)
                }

                XCTAssertEqual(connectionID, expectedConnection.id, "Request is scheduled on the connection we expected")
                XCTAssertNoThrow(try connections.activateConnection(connectionID))

                guard case .executeRequest(let request, let connection, cancelTimeout: false) = action.request else {
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
            guard let expectedConnection = connections.newestParkedConnection(for: eventLoop) ?? connections.newestParkedConnection else {
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
                guard case .executeRequest(let request, newConnection, cancelTimeout: true) = afterRecreationAction.request else {
                    return XCTFail("Unexpected request action: \(action.request)")
                }

                XCTAssertEqual(request.id, queuedRequestsOrder.popFirst())
                XCTAssertNoThrow(try connections.execute(queuer.get(request.id, request: request.__testOnly_wrapped_request()), on: newConnection))

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
        XCTAssertEqual(state.http1ConnectionClosed(connection.id), .none)

        // triggered by timer
        XCTAssertEqual(state.connectionIdleTimeout(connection.id), .none)
    }

    func testConnectionBackoffVsShutdownRace() {
        let elg = EmbeddedEventLoopGroup(loops: 2)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }

        var state = HTTPConnectionPool.StateMachine(
            idGenerator: .init(),
            maximumConcurrentHTTP1Connections: 6,
            retryConnectionEstablishment: true,
            maximumConnectionUses: nil
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
            maximumConnectionUses: nil
        )

        let mockRequest = MockHTTPScheduableRequest(eventLoop: elg.next(), requiresEventLoopForChannel: false)
        let request = HTTPConnectionPool.Request(mockRequest)

        let executeAction = state.executeRequest(request)
        guard case .createConnection(let connectionID, on: let connEL) = executeAction.connection else {
            return XCTFail("Expected to create a connection")
        }

        XCTAssertEqual(executeAction.request, .scheduleRequestTimeout(for: request, on: mockRequest.eventLoop))

        let failAction = state.failedToCreateNewConnection(HTTPClientError.httpProxyHandshakeTimeout, connectionID: connectionID)
        guard case .scheduleBackoffTimer(connectionID, backoff: _, on: let timerEL) = failAction.connection else {
            return XCTFail("Expected to create a backoff timer")
        }
        XCTAssert(timerEL === connEL)
        XCTAssertEqual(failAction.request, .none)

        let timeoutAction = state.timeoutRequest(request.id)
        XCTAssertEqual(timeoutAction.request, .failRequest(request, HTTPClientError.httpProxyHandshakeTimeout, cancelTimeout: false))
        XCTAssertEqual(timeoutAction.connection, .none)
    }

    func testRequestThatTimesOutBeforeAConnectionIsEstablishedIsFailedWithConnectTimeoutError() {
        let eventLoop = EmbeddedEventLoop()
        defer { XCTAssertNoThrow(try eventLoop.syncShutdownGracefully()) }

        var state = HTTPConnectionPool.StateMachine(
            idGenerator: .init(),
            maximumConcurrentHTTP1Connections: 6,
            retryConnectionEstablishment: true,
            maximumConnectionUses: nil
        )

        let mockRequest = MockHTTPScheduableRequest(eventLoop: eventLoop.next(), requiresEventLoopForChannel: false)
        let request = HTTPConnectionPool.Request(mockRequest)

        let executeAction = state.executeRequest(request)
        guard case .createConnection(_, on: _) = executeAction.connection else {
            return XCTFail("Expected to create a connection")
        }
        XCTAssertEqual(executeAction.request, .scheduleRequestTimeout(for: request, on: mockRequest.eventLoop))

        let timeoutAction = state.timeoutRequest(request.id)
        XCTAssertEqual(timeoutAction.request, .failRequest(request, HTTPClientError.connectTimeout, cancelTimeout: false))
        XCTAssertEqual(timeoutAction.connection, .none)
    }

    func testRequestThatTimesOutAfterAConnectionWasEstablishedSuccessfullyTimesOutWithGenericError() {
        let elg = EmbeddedEventLoopGroup(loops: 1)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }

        var state = HTTPConnectionPool.StateMachine(
            idGenerator: .init(),
            maximumConcurrentHTTP1Connections: 6,
            retryConnectionEstablishment: true,
            maximumConnectionUses: nil
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

        let failAction = state.failedToCreateNewConnection(HTTPClientError.httpProxyHandshakeTimeout, connectionID: connectionID1)
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
        XCTAssertEqual(timeoutAction.request, .failRequest(request2, HTTPClientError.getConnectionFromPoolTimeout, cancelTimeout: false))
        XCTAssertEqual(timeoutAction.connection, .none)
    }
}
