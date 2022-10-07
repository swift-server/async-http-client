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

            static let none = Action(request: .none, connection: .none)
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
                scheduleTimeout: (Connection.ID, EventLoop)?
            )

            case none
        }

        enum RequestAction {
            case executeRequest(Request, Connection, cancelTimeout: Bool)
            case executeRequestsAndCancelTimeouts([Request], Connection)

            case failRequest(Request, Error, cancelTimeout: Bool)
            case failRequestsAndCancelTimeouts([Request], Error)

            case scheduleRequestTimeout(for: Request, on: EventLoop)

            case none
        }

        enum LifecycleState: Equatable {
            case running
            case shuttingDown(unclean: Bool)
            case shutDown
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

        let idGenerator: Connection.ID.Generator
        let maximumConcurrentHTTP1Connections: Int
        /// The property was introduced to fail fast during testing.
        /// Otherwise this should always be true and not turned off.
        private let retryConnectionEstablishment: Bool

        init(
            idGenerator: Connection.ID.Generator,
            maximumConcurrentHTTP1Connections: Int,
            retryConnectionEstablishment: Bool
        ) {
            self.maximumConcurrentHTTP1Connections = maximumConcurrentHTTP1Connections
            self.retryConnectionEstablishment = retryConnectionEstablishment
            self.idGenerator = idGenerator
            let http1State = HTTP1StateMachine(
                idGenerator: idGenerator,
                maximumConcurrentConnections: maximumConcurrentHTTP1Connections,
                retryConnectionEstablishment: retryConnectionEstablishment,
                lifecycleState: .running
            )
            self.state = .http1(http1State)
        }

        mutating func executeRequest(_ request: Request) -> Action {
            self.state.modify(http1: { http1 in
                http1.executeRequest(request)
            }, http2: { http2 in
                http2.executeRequest(request)
            })
        }

        mutating func newHTTP1ConnectionCreated(_ connection: Connection) -> Action {
            switch self.state {
            case .http1(var http1StateMachine):
                let action = http1StateMachine.newHTTP1ConnectionEstablished(connection)
                self.state = .http1(http1StateMachine)
                return action

            case .http2(let http2StateMachine):
                var http1StateMachine = HTTP1StateMachine(
                    idGenerator: self.idGenerator,
                    maximumConcurrentConnections: self.maximumConcurrentHTTP1Connections,
                    retryConnectionEstablishment: self.retryConnectionEstablishment,
                    lifecycleState: http2StateMachine.lifecycleState
                )

                let newConnectionAction = http1StateMachine.migrateFromHTTP2(
                    http1Connections: http2StateMachine.http1Connections,
                    http2Connections: http2StateMachine.connections,
                    requests: http2StateMachine.requests,
                    newHTTP1Connection: connection
                )
                self.state = .http1(http1StateMachine)
                return newConnectionAction
            }
        }

        mutating func newHTTP2ConnectionCreated(_ connection: Connection, maxConcurrentStreams: Int) -> Action {
            switch self.state {
            case .http1(let http1StateMachine):

                var http2StateMachine = HTTP2StateMachine(
                    idGenerator: self.idGenerator,
                    retryConnectionEstablishment: self.retryConnectionEstablishment,
                    lifecycleState: http1StateMachine.lifecycleState
                )
                let migrationAction = http2StateMachine.migrateFromHTTP1(
                    http1Connections: http1StateMachine.connections,
                    http2Connections: http1StateMachine.http2Connections,
                    requests: http1StateMachine.requests,
                    newHTTP2Connection: connection,
                    maxConcurrentStreams: maxConcurrentStreams
                )

                self.state = .http2(http2StateMachine)
                return migrationAction

            case .http2(var http2StateMachine):
                let newConnectionAction = http2StateMachine.newHTTP2ConnectionEstablished(
                    connection,
                    maxConcurrentStreams: maxConcurrentStreams
                )
                self.state = .http2(http2StateMachine)
                return newConnectionAction
            }
        }

        mutating func newHTTP2MaxConcurrentStreamsReceived(_ connectionID: Connection.ID, newMaxStreams: Int) -> Action {
            self.state.modify(http1: { http1 in
                http1.newHTTP2MaxConcurrentStreamsReceived(connectionID, newMaxStreams: newMaxStreams)
            }, http2: { http2 in
                http2.newHTTP2MaxConcurrentStreamsReceived(connectionID, newMaxStreams: newMaxStreams)
            })
        }

        mutating func http2ConnectionGoAwayReceived(_ connectionID: Connection.ID) -> Action {
            self.state.modify(http1: { http1 in
                http1.http2ConnectionGoAwayReceived(connectionID)
            }, http2: { http2 in
                http2.http2ConnectionGoAwayReceived(connectionID)
            })
        }

        mutating func http2ConnectionClosed(_ connectionID: Connection.ID) -> Action {
            self.state.modify(http1: { http1 in
                http1.http2ConnectionClosed(connectionID)
            }, http2: { http2 in
                http2.http2ConnectionClosed(connectionID)
            })
        }

        mutating func http2ConnectionStreamClosed(_ connectionID: Connection.ID) -> Action {
            self.state.modify(http1: { http1 in
                http1.http2ConnectionStreamClosed(connectionID)
            }, http2: { http2 in
                http2.http2ConnectionStreamClosed(connectionID)
            })
        }

        mutating func failedToCreateNewConnection(_ error: Error, connectionID: Connection.ID) -> Action {
            self.state.modify(http1: { http1 in
                http1.failedToCreateNewConnection(error, connectionID: connectionID)
            }, http2: { http2 in
                http2.failedToCreateNewConnection(error, connectionID: connectionID)
            })
        }

        mutating func waitingForConnectivity(_ error: Error, connectionID: Connection.ID) -> Action {
            self.state.modify(http1: { http1 in
                http1.waitingForConnectivity(error, connectionID: connectionID)
            }, http2: { http2 in
                http2.waitingForConnectivity(error, connectionID: connectionID)
            })
        }

        mutating func connectionCreationBackoffDone(_ connectionID: Connection.ID) -> Action {
            self.state.modify(http1: { http1 in
                http1.connectionCreationBackoffDone(connectionID)
            }, http2: { http2 in
                http2.connectionCreationBackoffDone(connectionID)
            })
        }

        /// A request has timed out.
        ///
        /// This is different to a request being cancelled. If a request times out, we need to fail the
        /// request, but don't need to cancel the timer (it already triggered). If a request is cancelled
        /// we don't need to fail it but we need to cancel its timeout timer.
        mutating func timeoutRequest(_ requestID: Request.ID) -> Action {
            self.state.modify(http1: { http1 in
                http1.timeoutRequest(requestID)
            }, http2: { http2 in
                http2.timeoutRequest(requestID)
            })
        }

        /// A request was cancelled.
        ///
        /// This is different to a request timing out. If a request is cancelled we don't need to fail it but we
        /// need to cancel its timeout timer. If a request times out, we need to fail the request, but don't
        /// need to cancel the timer (it already triggered).
        mutating func cancelRequest(_ requestID: Request.ID) -> Action {
            self.state.modify(http1: { http1 in
                http1.cancelRequest(requestID)
            }, http2: { http2 in
                http2.cancelRequest(requestID)
            })
        }

        mutating func connectionIdleTimeout(_ connectionID: Connection.ID) -> Action {
            self.state.modify(http1: { http1 in
                http1.connectionIdleTimeout(connectionID)
            }, http2: { http2 in
                http2.connectionIdleTimeout(connectionID)
            })
        }

        /// A connection has been closed
        mutating func http1ConnectionClosed(_ connectionID: Connection.ID) -> Action {
            self.state.modify(http1: { http1 in
                http1.http1ConnectionClosed(connectionID)
            }, http2: { http2 in
                http2.http1ConnectionClosed(connectionID)
            })
        }

        mutating func http1ConnectionReleased(_ connectionID: Connection.ID) -> Action {
            self.state.modify(http1: { http1 in
                http1.http1ConnectionReleased(connectionID)
            }, http2: { http2 in
                http2.http1ConnectionReleased(connectionID)
            })
        }

        mutating func shutdown() -> Action {
            return self.state.modify(http1: { http1 in
                http1.shutdown()
            }, http2: { http2 in
                http2.shutdown()
            })
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
        case .http2(let http2):
            return ".http2(\(http2))"
        }
    }
}

extension HTTPConnectionPool.StateMachine {
    struct ConnectionMigrationAction {
        var closeConnections: [HTTPConnectionPool.Connection]
        var createConnections: [(HTTPConnectionPool.Connection.ID, EventLoop)]
    }

    struct EstablishedAction {
        static let none: Self = .init(request: .none, connection: .none)
        let request: HTTPConnectionPool.StateMachine.RequestAction
        let connection: EstablishedConnectionAction
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
                scheduleTimeout: nil
            )
        case .closeConnection(let connection, let isShutdown):
            guard isShutdown == .no else {
                precondition(
                    migrationAction.closeConnections.isEmpty &&
                        migrationAction.createConnections.isEmpty,
                    "migration actions are not supported during shutdown"
                )
                return .closeConnection(connection, isShutdown: isShutdown)
            }
            var closeConnections = migrationAction.closeConnections
            closeConnections.append(connection)
            return .migration(
                createConnections: migrationAction.createConnections,
                closeConnections: closeConnections,
                scheduleTimeout: nil
            )
        case .scheduleTimeoutTimer(let connectionID, let eventLoop):
            return .migration(
                createConnections: migrationAction.createConnections,
                closeConnections: migrationAction.closeConnections,
                scheduleTimeout: (connectionID, eventLoop)
            )
        }
    }
}
