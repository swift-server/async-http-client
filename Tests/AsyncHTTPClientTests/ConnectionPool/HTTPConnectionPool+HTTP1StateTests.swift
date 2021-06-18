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
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 4)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }
        var state = HTTPConnectionPool.StateMachine(
            eventLoopGroup: elg,
            idGenerator: .init(),
            maximumConcurrentHTTP1Connections: 8
        )

        var connections = MockConnections()
        var waiters = MockWaiters()

        for _ in 0..<8 {
            let task = MockHTTPRequestTask(eventLoop: elg.next())
            let action = state.executeTask(task, onPreffered: task.eventLoop, required: false)
            guard case .createConnection(let connectionID, let connectionEL) = action.connection else {
                return XCTFail("Unexpected connection action")
            }
            guard case .scheduleWaiterTimeout(let waiterID, _, on: let waiterEL) = action.task else {
                return XCTFail("Unexpected task action")
            }
            XCTAssert(waiterEL === task.eventLoop)
            XCTAssert(connectionEL === task.eventLoop)

            XCTAssertNoThrow(try connections.createConnection(connectionID, on: connectionEL))
            XCTAssertNoThrow(try waiters.wait(task, id: waiterID))
        }

        for _ in 0..<8 {
            let task = MockHTTPRequestTask(eventLoop: elg.next())
            let action = state.executeTask(task, onPreffered: task.eventLoop, required: false)
            guard case .none = action.connection else {
                return XCTFail("Unexpected connection action")
            }
            guard case .scheduleWaiterTimeout(let waiterID, _, on: let waiterEL) = action.task else {
                return XCTFail("Unexpected task action")
            }
            XCTAssert(waiterEL === task.eventLoop)
            XCTAssertNoThrow(try waiters.wait(task, id: waiterID))
        }

        // fail all connection attempts
        var counter: Int = 0
        while let randomConnectionID = connections.randomStartingConnection() {
            counter += 1
            struct SomeError: Error, Equatable {}

            XCTAssertNoThrow(try connections.failConnectionCreation(randomConnectionID))
            let action = state.failedToCreateNewConnection(SomeError(), connectionID: randomConnectionID)

            guard case .failTask(let task, let error, .some(let waiterID)) = action.task, error is SomeError else {
                return XCTFail("Unexpected task action: \(action.task)")
            }

            XCTAssertNoThrow(try waiters.fail(waiterID, task: task))

            switch action.connection {
            case .createConnection(let newConnectionID, let eventLoop):
                XCTAssertNoThrow(try connections.createConnection(newConnectionID, on: eventLoop))
            case .none:
                XCTAssertLessThan(waiters.count, 8)
            default:
                XCTFail("Unexpected action")
            }
        }

        XCTAssertEqual(counter, 16)
        XCTAssert(waiters.isEmpty)
        XCTAssert(connections.isEmpty)
    }

    func testForExactEventLoopRequirementsNewConnectionsAreCreatedUntilFullLaterOldestReplaced() {
        // If we have exact eventLoop requirements, we should create new connections, until the
        // maximum number of connections allowed is reached (8). After that we will start to replace
        // connections

        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 9)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }

        let eventLoop = elg.next()

        guard var (connections, state) = try? MockConnections.http1(elg: elg, on: eventLoop, numberOfConnections: 1) else {
            return XCTFail("Test setup failed")
        }
        XCTAssertEqual(connections.parked, 1)
        var waiters = MockWaiters()

        // At this point we have one open connection on `eventLoop`. This means we should be able
        // to create 7 more connections.

        for index in 0..<100 {
            let request = MockHTTPRequestTask(eventLoop: elg.next(), requiresEventLoopForChannel: true)
            let action = state.executeTask(request, onPreffered: request.eventLoop, required: true)

            guard case .scheduleWaiterTimeout(let waiterID, let requestToWait, on: let waiterEL) = action.task else {
                return XCTFail("Unexpected task action")
            }

            XCTAssert(request === requestToWait)
            XCTAssert(request.eventLoop === waiterEL)

            var oldConnection: MockConnections.Connection?
            let connectionID: MockConnections.Connection.ID
            let eventLoop: EventLoop

            if index < 7 {
                // Since we have one existing connection and eight connections are allowed, the
                // first seven tasks, will create new connections.
                guard case .createConnection(let id, on: let el) = action.connection else {
                    return XCTFail("Unexpected connection action \(index): \(action.connection)")
                }

                connectionID = id
                eventLoop = el
            } else {
                // After the first seven tasks, we need to replace existing connections. We try to
                // replace the connection that hasn't been use the longest.
                guard case .replaceConnection(let oid, let id, let el) = action.connection else {
                    return XCTFail("Unexpected connection action")
                }

                oldConnection = oid
                connectionID = id
                eventLoop = el
            }

            if let oid = oldConnection {
                XCTAssertEqual(connections.oldestParkedConnection, oldConnection)
                XCTAssertNoThrow(try connections.closeConnection(oid))
            }

            XCTAssert(eventLoop === request.eventLoop)
            XCTAssertNoThrow(try waiters.wait(request, id: waiterID))
            XCTAssertNoThrow(try connections.createConnection(connectionID, on: eventLoop))
            var newConnection: HTTPConnectionPool.Connection?
            XCTAssertNoThrow(newConnection = try connections.succeedConnectionCreationHTTP1(connectionID))

            var actionAfterCreation: HTTPConnectionPool.StateMachine.Action?
            XCTAssertNoThrow(actionAfterCreation = try state.newHTTP1ConnectionCreated(XCTUnwrap(newConnection)))
            XCTAssertEqual(actionAfterCreation?.connection, .some(.none))
            XCTAssertEqual(actionAfterCreation?.task, try .executeTask(request, XCTUnwrap(newConnection), cancelWaiter: waiterID))

            XCTAssertNoThrow(try connections.execute(waiters.get(waiterID, task: request), on: XCTUnwrap(newConnection)))
            XCTAssertNoThrow(try connections.finishExecution(connectionID))

            let actionAfterRequest = state.http1ConnectionReleased(connectionID)

            XCTAssertEqual(actionAfterRequest.connection, .scheduleTimeoutTimer(connectionID))
            XCTAssertEqual(actionAfterRequest.task, .none)

            XCTAssertNoThrow(try connections.parkConnection(connectionID))
        }

        XCTAssertEqual(connections.parked, 8)
    }

    func testWaitersAreCreatedIfAllConnectionsAreInUseAndWaitersAreDequeuedInOrder() {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 4)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }

        guard var (connections, state) = try? MockConnections.http1(elg: elg, numberOfConnections: 8) else {
            return XCTFail("Test setup failed")
        }

        XCTAssertEqual(connections.parked, 8)

        // Add eight requests to fill all connections
        for _ in 0..<8 {
            let eventLoop = elg.next()
            guard let expectedConnection = connections.newestParkedConnection(for: eventLoop) ?? connections.newestParkedConnection else {
                return XCTFail("Expected to still have connections available")
            }

            let request = MockHTTPRequestTask(eventLoop: eventLoop)
            let action = state.executeTask(request, onPreffered: request.eventLoop, required: false)

            XCTAssertEqual(action.connection, .cancelTimeoutTimer(expectedConnection.id))
            guard case .executeTask(let returnedRequest, expectedConnection, cancelWaiter: nil) = action.task else {
                return XCTFail("Expected to execute a task next, but got: \(action.task)")
            }

            XCTAssert(request === returnedRequest)

            XCTAssertNoThrow(try connections.activateConnection(expectedConnection.id))
            XCTAssertNoThrow(try connections.execute(request, on: expectedConnection))
        }

        // Add 100 requests to fill waiters
        var waitersOrder = CircularBuffer<MockWaiters.Waiter.ID>()
        var waiters = MockWaiters()
        for _ in 0..<100 {
            let eventLoop = elg.next()

            // in 10% of the cases, we require an explicit EventLoop.
            let elRequired = (0..<10).randomElement().flatMap { $0 == 0 ? true : false }!
            let request = MockHTTPRequestTask(eventLoop: eventLoop, requiresEventLoopForChannel: elRequired)
            let action = state.executeTask(request, onPreffered: request.eventLoop, required: elRequired)

            XCTAssertEqual(action.connection, .none)
            guard case .scheduleWaiterTimeout(let waiterID, let requestToWait, on: let waiterEL) = action.task else {
                return XCTFail("Unexpected task action: \(action.task)")
            }

            XCTAssert(request === requestToWait)
            XCTAssert(waiterEL === request.eventLoop)

            XCTAssertNoThrow(try waiters.wait(request, id: waiterID))
            waitersOrder.append(waiterID)
        }

        while let connection = connections.randomLeasedConnection() {
            XCTAssertNoThrow(try connections.finishExecution(connection.id))
            let action = state.http1ConnectionReleased(connection.id)

            switch action.connection {
            case .scheduleTimeoutTimer(connection.id):
                // if all waiters are processed, the connection will be parked
                XCTAssert(waitersOrder.isEmpty)
                XCTAssertEqual(action.task, .none)
                XCTAssertNoThrow(try connections.parkConnection(connection.id))
            case .replaceConnection(let oldConnection, with: let newConnectionID, on: let newEventLoop):
                XCTAssertEqual(connection, oldConnection)
                XCTAssert(connection.eventLoop !== newEventLoop)
                XCTAssertEqual(action.task, .none)
                XCTAssertNoThrow(try connections.closeConnection(connection))
                XCTAssertNoThrow(try connections.createConnection(newConnectionID, on: newEventLoop))

                var maybeNewConnection: HTTPConnectionPool.Connection?
                XCTAssertNoThrow(maybeNewConnection = try connections.succeedConnectionCreationHTTP1(newConnectionID))
                guard let newConnection = maybeNewConnection else { return XCTFail("Expected to get a new connection") }
                let actionAfterReplacement = state.newHTTP1ConnectionCreated(newConnection)
                XCTAssertEqual(actionAfterReplacement.connection, .none)
                guard case .executeTask(let task, newConnection, cancelWaiter: .some(let waiterID)) = actionAfterReplacement.task else {
                    return XCTFail("Unexpected task action: \(actionAfterReplacement.task)")
                }
                XCTAssertEqual(waiterID, waitersOrder.popFirst())
                XCTAssertNoThrow(try connections.execute(waiters.get(waiterID, task: task), on: newConnection))
            case .none:
                guard case .executeTask(let task, connection, cancelWaiter: .some(let waiterID)) = action.task else {
                    return XCTFail("Unexpected task action: \(action.task)")
                }
                XCTAssertEqual(waiterID, waitersOrder.popFirst())
                XCTAssertNoThrow(try connections.execute(waiters.get(waiterID, task: task), on: connection))

            default:
                XCTFail("Unexpected connection action: \(action)")
            }
        }

        XCTAssertEqual(connections.parked, 8)
        XCTAssert(waiters.isEmpty)
    }

    func testBestConnectionIsPicked() {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 64)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }

        guard var (connections, state) = try? MockConnections.http1(elg: elg, numberOfConnections: 8) else {
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
            let elRequired = (0..<10).randomElement().flatMap { $0 == 0 ? true : false }!
            let request = MockHTTPRequestTask(eventLoop: eventLoop, requiresEventLoopForChannel: elRequired)

            let action = state.executeTask(request, onPreffered: request.eventLoop, required: elRequired)

            guard let expectedConnection = connections.newestParkedConnection(for: eventLoop) ?? connections.newestParkedConnection else {
                return XCTFail("Expected to have connections available")
            }

            switch action.connection {
            case .cancelTimeoutTimer(let connectionID):
                XCTAssertEqual(connectionID, expectedConnection.id, "Task is scheduled on the connection we expected")
                XCTAssertNoThrow(try connections.activateConnection(connectionID))

                guard case .executeTask(let request, let connection, cancelWaiter: nil) = action.task else {
                    return XCTFail("Expected to execute a task, but got: \(action.task)")
                }
                XCTAssertEqual(connection, expectedConnection)
                XCTAssertNoThrow(try connections.execute(request, on: connection))
                XCTAssertNoThrow(try connections.finishExecution(connection.id))

                XCTAssertEqual(state.http1ConnectionReleased(connection.id), .init(.none, .scheduleTimeoutTimer(connectionID)))
                XCTAssertNoThrow(try connections.parkConnection(connectionID))

            case .replaceConnection(let oldConnection, with: let newConnectionID, on: let newConnectionEL):
                guard case .scheduleWaiterTimeout(let waiterID, let requestToWait, on: let waiterEL) = action.task else {
                    return XCTFail("Unexpected task action: \(action.task)")
                }
                XCTAssert(request === requestToWait)
                XCTAssert(request.eventLoop === newConnectionEL)
                XCTAssert(request.eventLoop === waiterEL)
                XCTAssert(oldConnection.eventLoop !== newConnectionEL,
                          "Ensure the connection is recreated on another EL")
                XCTAssertNoThrow(try connections.closeConnection(oldConnection))
                XCTAssertNoThrow(try connections.createConnection(newConnectionID, on: newConnectionEL))

                var maybeNewConnection: HTTPConnectionPool.Connection?
                XCTAssertNoThrow(maybeNewConnection = try connections.succeedConnectionCreationHTTP1(newConnectionID))
                guard let newConnection = maybeNewConnection else { return XCTFail("Expected to get a new connection") }

                let actionAfterReplacement = state.newHTTP1ConnectionCreated(newConnection)
                XCTAssertEqual(actionAfterReplacement.connection, .none)
                XCTAssertEqual(actionAfterReplacement.task, .executeTask(request, newConnection, cancelWaiter: waiterID))
                XCTAssertNoThrow(try connections.execute(request, on: newConnection))
                XCTAssertNoThrow(try connections.finishExecution(newConnectionID))

                XCTAssertEqual(state.http1ConnectionReleased(newConnectionID), .init(.none, .scheduleTimeoutTimer(newConnectionID)))
                XCTAssertNoThrow(try connections.parkConnection(newConnectionID))
            default:
                XCTFail("Unexpected connection action in iteration \(index): \(action.connection)")
            }
        }

        XCTAssertEqual(connections.parked, 8)
    }

    func testConnectionAbortIsIgnoredIfThereAreNoWaiters() {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }

        guard var (connections, state) = try? MockConnections.http1(elg: elg, numberOfConnections: 8) else {
            return XCTFail("Test setup failed")
        }

        XCTAssertEqual(connections.parked, 8)

        // close a leased connection == abort
        let request = MockHTTPRequestTask(eventLoop: elg.next())
        guard let connectionToAbort = connections.newestParkedConnection else {
            return XCTFail("Expected to have a parked connection")
        }
        let action = state.executeTask(request, onPreffered: request.eventLoop, required: false)
        XCTAssertEqual(action.connection, .cancelTimeoutTimer(connectionToAbort.id))
        XCTAssertNoThrow(try connections.activateConnection(connectionToAbort.id))
        XCTAssertEqual(action.task, .executeTask(request, connectionToAbort, cancelWaiter: nil))
        XCTAssertNoThrow(try connections.execute(request, on: connectionToAbort))
        XCTAssertEqual(connections.parked, 7)
        XCTAssertEqual(connections.leased, 1)
        XCTAssertNoThrow(try connections.abortConnection(connectionToAbort.id))
        XCTAssertEqual(state.connectionClosed(connectionToAbort.id), .init(.none, .none))
        XCTAssertEqual(connections.parked, 7)
        XCTAssertEqual(connections.leased, 0)
    }

    func testConnectionCloseLeadsToTumbleWeedIfThereNoWaiters() {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }

        guard var (connections, state) = try? MockConnections.http1(elg: elg, numberOfConnections: 8) else {
            return XCTFail("Test setup failed")
        }

        XCTAssertEqual(connections.parked, 8)

        // close a parked connection
        guard let connectionToClose = connections.randomParkedConnection() else {
            return XCTFail("Expected to have a parked connection")
        }
        XCTAssertNoThrow(try connections.closeConnection(connectionToClose))
        XCTAssertEqual(state.connectionClosed(connectionToClose.id), .init(.none, .none))
        XCTAssertEqual(connections.parked, 7)
    }

    func testConnectionAbortLeadsToNewConnectionsIfThereAreWaiters() {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 8)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }

        guard var (connections, state) = try? MockConnections.http1(elg: elg, numberOfConnections: 8) else {
            return XCTFail("Test setup failed")
        }

        XCTAssertEqual(connections.parked, 8)

        // Add eight requests to fill all connections
        for _ in 0..<8 {
            let eventLoop = elg.next()
            guard let expectedConnection = connections.newestParkedConnection(for: eventLoop) ?? connections.newestParkedConnection else {
                return XCTFail("Expected to still have connections available")
            }

            let request = MockHTTPRequestTask(eventLoop: eventLoop)
            let action = state.executeTask(request, onPreffered: request.eventLoop, required: false)

            XCTAssertEqual(action.connection, .cancelTimeoutTimer(expectedConnection.id))
            XCTAssertEqual(action.task, .executeTask(request, expectedConnection, cancelWaiter: nil))

            XCTAssertNoThrow(try connections.activateConnection(expectedConnection.id))
            XCTAssertNoThrow(try connections.execute(request, on: expectedConnection))
        }

        // Add 100 requests to fill waiters
        var waitersOrder = CircularBuffer<MockWaiters.Waiter.ID>()
        var waiters = MockWaiters()
        for _ in 0..<100 {
            let eventLoop = elg.next()

            // in 10% of the cases, we require an explicit EventLoop.
            let elRequired = (0..<10).randomElement().flatMap { $0 == 0 ? true : false }!
            let request = MockHTTPRequestTask(eventLoop: eventLoop, requiresEventLoopForChannel: elRequired)
            let action = state.executeTask(request, onPreffered: request.eventLoop, required: elRequired)

            XCTAssertEqual(action.connection, .none)
            guard case .scheduleWaiterTimeout(let waiterID, let requestToWait, on: let waiterEL) = action.task else {
                return XCTFail("Unexpected task action: \(action.task)")
            }

            XCTAssert(request === requestToWait)
            XCTAssert(request.eventLoop === waiterEL)
            XCTAssertNoThrow(try waiters.wait(request, id: waiterID))
            waitersOrder.append(waiterID)
        }

        while let closedConnection = connections.randomLeasedConnection() {
            XCTAssertNoThrow(try connections.abortConnection(closedConnection.id))
            XCTAssertEqual(connections.parked, 0)
            let action = state.connectionClosed(closedConnection.id)

            switch action.connection {
            case .createConnection(let newConnectionID, on: let eventLoop):
                XCTAssertEqual(action.task, .none)
                XCTAssertNoThrow(try connections.createConnection(newConnectionID, on: eventLoop))
                XCTAssertEqual(connections.starting, 1)

                var maybeNewConnection: HTTPConnectionPool.Connection?
                XCTAssertNoThrow(maybeNewConnection = try connections.succeedConnectionCreationHTTP1(newConnectionID))
                guard let newConnection = maybeNewConnection else { return XCTFail("Expected to get a new connection") }
                let afterRecreationAction = state.newHTTP1ConnectionCreated(newConnection)
                XCTAssertEqual(afterRecreationAction.connection, .none)
                guard case .executeTask(let task, newConnection, cancelWaiter: .some(let waiterID)) = afterRecreationAction.task else {
                    return XCTFail("Unexpected task action: \(action.task)")
                }

                XCTAssertEqual(waiterID, waitersOrder.popFirst())
                XCTAssertNoThrow(try connections.execute(waiters.get(waiterID, task: task), on: newConnection))

            case .none:
                XCTAssert(waiters.isEmpty)
            default:
                XCTFail("Unexpected connection action: \(action.connection)")
            }
        }
    }

    func testParkedConnectionTimesOut() {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }

        guard var (connections, state) = try? MockConnections.http1(elg: elg, numberOfConnections: 1) else {
            return XCTFail("Test setup failed")
        }

        guard let connection = connections.randomParkedConnection() else {
            return XCTFail("Expected to have one parked connection")
        }

        let action = state.connectionTimeout(connection.id)
        XCTAssertEqual(action.connection, .closeConnection(connection, isShutdown: .no))
        XCTAssertEqual(action.task, .none)
        XCTAssertNoThrow(try connections.closeConnection(connection))
    }

    func testConnectionPoolFullOfParkedConnectionsIsShutdownImmidiatly() {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 8)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }

        guard var (connections, state) = try? MockConnections.http1(elg: elg, numberOfConnections: 8) else {
            return XCTFail("Test setup failed")
        }

        XCTAssertEqual(connections.parked, 8)
        let action = state.shutdown()
        XCTAssertEqual(.none, action.task)

        guard case .cleanupConnection(close: let close, cancel: [], isShutdown: .yes(unclean: false)) = action.connection else {
            return XCTFail("Unexpected connection event: \(action.connection)")
        }

        XCTAssertEqual(close.count, 8)

        for connection in close {
            XCTAssertNoThrow(try connections.closeConnection(connection))
        }

        XCTAssertEqual(connections.count, 0)
    }

    func testParkedConnectionTimesOutButIsAlsoClosedByRemote() {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }

        guard var (connections, state) = try? MockConnections.http1(elg: elg, numberOfConnections: 1) else {
            return XCTFail("Test setup failed")
        }

        guard let connection = connections.randomParkedConnection() else {
            return XCTFail("Expected to have one parked connection")
        }

        // triggered by remote peer
        XCTAssertNoThrow(try connections.abortConnection(connection.id))
        XCTAssertEqual(state.connectionClosed(connection.id), .init(.none, .none))

        // triggered by timer
        XCTAssertEqual(state.connectionTimeout(connection.id), .init(.none, .none))
    }
}
