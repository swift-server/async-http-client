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

extension HTTPConnectionPool {
    struct HTTP1StateMachine {
        enum State: Equatable {
            case running
            case shuttingDown(unclean: Bool)
            case shutDown
        }

        typealias Action = HTTPConnectionPool.StateMachine.Action

        private var connections: HTTP1Connections
        private var failedConsecutiveConnectionAttempts: Int = 0

        private var queue: RequestQueue
        private var state: State = .running

        init(idGenerator: Connection.ID.Generator, maximumConcurrentConnections: Int) {
            self.connections = HTTP1Connections(
                maximumConcurrentConnections: maximumConcurrentConnections,
                generator: idGenerator
            )

            self.queue = RequestQueue()
        }

        // MARK: - Events -

        mutating func executeRequest(_ request: Request) -> Action {
            switch self.state {
            case .running:
                if let eventLoop = request.requiredEventLoop {
                    return self.executeRequestOnRequiredEventLoop(request, eventLoop: eventLoop)
                } else {
                    return self.executeRequestOnPreferredEventLoop(request, eventLoop: request.preferredEventLoop)
                }
            case .shuttingDown, .shutDown:
                // it is fairly unlikely that this condition is met, since the ConnectionPoolManager
                // also fails new requests immediately, if it is shutting down. However there might
                // be race conditions in which a request passes through a running connection pool
                // manager, but hits a connection pool that is already shutting down.
                //
                // (Order in one lock does not guarantee order in the next lock!)
                return .init(
                    request: .failRequest(request, HTTPClientError.alreadyShutdown, cancelTimeout: nil),
                    connection: .none
                )
            }
        }

        mutating func executeRequestOnPreferredEventLoop(_ request: Request, eventLoop: EventLoop) -> Action {
            if let connection = self.connections.leaseConnection(onPreferred: eventLoop) {
                return .init(
                    request: .executeRequest(request, connection, cancelTimeout: nil),
                    connection: .cancelTimeoutTimer(connection.id)
                )
            }

            // No matter what we do now, the request will need to wait!
            let requestID = self.queue.push(request)
            let requestAction: StateMachine.RequestAction = .scheduleRequestTimeout(
                request.connectionDeadline,
                for: requestID,
                on: request.preferredEventLoop
            )

            if !self.connections.canGrow {
                // all connections are busy and there is no room for more connections, we need to wait!
                return .init(request: requestAction, connection: .none)
            }

            // if we are not at max connections, we may want to create a new connection
            if self.connections.startingGeneralPurposeConnections >= self.queue.count {
                // If there are at least as many connections starting as we have request queued, we
                // don't need to create a new connection. we just need to wait.
                return .init(request: requestAction, connection: .none)
            }

            // There are not enough connections starting for the current waiting request count. We
            // should create a new one.
            let newConnectionID = self.connections.createNewConnection(on: eventLoop)

            return .init(
                request: requestAction,
                connection: .createConnection(newConnectionID, on: eventLoop)
            )
        }

        mutating func executeRequestOnRequiredEventLoop(_ request: Request, eventLoop: EventLoop) -> Action {
            if let connection = self.connections.leaseConnection(onRequired: eventLoop) {
                return .init(
                    request: .executeRequest(request, connection, cancelTimeout: nil),
                    connection: .cancelTimeoutTimer(connection.id)
                )
            }

            // No matter what we do now, the request will need to wait!
            let requestID = self.queue.push(request)
            let requestAction: StateMachine.RequestAction = .scheduleRequestTimeout(
                request.connectionDeadline,
                for: requestID,
                on: request.preferredEventLoop
            )

            let starting = self.connections.startingEventLoopConnections(on: eventLoop)
            let waiting = self.queue.count(for: eventLoop)

            if starting >= waiting {
                // There are already as many connections starting as we need for the waiting
                // requests. A new connection doesn't need to be created.
                return .init(request: requestAction, connection: .none)
            }

            // There are not enough connections starting for the number of requests in the queue.
            // We should create a new connection.
            let newConnectionID = self.connections.createNewOverflowConnection(on: eventLoop)

            return .init(
                request: requestAction,
                connection: .createConnection(newConnectionID, on: eventLoop)
            )
        }

        mutating func newHTTP1ConnectionEstablished(_ connection: Connection) -> Action {
            self.failedConsecutiveConnectionAttempts = 0
            let (index, context) = self.connections.newHTTP1ConnectionEstablished(connection)
            return self.nextActionForIdleConnection(at: index, context: context)
        }

        mutating func failedToCreateNewConnection(_ error: Error, connectionID: Connection.ID) -> Action {
            defer {
                // After we have processed this call, we have one more failed connection attempt,
                // that we need to consider when computing the jitter.
                self.failedConsecutiveConnectionAttempts += 1
            }

            switch self.state {
            case .running:
                // We don't care how many waiting requests we have at this point, we will schedule a
                // retry. More tasks, may appear until the backoff has completed. The final
                // decision about the retry will be made in `connectionCreationBackoffDone(_:)`
                let eventLoop = self.connections.backoffNextConnectionAttempt(connectionID)

                let backoff = TimeAmount.milliseconds(100) * Int(pow(1.25, Double(self.failedConsecutiveConnectionAttempts)))
                let jitterRange = backoff.nanoseconds / 100 * 5
                let jitteredBackoff = backoff + .nanoseconds((-jitterRange...jitterRange).randomElement()!)
                return .init(
                    request: .none,
                    connection: .scheduleBackoffTimer(connectionID, backoff: jitteredBackoff, on: eventLoop)
                )

            case .shuttingDown:
                let (index, context) = self.connections.failConnection(connectionID)
                return self.nextActionForFailedConnection(at: index, context: context)

            case .shutDown:
                preconditionFailure("The pool is already shutdown all connections must already been torn down")
            }
        }

        mutating func connectionCreationBackoffDone(_ connectionID: Connection.ID) -> Action {
            assert(self.connections.stats.backingOff >= 1, "At least this connection is currently in backoff")
            let (index, context) = self.connections.failConnection(connectionID)
            return self.nextActionForFailedConnection(at: index, context: context)
        }

        mutating func connectionIdleTimeout(_ connectionID: Connection.ID) -> Action {
            guard let connection = self.connections.closeConnectionIfIdle(connectionID) else {
                // because of a race this connection (connection close runs against trigger of timeout)
                // was already removed from the state machine.
                return .none
            }

            assert(self.state == .running, "If we are shutting down, we must not have any idle connections")

            return .init(
                request: .none,
                connection: .closeConnection(connection, isShutdown: .no)
            )
        }

        mutating func http1ConnectionReleased(_ connectionID: Connection.ID) -> Action {
            let (index, context) = self.connections.releaseConnection(connectionID)
            return self.nextActionForIdleConnection(at: index, context: context)
        }

        /// A connection has been unexpectedly closed
        mutating func connectionClosed(_ connectionID: Connection.ID) -> Action {
            let (index, context) = self.connections.failConnection(connectionID)
            return self.nextActionForFailedConnection(at: index, context: context)
        }

        mutating func timeoutRequest(_ requestID: Request.ID) -> Action {
            // 1. check requests in queue
            if let request = self.queue.remove(requestID) {
                return .init(
                    request: .failRequest(request, HTTPClientError.getConnectionFromPoolTimeout, cancelTimeout: nil),
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
            if self.queue.remove(requestID) != nil {
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

        mutating func shutdown() -> Action {
            precondition(self.state == .running, "Shutdown must only be called once")

            // If we have remaining request queued, we should fail all of them with a cancelled
            // error.
            let waitingRequests = self.queue.removeAll().map { ($0, $0.id) }

            var requestAction: StateMachine.RequestAction = .none
            if !waitingRequests.isEmpty {
                requestAction = .failRequests(waitingRequests, HTTPClientError.cancelled)
            }

            // clean up the connections, we can cleanup now!
            let cleanupContext = self.connections.shutdown()

            // If there aren't any more connections, everything is shutdown
            let isShutdown: StateMachine.ConnectionAction.IsShutdown
            let unclean = !(cleanupContext.cancel.isEmpty && waitingRequests.isEmpty)
            if self.connections.isEmpty {
                self.state = .shutDown
                isShutdown = .yes(unclean: unclean)
            } else {
                self.state = .shuttingDown(unclean: unclean)
                isShutdown = .no
            }

            return .init(
                request: requestAction,
                connection: .cleanupConnections(cleanupContext, isShutdown: isShutdown)
            )
        }

        // MARK: - Private Methods -

        // MARK: Idle connection management

        private mutating func nextActionForIdleConnection(
            at index: Int,
            context: HTTP1Connections.IdleConnectionContext
        ) -> Action {
            switch self.state {
            case .running:
                switch context.use {
                case .generalPurpose:
                    return self.nextActionForIdleGeneralPurposeConnection(at: index, context: context)
                case .eventLoop:
                    return self.nextActionForIdleEventLoopConnection(at: index, context: context)
                }
            case .shuttingDown(let unclean):
                assert(self.queue.isEmpty)
                let connection = self.connections.closeConnection(at: index)
                if self.connections.isEmpty {
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

        private mutating func nextActionForIdleGeneralPurposeConnection(
            at index: Int,
            context: HTTP1Connections.IdleConnectionContext
        ) -> Action {
            // 1. Check if there are waiting requests in the general purpose queue
            if let request = self.queue.popFirst(for: nil) {
                return .init(
                    request: .executeRequest(request, self.connections.leaseConnection(at: index), cancelTimeout: request.id),
                    connection: .none
                )
            }

            // 2. Check if there are waiting requests in the matching eventLoop queue
            if let request = self.queue.popFirst(for: context.eventLoop) {
                return .init(
                    request: .executeRequest(request, self.connections.leaseConnection(at: index), cancelTimeout: request.id),
                    connection: .none
                )
            }

            // 3. Create a timeout timer to ensure the connection is closed if it is idle for too
            //    long.
            let (connectionID, eventLoop) = self.connections.parkConnection(at: index)
            return .init(
                request: .none,
                connection: .scheduleTimeoutTimer(connectionID, on: eventLoop)
            )
        }

        private mutating func nextActionForIdleEventLoopConnection(
            at index: Int,
            context: HTTP1Connections.IdleConnectionContext
        ) -> Action {
            // Check if there are waiting requests in the matching eventLoop queue
            if let request = self.queue.popFirst(for: context.eventLoop) {
                return .init(
                    request: .executeRequest(request, self.connections.leaseConnection(at: index), cancelTimeout: request.id),
                    connection: .none
                )
            }

            // TBD: What do we want to do, if there are more requests in the general purpose queue?
            //      For now, we don't care. The general purpose connections will pick those up
            //      eventually.
            //
            // If there is no more eventLoop bound work, we close the eventLoop bound connections.
            // We don't park them.
            return .init(
                request: .none,
                connection: .closeConnection(self.connections.closeConnection(at: index), isShutdown: .no)
            )
        }

        // MARK: Failed/Closed connection management

        private mutating func nextActionForFailedConnection(
            at index: Int,
            context: HTTP1Connections.FailedConnectionContext
        ) -> Action {
            switch self.state {
            case .running:
                switch context.use {
                case .generalPurpose:
                    return self.nextActionForFailedGeneralPurposeConnection(at: index, context: context)
                case .eventLoop:
                    return self.nextActionForFailedEventLoopConnection(at: index, context: context)
                }

            case .shuttingDown(let unclean):
                assert(self.queue.isEmpty)
                self.connections.removeConnection(at: index)
                if self.connections.isEmpty {
                    return .init(
                        request: .none,
                        connection: .cleanupConnections(.init(), isShutdown: .yes(unclean: unclean))
                    )
                }
                return .none

            case .shutDown:
                preconditionFailure("It the pool is already shutdown, all connections must have been torn down.")
            }
        }

        private mutating func nextActionForFailedGeneralPurposeConnection(
            at index: Int,
            context: HTTP1Connections.FailedConnectionContext
        ) -> Action {
            if context.connectionsStartingForUseCase < self.queue.count(for: nil) {
                // if we have more requests queued up, than we have starting connections, we should
                // create a new connection
                let (newConnectionID, newEventLoop) = self.connections.replaceConnection(at: index)
                return .init(
                    request: .none,
                    connection: .createConnection(newConnectionID, on: newEventLoop)
                )
            }
            self.connections.removeConnection(at: index)
            return .none
        }

        private mutating func nextActionForFailedEventLoopConnection(
            at index: Int,
            context: HTTP1Connections.FailedConnectionContext
        ) -> Action {
            if context.connectionsStartingForUseCase < self.queue.count(for: context.eventLoop) {
                // if we have more requests queued up, than we have starting connections, we should
                // create a new connection
                let (newConnectionID, newEventLoop) = self.connections.replaceConnection(at: index)
                return .init(
                    request: .none,
                    connection: .createConnection(newConnectionID, on: newEventLoop)
                )
            }
            self.connections.removeConnection(at: index)
            return .none
        }
    }
}

extension HTTPConnectionPool.HTTP1StateMachine: CustomStringConvertible {
    var description: String {
        let stats = self.connections.stats
        let queued = self.queue.count

        return "connections: [connecting: \(stats.connecting) | backoff: \(stats.backingOff) | leased: \(stats.leased) | idle: \(stats.idle)], queued: \(queued)"
    }
}
