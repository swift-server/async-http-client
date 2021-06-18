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

extension HTTPConnectionPool.StateMachine.Action: Equatable {
    public static func == (lhs: HTTPConnectionPool.StateMachine.Action, rhs: HTTPConnectionPool.StateMachine.Action) -> Bool {
        lhs.connection == rhs.connection && lhs.task == rhs.task
    }
}

extension HTTPConnectionPool.StateMachine.TaskAction: Equatable {
    public static func == (lhs: HTTPConnectionPool.StateMachine.TaskAction, rhs: HTTPConnectionPool.StateMachine.TaskAction) -> Bool {
        switch (lhs, rhs) {
        case (.executeTask(let lhsTask, let lhsConnectionID, cancelWaiter: let lhsWaiterID),
              .executeTask(let rhsTask, let rhsConnectionID, cancelWaiter: let rhsWaiterID)):
            return lhsTask === rhsTask && lhsConnectionID == rhsConnectionID && lhsWaiterID == rhsWaiterID

        case (.executeTasks(let lhsTasks, let lhsConnection), .executeTasks(let rhsTasks, let rhsConnection)):
            guard lhsConnection == rhsConnection else {
                return false
            }
            guard lhsTasks.count == rhsTasks.count else {
                return false
            }

            var lhsIter = lhsTasks.makeIterator()
            var rhsIter = rhsTasks.makeIterator()

            while let (lhsTask, lhsWaiterID) = lhsIter.next(), let (rhsTask, rhsWaiterID) = rhsIter.next() {
                guard lhsTask === rhsTask, lhsWaiterID == rhsWaiterID else {
                    return false
                }
            }
            return true

        case (.failTask(let lhsTask, _, let lhsWaiterID), .failTask(let rhsTask, _, let rhsWaiterID)):
            return lhsTask === rhsTask && lhsWaiterID == rhsWaiterID
        case (.failTasks(let lhsTasks, _), .failTasks(let rhsTasks, _)):
            guard lhsTasks.count == rhsTasks.count else {
                return false
            }

            var lhsIter = lhsTasks.makeIterator()
            var rhsIter = rhsTasks.makeIterator()

            while let (lhsTask, lhsWaiterID) = lhsIter.next(), let (rhsTask, rhsWaiterID) = rhsIter.next() {
                guard lhsTask === rhsTask, lhsWaiterID == rhsWaiterID else {
                    return false
                }
            }
            return true

        case (.scheduleWaiterTimeout(let lhsWaiterID, let lhsTask, on: let lhsEventLoop), .scheduleWaiterTimeout(let rhsWaiterID, let rhsTask, on: let rhsEventLoop)):
            return lhsWaiterID == rhsWaiterID && lhsTask === rhsTask && lhsEventLoop === rhsEventLoop
        case (.cancelWaiterTimeout(let lhsWaiterID), .cancelWaiterTimeout(let rhsWaiterID)):
            return lhsWaiterID == rhsWaiterID

        case (.none, .none):
            return true

        default:
            return false
        }
    }
}

extension HTTPConnectionPool.StateMachine.ConnectionAction: Equatable {
    public static func == (lhs: HTTPConnectionPool.StateMachine.ConnectionAction, rhs: HTTPConnectionPool.StateMachine.ConnectionAction) -> Bool {
        switch (lhs, rhs) {
        case (.createConnection(let lhsConnectionID, let lhsEventLoop), .createConnection(let rhsConnectionID, let rhsEventLoop)):
            return (lhsEventLoop === rhsEventLoop) && (lhsConnectionID == rhsConnectionID)
        case (.closeConnection(let lhsConnection, let lhsShutdown), .closeConnection(let rhsConnection, let rhsShutdown)):
            return lhsConnection == rhsConnection && lhsShutdown == rhsShutdown
        case (.scheduleTimeoutTimer(let lhsConnectionID), .scheduleTimeoutTimer(let rhsConnectionID)):
            return lhsConnectionID == rhsConnectionID
        case (.cancelTimeoutTimer(let lhsConnectionID), .cancelTimeoutTimer(let rhsConnectionID)):
            return lhsConnectionID == rhsConnectionID
        case (.none, .none):
            return true
        default:
            return false
        }
    }
}
