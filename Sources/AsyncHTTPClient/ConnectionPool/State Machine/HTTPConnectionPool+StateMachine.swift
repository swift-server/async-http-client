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

            case migration(
                createConnections: [(Connection.ID, EventLoop)],
                closeConnections: [Connection],
                scheduleTimeout: (Connection.ID, EventLoop)?,
                isShutdown: IsShutdown
            )

            case none
        }

        enum RequestAction {
            case executeRequest(Request, Connection, cancelTimeout: Bool)
            case executeRequestsAndCancelTimeouts([Request], Connection)

            case failRequest(Request, Error, cancelTimeout: Bool)
            case failRequestsAndCancelTimeouts([Request], Error)

            case scheduleRequestTimeout(for: Request, on: EventLoop)
            case cancelRequestTimeout(Request.ID)

            case none
        }

        enum HTTPVersionState {
            case http1(HTTP1StateMachine)
            case http2(HTTP2StateMachine)

            mutating func modify<ReturnValue>(
                http1: (inout HTTP1StateMachine) -> ReturnValue,
                http2: (inout HTTP2StateMachine) -> ReturnValue
            ) -> ReturnValue {
                let returnValue: ReturnValue
                switch self {
                case .http1(var http1State):
                    returnValue = http1(&http1State)
                    self = .http1(http1State)
                case .http2(var http2State):
                    returnValue = http2(&http2State)
                    self = .http2(http2State)
                }
                return returnValue
            }
        }

        var state: HTTPVersionState
        var isShuttingDown: Bool = false

        let idGenerator: Connection.ID.Generator
        let maximumConcurrentHTTP1Connections: Int

        init(idGenerator: Connection.ID.Generator, maximumConcurrentHTTP1Connections: Int) {
            self.maximumConcurrentHTTP1Connections = maximumConcurrentHTTP1Connections
            self.idGenerator = idGenerator
            let http1State = HTTP1StateMachine(
                idGenerator: idGenerator,
                maximumConcurrentConnections: maximumConcurrentHTTP1Connections
            )
            self.state = .http1(http1State)
        }

        mutating func executeRequest(_ request: Request) -> Action {
            switch self.state {
            case .http1(var http1StateMachine):
                let action = http1StateMachine.executeRequest(request)
                self.state = .http1(http1StateMachine)
                return action
            }
        }

        mutating func newHTTP1ConnectionCreated(_ connection: Connection) -> Action {
            switch self.state {
            case .http1(var http1StateMachine):
                let action = http1StateMachine.newHTTP1ConnectionEstablished(connection)
                self.state = .http1(http1StateMachine)
                return action
            }
        }

        mutating func failedToCreateNewConnection(_ error: Error, connectionID: Connection.ID) -> Action {
            switch self.state {
            case .http1(var http1StateMachine):
                let action = http1StateMachine.failedToCreateNewConnection(
                    error,
                    connectionID: connectionID
                )
                self.state = .http1(http1StateMachine)
                return action
            }
        }

        mutating func connectionCreationBackoffDone(_ connectionID: Connection.ID) -> Action {
            switch self.state {
            case .http1(var http1StateMachine):
                let action = http1StateMachine.connectionCreationBackoffDone(connectionID)
                self.state = .http1(http1StateMachine)
                return action
            }
        }

        /// A request has timed out.
        ///
        /// This is different to a request being cancelled. If a request times out, we need to fail the
        /// request, but don't need to cancel the timer (it already triggered). If a request is cancelled
        /// we don't need to fail it but we need to cancel its timeout timer.
        mutating func timeoutRequest(_ requestID: Request.ID) -> Action {
            switch self.state {
            case .http1(var http1StateMachine):
                let action = http1StateMachine.timeoutRequest(requestID)
                self.state = .http1(http1StateMachine)
                return action
            }
        }

        /// A request was cancelled.
        ///
        /// This is different to a request timing out. If a request is cancelled we don't need to fail it but we
        /// need to cancel its timeout timer. If a request times out, we need to fail the request, but don't
        /// need to cancel the timer (it already triggered).
        mutating func cancelRequest(_ requestID: Request.ID) -> Action {
            switch self.state {
            case .http1(var http1StateMachine):
                let action = http1StateMachine.cancelRequest(requestID)
                self.state = .http1(http1StateMachine)
                return action
            }
        }

        mutating func connectionIdleTimeout(_ connectionID: Connection.ID) -> Action {
            switch self.state {
            case .http1(var http1StateMachine):
                let action = http1StateMachine.connectionIdleTimeout(connectionID)
                self.state = .http1(http1StateMachine)
                return action
            }
        }

        /// A connection has been closed
        mutating func http1ConnectionClosed(_ connectionID: Connection.ID) -> Action {
            switch self.state {
            case .http1(var http1StateMachine):
                let action = http1StateMachine.http1ConnectionClosed(connectionID)
                self.state = .http1(http1StateMachine)
                return action
            }
        }

        mutating func http1ConnectionReleased(_ connectionID: Connection.ID) -> Action {
            switch self.state {
            case .http1(var http1StateMachine):
                let action = http1StateMachine.http1ConnectionReleased(connectionID)
                self.state = .http1(http1StateMachine)
                return action
            }
        }

        mutating func shutdown() -> Action {
            precondition(!self.isShuttingDown, "Shutdown must only be called once")

            self.isShuttingDown = true

            switch self.state {
            case .http1(var http1StateMachine):
                let action = http1StateMachine.shutdown()
                self.state = .http1(http1StateMachine)
                return action
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

extension HTTPConnectionPool.StateMachine: CustomStringConvertible {
    var description: String {
        switch self.state {
        case .http1(let http1):
            return ".http1(\(http1))"
extension HTTPConnectionPool.StateMachine {
    struct ConnectionMigrationAction {
        var closeConnections: [HTTPConnectionPool.Connection]
        var createConnections: [(HTTPConnectionPool.Connection.ID, EventLoop)]
    }

    struct EstablishedAction {
        static let none: Self = .init(request: .none, connection: .none)
        let request: HTTPConnectionPool.StateMachine.RequestAction
        let connection: EstablishedConnectionAction

        var asStateMachineAction: HTTPConnectionPool.StateMachine.Action {
            return .init(self)
        }
    }

    enum EstablishedConnectionAction {
        case none
        case scheduleTimeoutTimer(HTTPConnectionPool.Connection.ID, on: EventLoop)
        case closeConnection(HTTPConnectionPool.Connection, isShutdown: HTTPConnectionPool.StateMachine.ConnectionAction.IsShutdown)
    }
}

extension HTTPConnectionPool.StateMachine.Action {
    init(_ action: HTTPConnectionPool.StateMachine.EstablishedAction) {
        self.init(
            request: action.request,
            connection: .init(action.connection)
        )
    }
}

extension HTTPConnectionPool.StateMachine.ConnectionAction {
    init(_ action: HTTPConnectionPool.StateMachine.EstablishedConnectionAction) {
        switch action {
        case .none:
            self = .none
        case .scheduleTimeoutTimer(let connectionID, let eventLoop):
            self = .scheduleTimeoutTimer(connectionID, on: eventLoop)
        case .closeConnection(let connection, let isShutdown):
            self = .closeConnection(connection, isShutdown: isShutdown)
        }
    }
}

extension HTTPConnectionPool.StateMachine.ConnectionAction {
    static func combined(
        _ migrationAction: HTTPConnectionPool.StateMachine.ConnectionMigrationAction,
        _ establishedAction: HTTPConnectionPool.StateMachine.EstablishedConnectionAction
    ) -> Self {
        switch establishedAction {
        case .none:
            return .migration(
                createConnections: migrationAction.createConnections,
                closeConnections: migrationAction.closeConnections,
                scheduleTimeout: nil,
                isShutdown: .no
            )
        case .closeConnection(let connection, let isShutdown):
            return .migration(
                createConnections: migrationAction.createConnections,
                closeConnections: migrationAction.closeConnections + CollectionOfOne(connection),
                scheduleTimeout: nil,
                isShutdown: isShutdown
            )
        case .scheduleTimeoutTimer(let connectionID, let eventLoop):
            return .migration(
                createConnections: migrationAction.createConnections,
                closeConnections: migrationAction.closeConnections,
                scheduleTimeout: (connectionID, eventLoop),
                isShutdown: .no
            )
        }
    }
}
