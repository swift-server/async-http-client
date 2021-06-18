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
@_implementationOnly import NIOHTTP2

extension HTTPConnectionPool {
    struct StateMachine {
        struct Action {
            let task: TaskAction
            let connection: ConnectionAction

            init(_ task: TaskAction, _ connection: ConnectionAction) {
                self.task = task
                self.connection = connection
            }
        }

        enum ConnectionAction {
            enum IsShutdown: Equatable {
                case yes(unclean: Bool)
                case no
            }

            case createConnection(Connection.ID, on: EventLoop)
            case replaceConnection(Connection, with: Connection.ID, on: EventLoop)

            case scheduleTimeoutTimer(Connection.ID)
            case cancelTimeoutTimer(Connection.ID)

            case closeConnection(Connection, isShutdown: IsShutdown)
            case cleanupConnection(close: [Connection], cancel: [Connection], isShutdown: IsShutdown)

            case none
        }

        enum TaskAction {
            case executeTask(HTTPRequestTask, Connection, cancelWaiter: Waiter.ID?)
            case executeTasks([(HTTPRequestTask, cancelWaiter: Waiter.ID?)], Connection)
            case failTask(HTTPRequestTask, Error, cancelWaiter: Waiter.ID?)
            case failTasks([(HTTPRequestTask, cancelWaiter: Waiter.ID?)], Error)

            case scheduleWaiterTimeout(Waiter.ID, HTTPRequestTask, on: EventLoop)
            case cancelWaiterTimeout(Waiter.ID)

            case none
        }

        enum HTTPTypeStateMachine {
            case http1(HTTP1StateMachine)
            case http2(HTTP2StateMachine)

            case modify
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

        mutating func executeTask(_ task: HTTPRequestTask, onPreffered prefferedEL: EventLoop, required: Bool) -> Action {
            switch self.state {
            case .http1(var http1StateMachine):
                return self.state.modify { state -> Action in
                    let action = http1StateMachine.executeTask(task, onPreffered: prefferedEL, required: required)
                    state = .http1(http1StateMachine)
                    return state.modify(with: action)
                }
            case .http2(var http2StateMachine):
                return self.state.modify { state -> Action in
                    let action = http2StateMachine.executeTask(task, onPreffered: prefferedEL, required: required)
                    state = .http2(http2StateMachine)
                    return state.modify(with: action)
                }
            case .modify:
                preconditionFailure("Invalid state")
            }
        }

        mutating func newHTTP1ConnectionCreated(_ connection: Connection) -> Action {
            switch self.state {
            case .http1(var httpStateMachine):
                return self.state.modify { state -> Action in
                    let action = httpStateMachine.newHTTP1ConnectionCreated(connection)
                    state = .http1(httpStateMachine)
                    return state.modify(with: action)
                }

            case .http2:
                preconditionFailure("Unimplemented. Switching back to HTTP/1.1 not supported for now")

            case .modify:
                preconditionFailure("Invalid state")
            }
        }

        mutating func newHTTP2ConnectionCreated(_ connection: Connection, settings: HTTP2Settings) -> Action {
            switch self.state {
            case .http1(let http1StateMachine):
                return self.state.modify { state -> Action in
                    var http2StateMachine = HTTP2StateMachine(
                        http1StateMachine: http1StateMachine,
                        eventLoopGroup: self.eventLoopGroup
                    )

                    let action = http2StateMachine.newHTTP2ConnectionCreated(connection, settings: settings)
                    state = .http2(http2StateMachine)
                    return state.modify(with: action)
                }

            case .http2(var http2StateMachine):
                return self.state.modify { state -> Action in
                    let action = http2StateMachine.newHTTP2ConnectionCreated(connection, settings: settings)
                    state = .http2(http2StateMachine)
                    return state.modify(with: action)
                }

            case .modify:
                preconditionFailure("Invalid state")
            }
        }

        mutating func failedToCreateNewConnection(_ error: Error, connectionID: Connection.ID) -> Action {
            switch self.state {
            case .http1(var http1StateMachine):
                return self.state.modify { state -> Action in
                    let action = http1StateMachine.failedToCreateNewConnection(error, connectionID: connectionID)
                    state = .http1(http1StateMachine)
                    return state.modify(with: action)
                }

            case .http2(var http2StateMachine):
                return self.state.modify { state -> Action in
                    let action = http2StateMachine.failedToCreateNewConnection(error, connectionID: connectionID)
                    state = .http2(http2StateMachine)
                    return state.modify(with: action)
                }

            case .modify:
                preconditionFailure("Invalid state")
            }
        }

        mutating func waiterTimeout(_ waitID: Waiter.ID) -> Action {
            switch self.state {
            case .http1(var http1StateMachine):
                return self.state.modify { state -> Action in
                    let action = http1StateMachine.timeoutWaiter(waitID)
                    state = .http1(http1StateMachine)
                    return state.modify(with: action)
                }
            case .http2(var http2StateMachine):
                return self.state.modify { state -> Action in
                    let action = http2StateMachine.timeoutWaiter(waitID)
                    state = .http2(http2StateMachine)
                    return state.modify(with: action)
                }
            case .modify:
                preconditionFailure("Invalid state")
            }
        }

        mutating func cancelWaiter(_ waitID: Waiter.ID) -> Action {
            switch self.state {
            case .http1(var http1StateMachine):
                return self.state.modify { state -> Action in
                    let action = http1StateMachine.cancelWaiter(waitID)
                    state = .http1(http1StateMachine)
                    return state.modify(with: action)
                }
            case .http2(var http2StateMachine):
                return self.state.modify { state -> Action in
                    let action = http2StateMachine.cancelWaiter(waitID)
                    state = .http2(http2StateMachine)
                    return state.modify(with: action)
                }
            case .modify:
                preconditionFailure("Invalid state")
            }
        }

        mutating func connectionTimeout(_ connectionID: Connection.ID) -> Action {
            switch self.state {
            case .http1(var http1StateMachine):
                return self.state.modify { state -> Action in
                    let action = http1StateMachine.connectionTimeout(connectionID)
                    state = .http1(http1StateMachine)
                    return state.modify(with: action)
                }
            case .http2(var http2StateMachine):
                return self.state.modify { state -> Action in
                    let action = http2StateMachine.connectionTimeout(connectionID)
                    state = .http2(http2StateMachine)
                    return state.modify(with: action)
                }
            case .modify:
                preconditionFailure("Invalid state")
            }
        }

        /// A connection has been closed
        mutating func connectionClosed(_ connectionID: Connection.ID) -> Action {
            switch self.state {
            case .http1(var http1StateMachine):
                return self.state.modify { state -> Action in
                    let action = http1StateMachine.connectionClosed(connectionID)
                    state = .http1(http1StateMachine)
                    return state.modify(with: action)
                }
            case .http2(var http2StateMachine):
                return self.state.modify { state -> Action in
                    let action = http2StateMachine.connectionClosed(connectionID)
                    state = .http2(http2StateMachine)
                    return state.modify(with: action)
                }
            case .modify:
                preconditionFailure("Invalid state")
            }
        }

        mutating func http1ConnectionReleased(_ connectionID: Connection.ID) -> Action {
            guard case .http1(var http1StateMachine) = self.state else {
                preconditionFailure("Invalid state")
            }

            return self.state.modify { state -> Action in
                let action = http1StateMachine.http1ConnectionReleased(connectionID)
                state = .http1(http1StateMachine)
                return state.modify(with: action)
            }
        }

        /// A connection is done processing a task
        mutating func http2ConnectionStreamClosed(_ connectionID: Connection.ID, availableStreams: Int) -> Action {
            switch self.state {
            case .http1:
                preconditionFailure("Unimplemented for now")
            case .http2(var http2StateMachine):
                return self.state.modify { state -> Action in
                    let action = http2StateMachine.http2ConnectionStreamClosed(connectionID, availableStreams: availableStreams)
                    state = .http2(http2StateMachine)
                    return state.modify(with: action)
                }
            case .modify:
                preconditionFailure("Invalid state")
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
                    return state.modify(with: action)
                }
            case .http2(var http2StateMachine):
                return self.state.modify { state -> Action in
                    let action = http2StateMachine.shutdown()
                    state = .http2(http2StateMachine)
                    return state.modify(with: action)
                }
            case .modify:
                preconditionFailure("Invalid state")
            }
        }
    }
}

extension HTTPConnectionPool.StateMachine.HTTPTypeStateMachine {
    mutating func modify<T>(_ closure: (inout Self) throws -> (T)) rethrows -> T {
        self = .modify
        defer {
            if case .modify = self {
                preconditionFailure("Invalid state. Use closure to modify state")
            }
        }
        return try closure(&self)
    }

    mutating func modify(with action: HTTPConnectionPool.StateMachine.Action)
        -> HTTPConnectionPool.StateMachine.Action {
        return action
    }
}

extension HTTPConnectionPool.StateMachine: CustomStringConvertible {
    var description: String {
        switch self.state {
        case .http1(let http1):
            return ".http1(\(http1))"
        case .http2(let http2):
            return ".http2(\(http2))"
        case .modify:
            preconditionFailure("Invalid state")
        }
    }
}
