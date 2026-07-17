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
import NIOHTTP2

extension HTTPConnectionPool {
    struct HTTP2StateMachine {
        typealias Action = HTTPConnectionPool.StateMachine.Action
        typealias RequestAction = HTTPConnectionPool.StateMachine.RequestAction
        typealias ConnectionMigrationAction = HTTPConnectionPool.StateMachine.ConnectionMigrationAction
        typealias EstablishedAction = HTTPConnectionPool.StateMachine.EstablishedAction
        typealias EstablishedConnectionAction = HTTPConnectionPool.StateMachine.EstablishedConnectionAction

        private var lastConnectFailure: Error?
        private var failedConsecutiveConnectionAttempts = 0

        private(set) var connections: HTTP2Connections
        private(set) var http1Connections: HTTP1Connections?

        private(set) var requests: RequestQueue

        private let idGenerator: Connection.ID.Generator

        private(set) var lifecycleState: StateMachine.LifecycleState
        /// The property was introduced to fail fast during testing.
        /// Otherwise this should always be true and not turned off.
        private let retryConnectionEstablishment: Bool

        init(
            idGenerator: Connection.ID.Generator,
            retryConnectionEstablishment: Bool,
            lifecycleState: StateMachine.LifecycleState,
            maximumConnectionUses: Int?
        ) {
            self.idGenerator = idGenerator
            self.requests = RequestQueue()

            self.connections = HTTP2Connections(
                generator: idGenerator,
                maximumConnectionUses: maximumConnectionUses
            )
            self.lifecycleState = lifecycleState
            self.retryConnectionEstablishment = retryConnectionEstablishment
        }

        mutating func migrateFromHTTP1(
            http1Connections: HTTP1Connections,
            http2Connections: HTTP2Connections? = nil,
            requests: RequestQueue,
            newHTTP2Connection: Connection,
            maxConcurrentStreams: Int
        ) -> Action {
            let migrationAction = self.migrateConnectionsAndRequestsFromHTTP1(
                http1Connections: http1Connections,
                http2Connections: http2Connections,
                requests: requests
            )

            let newConnectionAction = self._newHTTP2ConnectionEstablished(
                newHTTP2Connection,
                maxConcurrentStreams: maxConcurrentStreams
            )

            return .init(
                request: newConnectionAction.request,
                connection: .combined(migrationAction, newConnectionAction.connection)
            )
        }

        private mutating func migrateConnectionsAndRequestsFromHTTP1(
            http1Connections: HTTP1Connections,
            http2Connections: HTTP2Connections?,
            requests: RequestQueue
        ) -> ConnectionMigrationAction {
            precondition(self.connections.isEmpty, "expected an empty state machine but connections are not empty")
            precondition(
                self.http1Connections == nil,
                "expected an empty state machine but http1Connections are not nil"
            )
            precondition(self.requests.isEmpty, "expected an empty state machine but requests are not empty")

            self.requests = requests

            // we may have remaining open http2 connections from a pervious migration to http1
            if let http2Connections = http2Connections {
                self.connections = http2Connections
            }

            var http1Connections = http1Connections  // make http1Connections mutable
            let context = http1Connections.migrateToHTTP2()
            self.connections.migrateFromHTTP1(
                starting: context.starting,
                backingOff: context.backingOff
            )

            let createConnections = self.connections.createConnectionsAfterMigrationIfNeeded(
                requiredEventLoopsOfPendingRequests: requests.eventLoopsWithPendingRequests()
            )

            if !http1Connections.isEmpty {
                self.http1Connections = http1Connections
            }

            // TODO: Potentially cancel unneeded bootstraps (Needs cancellable ClientBootstrap)
            return .init(
                closeConnections: context.close,
                createConnections: createConnections
            )
        }

        mutating func executeRequest(_ request: Request) -> Action {
            switch self.lifecycleState {
            case .running:
                if let eventLoop = request.requiredEventLoop {
                    return self.executeRequest(request, onRequired: eventLoop)
                } else {
                    return self.executeRequest(request, onPreferred: request.preferredEventLoop)
                }
            case .shutDown, .shuttingDown:
                // it is fairly unlikely that this condition is met, since the ConnectionPoolManager
                // also fails new requests immediately, if it is shutting down. However there might
                // be race conditions in which a request passes through a running connection pool
                // manager, but hits a connection pool that is already shutting down.
                //
                // (Order in one lock does not guarantee order in the next lock!)
                return .init(
                    request: .failRequest(request, HTTPClientError.alreadyShutdown, cancelTimeout: false),
                    connection: .none
                )
            }
        }

        private mutating func executeRequest(
            _ request: Request,
            onRequired eventLoop: EventLoop
        ) -> Action {
            if let (connection, context) = self.connections.leaseStream(onRequired: eventLoop) {
                /// 1. we have a stream available and can execute the request immediately
                if context.wasIdle {
                    return .init(
                        request: .executeRequest(request, connection, cancelTimeout: false),
                        connection: .cancelTimeoutTimer(connection.id)
                    )
                } else {
                    return .init(
                        request: .executeRequest(request, connection, cancelTimeout: false),
                        connection: .none
                    )
                }
            }
            /// 2. No available stream so we definitely need to wait until we have one
            self.requests.push(request)

            if self.connections.hasConnectionThatCanOrWillBeAbleToExecuteRequests(for: eventLoop) {
                /// 3. we already have a connection, we just need to wait until until it becomes available
                return .init(
                    request: .scheduleRequestTimeout(for: request, on: eventLoop),
                    connection: .none
                )
            } else {
                /// 4. we do *not* have a connection, need to create a new one and wait until it is connected.
                let connectionId = self.connections.createNewConnection(on: eventLoop)
                return .init(
                    request: .scheduleRequestTimeout(for: request, on: eventLoop),
                    connection: .createConnection(connectionId, on: eventLoop)
                )
            }
        }

        private mutating func executeRequest(
            _ request: Request,
            onPreferred eventLoop: EventLoop
        ) -> Action {
            if let (connection, context) = self.connections.leaseStream(onPreferred: eventLoop) {
                /// 1. we have a stream available and can execute the request immediately
                if context.wasIdle {
                    return .init(
                        request: .executeRequest(request, connection, cancelTimeout: false),
                        connection: .cancelTimeoutTimer(connection.id)
                    )
                } else {
                    return .init(
                        request: .executeRequest(request, connection, cancelTimeout: false),
                        connection: .none
                    )
                }
            }
            /// 2. No available stream so we definitely need to wait until we have one
            self.requests.push(request)

            if self.connections.hasConnectionThatCanOrWillBeAbleToExecuteRequests {
                /// 3. we already have a connection, we just need to wait until until it becomes available
                return .init(
                    request: .scheduleRequestTimeout(for: request, on: eventLoop),
                    connection: .none
                )
            } else {
                /// 4. we do *not* have a connection, need to create a new one and wait until it is connected.
                let connectionId = self.connections.createNewConnection(on: eventLoop)
                return .init(
                    request: .scheduleRequestTimeout(for: request, on: eventLoop),
                    connection: .createConnection(connectionId, on: eventLoop)
                )
            }
        }

        mutating func newHTTP2ConnectionEstablished(_ connection: Connection, maxConcurrentStreams: Int) -> Action {
            .init(self._newHTTP2ConnectionEstablished(connection, maxConcurrentStreams: maxConcurrentStreams))
        }

        private mutating func _newHTTP2ConnectionEstablished(
            _ connection: Connection,
            maxConcurrentStreams: Int
        ) -> EstablishedAction {
            self.failedConsecutiveConnectionAttempts = 0
            self.lastConnectFailure = nil
            let doesConnectionExistsForEL = self.connections.hasActiveConnection(for: connection.eventLoop)
            let (index, context) = self.connections.newHTTP2ConnectionEstablished(
                connection,
                maxConcurrentStreams: maxConcurrentStreams
            )
            if doesConnectionExistsForEL {
                let connection = self.connections.closeConnection(at: index)
                return .init(
                    request: .none,
                    connection: .closeConnection(connection, isShutdown: .no)
                )
            } else {
                return self.nextActionForAvailableConnection(at: index, context: context)
            }
        }

        private mutating func nextActionForAvailableConnection(
            at index: Int,
            context: HTTP2Connections.EstablishedConnectionContext
        ) -> EstablishedAction {
            switch self.lifecycleState {
            case .running:
                // We prioritise requests with a required event loop over those without a requirement.
                // This can cause starvation for request without a required event loop.
                // We should come up with a better algorithm in the future.

                var requestsToExecute = self.requests.popFirst(max: context.availableStreams, for: context.eventLoop)
                let remainingAvailableStreams = context.availableStreams - requestsToExecute.count
                // use the remaining available streams for requests without a required event loop
                requestsToExecute += self.requests.popFirst(max: remainingAvailableStreams, for: nil)

                let requestAction = { () -> HTTPConnectionPool.StateMachine.RequestAction in
                    if requestsToExecute.isEmpty {
                        return .none
                    } else {
                        // we can only lease streams if the connection has available streams.
                        // Otherwise we might crash even if we try to lease zero streams,
                        // because the connection might already be in the draining state.
                        let (connection, _) = self.connections.leaseStreams(at: index, count: requestsToExecute.count)
                        return .executeRequestsAndCancelTimeouts(requestsToExecute, connection)
                    }
                }()

                let connectionAction = { () -> EstablishedConnectionAction in
                    if context.isIdle, requestsToExecute.isEmpty {
                        return .scheduleTimeoutTimer(context.connectionID, on: context.eventLoop)
                    } else {
                        return .none
                    }
                }()

                return .init(
                    request: requestAction,
                    connection: connectionAction
                )
            case .shuttingDown(let unclean):
                guard context.isIdle else {
                    return .none
                }

                let connection = self.connections.closeConnection(at: index)
                if self.http1Connections == nil, self.connections.isEmpty {
                    return .init(
                        request: .none,
                        connection: .closeConnection(connection, isShutdown: .yes(unclean: unclean))
                    )
                }
                return .init(
                    request: .none,
                    connection: .closeConnection(connection, isShutdown: .no)
                )
            case .shutDown:
                preconditionFailure("It the pool is already shutdown, all connections must have been torn down.")
            }
        }

        mutating func newHTTP2MaxConcurrentStreamsReceived(_ connectionID: Connection.ID, newMaxStreams: Int) -> Action
        {
            guard
                let (index, context) = self.connections.newHTTP2MaxConcurrentStreamsReceived(
                    connectionID,
                    newMaxStreams: newMaxStreams
                )
            else {
                // When a connection close is initiated by the connection pool, the connection will
                // still report further events (like newMaxConcurrentStreamsReceived) to the state
                // machine. In those cases we must ignore the event.
                return .none
            }
            return .init(self.nextActionForAvailableConnection(at: index, context: context))
        }

        mutating func http2ConnectionGoAwayReceived(_ connectionID: Connection.ID) -> Action {
            guard let context = self.connections.goAwayReceived(connectionID) else {
                // When a connection close is initiated by the connection pool, the connection will
                // still report further events (like GOAWAY received) to the state machine. In those
                // cases we must ignore the event.
                return .none
            }
            return self.nextActionForClosingConnection(on: context.eventLoop)
        }

        mutating func http2ConnectionClosed(_ connectionID: Connection.ID) -> Action {
            guard let (index, context) = self.connections.failConnection(connectionID) else {
                // When a connection close is initiated by the connection pool, the connection will
                // still report its close to the state machine. In those cases we must ignore the
                // event.
                return .none
            }
            return self.nextActionForFailedConnection(at: index, on: context.eventLoop)
        }

        private mutating func nextActionForFailedConnection(at index: Int, on eventLoop: EventLoop) -> Action {
            switch self.lifecycleState {
            case .running:
                // we do not know if we have created this connection for a request with a required
                // event loop or not. However, we do not need this information and can infer
                // if we need to create a new connection because we will only ever create one connection
                // per event loop for required event loop requests and only need one connection for
                // general purpose requests.

                // precompute if we have starting or active connections to only iterate once over `self.connections`
                let context = self.connections.backingOffTimerDone(for: eventLoop)

                // we need to start a new on connection in two cases:
                let needGeneralPurposeConnection =
                    // 1. if we have general purpose requests
                    !self.requests.isEmpty(for: nil)
                    // and no connection starting or active
                    && !context.hasGeneralPurposeConnection

                let needRequiredEventLoopConnection =
                    // 2. or if we have requests for a required event loop
                    !self.requests.isEmpty(for: eventLoop)
                    // and no connection starting or active for the given event loop
                    && !context.hasConnectionOnSpecifiedEventLoop

                guard needGeneralPurposeConnection || needRequiredEventLoopConnection else {
                    // otherwise we can remove the connection
                    self.connections.removeConnection(at: index)
                    return .none
                }

                let (newConnectionID, previousEventLoop) = self.connections
                    .createNewConnectionByReplacingClosedConnection(at: index)
                precondition(previousEventLoop === eventLoop)

                return .init(
                    request: .none,
                    connection: .createConnection(newConnectionID, on: eventLoop)
                )

            case .shuttingDown(let unclean):
                assert(self.requests.isEmpty)
                self.connections.removeConnection(at: index)
                if self.connections.isEmpty {
                    return .init(
                        request: .none,
                        connection: .cleanupConnections(.init(), isShutdown: .yes(unclean: unclean))
                    )
                }
                return .none

            case .shutDown:
                preconditionFailure("If the pool is already shutdown, all connections must have been torn down.")
            }
        }

        private mutating func nextActionForClosingConnection(on eventLoop: EventLoop) -> Action {
            switch self.lifecycleState {
            case .running:
                let hasPendingRequest = !self.requests.isEmpty(for: eventLoop) || !self.requests.isEmpty(for: nil)
                guard hasPendingRequest else {
                    return .none
                }

                let newConnectionID = self.connections.createNewConnection(on: eventLoop)

                return .init(
                    request: .none,
                    connection: .createConnection(newConnectionID, on: eventLoop)
                )
            case .shutDown, .shuttingDown:
                return .none
            }
        }

        mutating func http2ConnectionStreamClosed(_ connectionID: Connection.ID) -> Action {
            let (index, context) = self.connections.releaseStream(connectionID)
            return .init(self.nextActionForAvailableConnection(at: index, context: context))
        }

        mutating func failedToCreateNewConnection(_ error: Error, connectionID: Connection.ID) -> Action {
            self.failedConsecutiveConnectionAttempts += 1
            self.lastConnectFailure = error

            let eventLoop = self.connections.backoffNextConnectionAttempt(connectionID)

            switch self.lifecycleState {
            case .running:
                guard self.retryConnectionEstablishment else {
                    guard let (index, _) = self.connections.failConnection(connectionID) else {
                        preconditionFailure(
                            "A connection attempt failed, that the state machine knows nothing about. Somewhere state was lost."
                        )
                    }
                    self.connections.removeConnection(at: index)

                    return .init(
                        request: self.failAllRequests(reason: error),
                        connection: .none
                    )
                }

                let backoff = calculateBackoff(failedAttempt: self.failedConsecutiveConnectionAttempts)
                return .init(
                    request: .none,
                    connection: .scheduleBackoffTimer(connectionID, backoff: backoff, on: eventLoop)
                )
            case .shuttingDown:
                guard let (index, context) = self.connections.failConnection(connectionID) else {
                    preconditionFailure(
                        "A connection attempt failed, that the state machine knows nothing about. Somewhere state was lost."
                    )
                }
                return self.nextActionForFailedConnection(at: index, on: context.eventLoop)
            case .shutDown:
                preconditionFailure("If the pool is already shutdown, all connections must have been torn down.")
            }
        }

        mutating func waitingForConnectivity(_ error: Error, connectionID: Connection.ID) -> Action {
            self.lastConnectFailure = error

            return .init(request: .none, connection: .none)
        }

        mutating func connectionCreationBackoffDone(_ connectionID: Connection.ID) -> Action {
            // The naming of `failConnection` is a little confusing here. All it does is moving the
            // connection state from `.backingOff` to `.closed` here. It also returns the
            // connection's index.
            guard let (index, context) = self.connections.failConnection(connectionID) else {
                preconditionFailure("Backing off a connection that is unknown to us?")
            }
            return self.nextActionForFailedConnection(at: index, on: context.eventLoop)
        }

        private mutating func failAllRequests(reason error: Error) -> RequestAction {
            let allRequests = self.requests.removeAll()
            guard !allRequests.isEmpty else {
                return .none
            }
            return .failRequestsAndCancelTimeouts(allRequests, error)
        }

        mutating func timeoutRequest(_ requestID: Request.ID) -> Action {
            // 1. check requests in queue
            if let request = self.requests.remove(requestID) {
                var error: Error = HTTPClientError.getConnectionFromPoolTimeout
                if let lastError = self.lastConnectFailure {
                    error = lastError
                } else if !self.connections.hasActiveConnections {
                    error = HTTPClientError.connectTimeout
                }
                return .init(
                    request: .failRequest(request, error, cancelTimeout: false),
                    connection: .none
                )
            }

            // 2. This point is reached, because the request may have already been scheduled. A
            //    connection might have become available shortly before the request timeout timer
            //    fired.
            return .none
        }

        mutating func cancelRequest(_ requestID: Request.ID) -> Action {
            // 1. check requests in queue
            if let request = self.requests.remove(requestID) {
                // Use the last connection error to let the user know why the request was never scheduled
                let error = self.lastConnectFailure ?? HTTPClientError.cancelled
                return .init(
                    request: .failRequest(request, error, cancelTimeout: true),
                    connection: .none
                )
            }

            // 2. This is point is reached, because the request may already have been forwarded to
            //    an idle connection. In this case the connection will need to handle the
            //    cancellation.
            return .none
        }

        mutating func connectionIdleTimeout(_ connectionID: Connection.ID) -> Action {
            guard let connection = connections.closeConnectionIfIdle(connectionID) else {
                // because of a race this connection (connection close runs against trigger of timeout)
                // was already removed from the state machine.
                return .none
            }

            precondition(
                self.lifecycleState == .running,
                "If we are shutting down, we must not have any idle connections"
            )

            return .init(
                request: .none,
                connection: .closeConnection(connection, isShutdown: .no)
            )
        }

        mutating func http1ConnectionClosed(_ connectionID: Connection.ID) -> Action {
            guard let index = self.http1Connections?.failConnection(connectionID)?.0 else {
                return .none
            }
            self.http1Connections!.removeConnection(at: index)
            if self.http1Connections!.isEmpty {
                self.http1Connections = nil
            }
            switch self.lifecycleState {
            case .running:
                return .none
            case .shuttingDown(let unclean):
                if self.http1Connections == nil, self.connections.isEmpty {
                    return .init(
                        request: .none,
                        connection: .cleanupConnections(.init(), isShutdown: .yes(unclean: unclean))
                    )
                } else {
                    return .none
                }
            case .shutDown:
                preconditionFailure("If the pool is already shutdown, all connections must have been torn down.")
            }
        }

        mutating func http1ConnectionReleased(_ connectionID: Connection.ID) -> Action {
            // It is save to bang the http1Connections here. If we get this callback but we don't have
            // http1 connections something has gone terribly wrong.
            let (index, _) = self.http1Connections!.releaseConnection(connectionID)
            // Any http1 connection that becomes idle should be closed right away after the transition
            // to http2.
            let connection = self.http1Connections!.closeConnection(at: index)
            guard self.http1Connections!.isEmpty else {
                return .init(request: .none, connection: .closeConnection(connection, isShutdown: .no))
            }
            // if there are no more http1Connections, we can remove the struct.
            self.http1Connections = nil

            // we must also check, if we are shutting down. Was this maybe out last connection?
            switch self.lifecycleState {
            case .running:
                return .init(request: .none, connection: .closeConnection(connection, isShutdown: .no))
            case .shuttingDown(let unclean):
                if self.connections.isEmpty {
                    // if the http2connections are empty as well, there are no more connections. Shutdown completed.
                    return .init(
                        request: .none,
                        connection: .closeConnection(connection, isShutdown: .yes(unclean: unclean))
                    )
                } else {
                    return .init(request: .none, connection: .closeConnection(connection, isShutdown: .no))
                }
            case .shutDown:
                preconditionFailure("If the pool is already shutdown, all connections must have been torn down.")
            }
        }

        mutating func shutdown() -> Action {
            // If we have remaining request queued, we should fail all of them with a cancelled
            // error.
            let waitingRequests = self.requests.removeAll()

            var requestAction: StateMachine.RequestAction = .none
            if !waitingRequests.isEmpty {
                requestAction = .failRequestsAndCancelTimeouts(waitingRequests, HTTPClientError.cancelled)
            }

            // clean up the connections, we can cleanup now!
            let cleanupContext = self.connections.shutdown()

            // If there aren't any more connections, everything is shutdown
            let isShutdown: StateMachine.ConnectionAction.IsShutdown
            let unclean = !(cleanupContext.cancel.isEmpty && waitingRequests.isEmpty && self.http1Connections == nil)
            if self.connections.isEmpty && self.http1Connections == nil {
                isShutdown = .yes(unclean: unclean)
                self.lifecycleState = .shutDown
            } else {
                isShutdown = .no
                self.lifecycleState = .shuttingDown(unclean: unclean)
            }
            return .init(
                request: requestAction,
                connection: .cleanupConnections(cleanupContext, isShutdown: isShutdown)
            )
        }
    }
}
