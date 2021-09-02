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

import NIO
import NIOHTTP1

extension HTTPConnectionPool {
    struct StateMachine {
        struct Action {
            let request: RequestAction
            let connection: ConnectionAction

            init(request: RequestAction, connection: ConnectionAction) {
                self.request = request
                self.connection = connection
            }

            static let none: Action = Action(request: .none, connection: .none)
        }

        enum ConnectionAction {
            enum IsShutdown: Equatable {
                case yes(unclean: Bool)
                case no
            }

            case createConnection(Connection.ID, on: EventLoop)
            case scheduleBackoffTimer(Connection.ID, backoff: TimeAmount, on: EventLoop)

            case scheduleTimeoutTimer(Connection.ID, on: EventLoop)
            case cancelTimeoutTimer(Connection.ID)

            case closeConnection(Connection, isShutdown: IsShutdown)
            case cleanupConnections(CleanupContext, isShutdown: IsShutdown)

            case none
        }

        enum RequestAction {
            case executeRequest(Request, Connection, cancelWaiter: Request.ID?)
            case executeRequests([(Request, cancelWaiter: Request.ID?)], Connection)

            case failRequest(Request, Error, cancelWaiter: Request.ID?)
            case failRequests([(Request, cancelWaiter: Request.ID?)], Error)

            case scheduleRequestTimeout(NIODeadline?, for: Request.ID, on: EventLoop)
            case cancelRequestTimeout(Request.ID)

            case none
        }

        enum HTTPTypeStateMachine {
            case http1(HTTP1StateMachine)

            case _modifying
        }

        var state: HTTPTypeStateMachine
        var isShuttingDown: Bool = false

        let eventLoopGroup: EventLoopGroup
        let maximumConcurrentHTTP1Connections: Int

        init(eventLoopGroup: EventLoopGroup, idGenerator: Connection.ID.Generator, maximumConcurrentHTTP1Connections: Int) {
            self.maximumConcurrentHTTP1Connections = maximumConcurrentHTTP1Connections
            let http1State = HTTP1StateMachine(
                idGenerator: idGenerator,
                maximumConcurrentConnections: maximumConcurrentHTTP1Connections
            )
            self.state = .http1(http1State)
            self.eventLoopGroup = eventLoopGroup
        }

        mutating func executeRequest(_ request: Request) -> Action {
            switch self.state {
            case .http1(var http1StateMachine):
                return self.state.modify { state -> Action in
                    let action = http1StateMachine.executeRequest(request)
                    state = .http1(http1StateMachine)
                    return action
                }

            case ._modifying:
                preconditionFailure("Invalid state: \(self.state)")
            }
        }

        mutating func newHTTP1ConnectionCreated(_ connection: Connection) -> Action {
            switch self.state {
            case .http1(var httpStateMachine):
                return self.state.modify { state -> Action in
                    let action = httpStateMachine.newHTTP1ConnectionEstablished(connection)
                    state = .http1(httpStateMachine)
                    return action
                }

            case ._modifying:
                preconditionFailure("Invalid state: \(self.state)")
            }
        }

        mutating func failedToCreateNewConnection(_ error: Error, connectionID: Connection.ID) -> Action {
            switch self.state {
            case .http1(var http1StateMachine):
                return self.state.modify { state -> Action in
                    let action = http1StateMachine.failedToCreateNewConnection(
                        error,
                        connectionID: connectionID
                    )
                    state = .http1(http1StateMachine)
                    return action
                }

            case ._modifying:
                preconditionFailure("Invalid state: \(self.state)")
            }
        }

        mutating func connectionCreationBackoffDone(_ connectionID: Connection.ID) -> Action {
            switch self.state {
            case .http1(var http1StateMachine):
                return self.state.modify { state -> Action in
                    let action = http1StateMachine.connectionCreationBackoffDone(connectionID)
                    state = .http1(http1StateMachine)
                    return action
                }

            case ._modifying:
                preconditionFailure("Invalid state: \(self.state)")
            }
        }

        mutating func waiterTimeout(_ requestID: Request.ID) -> Action {
            switch self.state {
            case .http1(var http1StateMachine):
                return self.state.modify { state -> Action in
                    let action = http1StateMachine.timeoutWaiter(requestID)
                    state = .http1(http1StateMachine)
                    return action
                }

            case ._modifying:
                preconditionFailure("Invalid state: \(self.state)")
            }
        }

        mutating func cancelRequest(_ requestID: Request.ID) -> Action {
            switch self.state {
            case .http1(var http1StateMachine):
                return self.state.modify { state -> Action in
                    let action = http1StateMachine.cancelRequest(requestID)
                    state = .http1(http1StateMachine)
                    return action
                }

            case ._modifying:
                preconditionFailure("Invalid state: \(self.state)")
            }
        }

        mutating func connectionIdleTimeout(_ connectionID: Connection.ID) -> Action {
            switch self.state {
            case .http1(var http1StateMachine):
                return self.state.modify { state -> Action in
                    let action = http1StateMachine.connectionIdleTimeout(connectionID)
                    state = .http1(http1StateMachine)
                    return action
                }

            case ._modifying:
                preconditionFailure("Invalid state: \(self.state)")
            }
        }

        /// A connection has been closed
        mutating func connectionClosed(_ connectionID: Connection.ID) -> Action {
            switch self.state {
            case .http1(var http1StateMachine):
                return self.state.modify { state -> Action in
                    let action = http1StateMachine.connectionClosed(connectionID)
                    state = .http1(http1StateMachine)
                    return action
                }

            case ._modifying:
                preconditionFailure("Invalid state: \(self.state)")
            }
        }

        mutating func http1ConnectionReleased(_ connectionID: Connection.ID) -> Action {
            guard case .http1(var http1StateMachine) = self.state else {
                preconditionFailure("Invalid state: \(self.state)")
            }

            return self.state.modify { state -> Action in
                let action = http1StateMachine.http1ConnectionReleased(connectionID)
                state = .http1(http1StateMachine)
                return action
            }
        }

        mutating func shutdown() -> Action {
            guard !self.isShuttingDown else {
                preconditionFailure("Shutdown must only be called once")
            }

            self.isShuttingDown = true

            switch self.state {
            case .http1(var http1StateMachine):
                return self.state.modify { state -> Action in
                    let action = http1StateMachine.shutdown()
                    state = .http1(http1StateMachine)
                    return action
                }

            case ._modifying:
                preconditionFailure("Invalid state: \(self.state)")
            }
        }
    }
}

extension HTTPConnectionPool {
    /// The pool cleanup todo list.
    struct CleanupContext: Equatable {
        /// the connections to close right away. These are idle.
        var close: [Connection]

        /// the connections that currently run a request that needs to be cancelled to close the connections
        var cancel: [Connection]

        /// the connections that are backing off from connection creation
        var connectBackoff: [Connection.ID]

        init(close: [Connection] = [], cancel: [Connection] = [], connectBackoff: [Connection.ID] = []) {
            self.close = close
            self.cancel = cancel
            self.connectBackoff = connectBackoff
        }
    }
}

extension HTTPConnectionPool.StateMachine.HTTPTypeStateMachine {
    mutating func modify<T>(_ closure: (inout Self) throws -> (T)) rethrows -> T {
        self = ._modifying
        defer {
            if case ._modifying = self {
                preconditionFailure("Invalid state. Use closure to modify state")
            }
        }
        return try closure(&self)
    }
}

extension HTTPConnectionPool.StateMachine: CustomStringConvertible {
    var description: String {
        switch self.state {
        case .http1(let http1):
            return ".http1(\(http1))"

        case ._modifying:
            preconditionFailure("Invalid state: \(self.state)")
        }
    }
}
