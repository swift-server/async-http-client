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
    struct HTTP2StateMaschine {
        typealias Action = HTTPConnectionPool.StateMachine.Action
        typealias RequestAction = HTTPConnectionPool.StateMachine.RequestAction
        typealias ConnectionAction = HTTPConnectionPool.StateMachine.ConnectionAction

        private var lastConnectFailure: Error?
        private var failedConsecutiveConnectionAttempts = 0

        private var connections: HTTP2Connections
        private var http1Connections: HTTP1Connections?

        private var requests: RequestQueue

        private let idGenerator: Connection.ID.Generator

        init(
            idGenerator: Connection.ID.Generator
        ) {
            self.idGenerator = idGenerator
            self.requests = RequestQueue()

            self.connections = HTTP2Connections(generator: idGenerator)
        }

        mutating func migrateConnectionsFromHTTP1(
            connections http1Connections: HTTP1Connections,
            requests: RequestQueue
        ) -> Action {
            precondition(self.http1Connections == nil)
            precondition(self.connections.isEmpty)
            precondition(self.requests.isEmpty)

            var http1Connections = http1Connections // make http1Connections mutable
            let context = http1Connections.migrateToHTTP2()
            self.connections.migrateConnections(
                starting: context.starting,
                backingOff: context.backingOff
            )

            if !http1Connections.isEmpty {
                self.http1Connections = http1Connections
            }

            self.requests = requests

            // TODO: Close all idle connections from context.close
            // TODO: Potentially cancel unneeded bootstraps (Needs cancellable ClientBootstrap)

            return .none
        }

        mutating func executeRequest(_ request: Request) -> Action {
            if let eventLoop = request.requiredEventLoop {
                return self.executeRequest(request, onRequired: eventLoop)
            } else {
                return self.executeRequest(request, onPreferred: request.preferredEventLoop)
            }
        }

        private mutating func executeRequest(
            _ request: Request,
            onRequired eventLoop: EventLoop
        ) -> Action {
            if let connection = self.connections.leaseStream(onRequired: eventLoop) {
                /// 1. we have a stream available and can execute the request immediately
                return .init(
                    request: .executeRequest(request, connection, cancelTimeout: false),
                    connection: .cancelTimeoutTimer(connection.id)
                )
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
            if let connection = self.connections.leaseStream(onPreferred: eventLoop) {
                /// 1. we have a stream available and can execute the request immediately
                return .init(
                    request: .executeRequest(request, connection, cancelTimeout: false),
                    connection: .cancelTimeoutTimer(connection.id)
                )
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
            self.failedConsecutiveConnectionAttempts = 0
            self.lastConnectFailure = nil
            let (index, context) = self.connections.newHTTP2ConnectionEstablished(
                connection,
                maxConcurrentStreams: maxConcurrentStreams
            )
            return self.nextActionForAvailableConnection(at: index, context: context)
        }

        private mutating func nextActionForAvailableConnection(
            at index: Int,
            context: HTTP2Connections.AvailableConnectionContext
        ) -> Action {
            // We prioritise requests with a required event loop over those without a requirement.
            // This can cause starvation for request without a required event loop.
            // We should come up with a better algorithm in the future.

            var requestsToExecute = self.requests.popFirst(max: context.availableStreams, for: context.eventLoop)
            let remainingAvailableStreams = context.availableStreams - requestsToExecute.count
            // use the remaining available streams for requests without a required event loop
            requestsToExecute += self.requests.popFirst(max: remainingAvailableStreams, for: nil)
            let connection = self.connections.leaseStreams(at: index, count: requestsToExecute.count)

            let requestAction = { () -> RequestAction in
                if requestsToExecute.isEmpty {
                    return .none
                } else {
                    return .executeRequestsAndCancelTimeouts(requestsToExecute, connection)
                }
            }()

            let connectionAction = { () -> ConnectionAction in
                if context.isIdle, requestsToExecute.isEmpty {
                    return .scheduleTimeoutTimer(connection.id, on: context.eventLoop)
                } else {
                    return .none
                }
            }()

            return .init(
                request: requestAction,
                connection: connectionAction
            )
        }

        mutating func newHTTP2MaxConcurrentStreamsReceived(_ connectionID: Connection.ID, newMaxStreams: Int) -> Action {
            let (index, context) = self.connections.newHTTP2MaxConcurrentStreamsReceived(connectionID, newMaxStreams: newMaxStreams)
            return self.nextActionForAvailableConnection(at: index, context: context)
        }

        mutating func http2ConnectionGoAwayReceived(_ connectionID: Connection.ID) -> Action {
            let context = self.connections.goAwayReceived(connectionID)
            return self.nextActionForClosingConnection(on: context.eventLoop)
        }

        mutating func http2ConnectionClosed(_ connectionID: Connection.ID) -> Action {
            guard let (index, context) = self.connections.failConnection(connectionID) else {
                return .none
            }
            return self.nextActionForFailedConnection(at: index, on: context.eventLoop)
        }

        private mutating func nextActionForFailedConnection(at index: Int, on eventLoop: EventLoop) -> Action {
            let hasPendingRequest = !self.requests.isEmpty(for: eventLoop) || !self.requests.isEmpty(for: nil)
            guard hasPendingRequest else {
                return .none
            }

            let (newConnectionID, previousEventLoop) = self.connections.createNewConnectionByReplacingClosedConnection(at: index)
            precondition(previousEventLoop === eventLoop)

            return .init(
                request: .none,
                connection: .createConnection(newConnectionID, on: eventLoop)
            )
        }

        private mutating func nextActionForClosingConnection(on eventLoop: EventLoop) -> Action {
            let hasPendingRequest = !self.requests.isEmpty(for: eventLoop) || !self.requests.isEmpty(for: nil)
            guard hasPendingRequest else {
                return .none
            }

            let newConnectionID = self.connections.createNewConnection(on: eventLoop)

            return .init(
                request: .none,
                connection: .createConnection(newConnectionID, on: eventLoop)
            )
        }

        mutating func http2ConnectionStreamClosed(_ connectionID: Connection.ID) -> Action {
            let (index, context) = self.connections.releaseStream(connectionID)
            return self.nextActionForAvailableConnection(at: index, context: context)
        }

        mutating func failedToCreateNewConnection(_ error: Error, connectionID: Connection.ID) -> Action {
            self.failedConsecutiveConnectionAttempts += 1
            self.lastConnectFailure = error

            let eventLoop = self.connections.backoffNextConnectionAttempt(connectionID)
            let backoff = calculateBackoff(failedAttempt: self.failedConsecutiveConnectionAttempts)
            return .init(request: .none, connection: .scheduleBackoffTimer(connectionID, backoff: backoff, on: eventLoop))
        }

        mutating func connectionCreationBackoffDone(_ connectionID: Connection.ID) -> Action {
            // The naming of `failConnection` is a little confusing here. All it does is moving the
            // connection state from `.backingOff` to `.closed` here. It also returns the
            // connection's index.
            guard let (index, context) = self.connections.failConnection(connectionID) else {
                preconditionFailure("Backing off a connection that is unknown to us?")
            }
            return nextActionForFailedConnection(at: index, on: context.eventLoop)
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
            if self.requests.remove(requestID) != nil {
                return .init(
                    request: .cancelRequestTimeout(requestID),
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
                return .none
            }
            return .init(
                request: .none,
                connection: .closeConnection(connection, isShutdown: .no)
            )
        }

        mutating func connectionClosed(_ connectionID: Connection.ID) -> Action {
            guard let (index, context) = self.connections.failConnection(connectionID) else {
                // When a connection close is initiated by the connection pool, the connection will
                // still report its close to the state machine. In those cases we must ignore the
                // event.
                return .none
            }
            return self.nextActionForFailedConnection(at: index, on: context.eventLoop)
        }

        mutating func http1ConnectionReleased(_: Connection.ID) -> Action {
            fatalError("TODO: implement \(#function)")
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
            let unclean = !(cleanupContext.cancel.isEmpty && waitingRequests.isEmpty)
            if self.connections.isEmpty {
                isShutdown = .yes(unclean: unclean)
            } else {
                isShutdown = .no
            }
            return .init(
                request: requestAction,
                connection: .cleanupConnections(cleanupContext, isShutdown: isShutdown)
            )
        }
    }
}
