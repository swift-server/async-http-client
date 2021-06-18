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

class HTTPConnectionPool_StateMachineTests: XCTestCase {
    func testCreatingAndFailingConnections() {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 4)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }
        var state = HTTPConnectionPool.StateMachine(
            eventLoopGroup: elg,
            idGenerator: .init(),
            maximumConcurrentHTTP1Connections: 8
        )

        var openingConnections = Set<HTTPConnectionPool.Connection.ID>()
        var connectionIDWaiter = [HTTPConnectionPool.Connection.ID: HTTPConnectionPool.Waiter.ID]()
        var waiters = CircularBuffer<(HTTPConnectionPool.Waiter.ID, MockHTTPRequestTask)>()

        for _ in 0..<8 {
            let task = MockHTTPRequestTask(eventLoop: elg.next())
            let action = state.executeTask(task, onPreffered: task.eventLoop, required: false)
            guard case .createConnection(let connectionID, let el) = action.connection else {
                return XCTFail("Unexpected connection action")
            }
            guard case .scheduleWaiterTimeout(let waiterID, let taskToWait, on: let waiterEventLoop) = action.task else {
                return XCTFail("Unexpected task action")
            }
            XCTAssert(task === taskToWait)
            XCTAssert(task.eventLoop === waiterEventLoop)

            openingConnections.insert(connectionID)
            connectionIDWaiter[connectionID] = waiterID

            XCTAssertTrue(el === task.eventLoop)
        }

        for _ in 0..<8 {
            let task = MockHTTPRequestTask(eventLoop: elg.next())
            let action = state.executeTask(task, onPreffered: task.eventLoop, required: false)
            guard case .none = action.connection else {
                return XCTFail("Unexpected connection action")
            }
            guard case .scheduleWaiterTimeout(let waiterID, let taskToWait, let waiterEL) = action.task else {
                return XCTFail("Unexpected task action")
            }
            XCTAssert(task === taskToWait)
            XCTAssert(task.eventLoop === waiterEL)

            waiters.append((waiterID, task))
        }

        // fail all connection attempts

        var counter: Int = 0
        while let randomConnectionID = openingConnections.randomElement() {
            counter += 1
            struct SomeError: Error, Equatable {}
            openingConnections.remove(randomConnectionID)
            let action = state.failedToCreateNewConnection(SomeError(), connectionID: randomConnectionID)
            guard case .failTask(_, let error, let waiterID) = action.task, error is SomeError else {
                return XCTFail("Unexpected task action")
            }

            if let newWaiterID = waiters.popFirst() {
                XCTAssertEqual(connectionIDWaiter.removeValue(forKey: randomConnectionID), waiterID)
                guard case .createConnection(let newConnectionID, _) = action.connection else {
                    return XCTFail("Unexpected connection action")
                }

                openingConnections.insert(newConnectionID)
                connectionIDWaiter[newConnectionID] = newWaiterID.0
            } else {
                XCTAssertEqual(connectionIDWaiter.removeValue(forKey: randomConnectionID), waiterID)
                guard case .none = action.connection else {
                    return XCTFail("Unexpected connection action")
                }
            }
        }

        XCTAssertEqual(counter, 16)
        XCTAssert(waiters.isEmpty)
        XCTAssert(openingConnections.isEmpty)
    }

    func testSimpleHTTP1Startup() {
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 4)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }
        var state = HTTPConnectionPool.StateMachine(
            eventLoopGroup: elg,
            idGenerator: .init(),
            maximumConcurrentHTTP1Connections: 8
        )

        let task = MockHTTPRequestTask(eventLoop: elg.next())
        let action = state.executeTask(task, onPreffered: task.eventLoop, required: false)
        guard case .createConnection(let connectionID, let taskEventLoop) = action.connection else {
            return XCTFail("Unexpected connection action")
        }
        guard case .scheduleWaiterTimeout(let waiterID, _, on: let waiterEL) = action.task else {
            return XCTFail("Unexpected task action")
        }
        XCTAssert(task.eventLoop === taskEventLoop)
        XCTAssert(task.eventLoop === waiterEL)

        let newConnection = HTTPConnectionPool.Connection.testing(id: connectionID, eventLoop: taskEventLoop)
        XCTAssertEqual(state.newHTTP1ConnectionCreated(newConnection),
                       .init(.executeTask(task, newConnection, cancelWaiter: waiterID), .none))
        XCTAssertEqual(state.http1ConnectionReleased(connectionID), .init(.none, .scheduleTimeoutTimer(connectionID)))
    }
}
