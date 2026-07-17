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

extension HTTPConnectionPool {
    struct HTTP1StateMachine {
        typealias Action = HTTPConnectionPool.StateMachine.Action
        typealias RequestAction = HTTPConnectionPool.StateMachine.RequestAction
        typealias ConnectionMigrationAction = HTTPConnectionPool.StateMachine.ConnectionMigrationAction
        typealias EstablishedAction = HTTPConnectionPool.StateMachine.EstablishedAction
        typealias EstablishedConnectionAction = HTTPConnectionPool.StateMachine.EstablishedConnectionAction

        private(set) var connections: HTTP1Connections
        private(set) var http2Connections: HTTP2Connections?
        private var failedConsecutiveConnectionAttempts: Int = 0
        /// the error from the last connection creation
        private var lastConnectFailure: Error?

        private(set) var requests: RequestQueue
        private(set) var lifecycleState: StateMachine.LifecycleState
        /// The property was introduced to fail fast during testing.
        /// Otherwise this should always be true and not turned off.
        private let retryConnectionEstablishment: Bool
        private let preWarmedConnectionCount: Int

        init(
            idGenerator: Connection.ID.Generator,
            maximumConcurrentConnections: Int,
            retryConnectionEstablishment: Bool,
            maximumConnectionUses: Int?,
            preWarmedHTTP1ConnectionCount: Int,
            lifecycleState: StateMachine.LifecycleState
        ) {
            self.connections = HTTP1Connections(
                maximumConcurrentConnections: maximumConcurrentConnections,
                generator: idGenerator,
                maximumConnectionUses: maximumConnectionUses,
                preWarmedHTTP1ConnectionCount: preWarmedHTTP1ConnectionCount
            )
            self.preWarmedConnectionCount = preWarmedHTTP1ConnectionCount
            self.retryConnectionEstablishment = retryConnectionEstablishment

            self.requests = RequestQueue()
            self.lifecycleState = lifecycleState
        }

        mutating func migrateFromHTTP2(
            http1Connections: HTTP1Connections? = nil,
            http2Connections: HTTP2Connections,
            requests: RequestQueue,
            newHTTP1Connection: Connection
        ) -> Action {
            let migrationAction = self.migrateConnectionsAndRequestsFromHTTP2(
                http1Connections: http1Connections,
                http2Connections: http2Connections,
                requests: requests
            )

            let newConnectionAction = self._newHTTP1ConnectionEstablished(
                newHTTP1Connection
            )

            return .init(
                request: newConnectionAction.request,
                connection: .combined(migrationAction, newConnectionAction.connection)
            )
        }

        private mutating func migrateConnectionsAndRequestsFromHTTP2(
            http1Connections: HTTP1Connections?,
            http2Connections: HTTP2Connections,
            requests: RequestQueue
        ) -> ConnectionMigrationAction {
            precondition(self.connections.isEmpty, "expected an empty state machine but connections are not empty")
            precondition(
                self.http2Connections == nil,
                "expected an empty state machine but http2Connections are not nil"
            )
            precondition(self.requests.isEmpty, "expected an empty state machine but requests are not empty")

            self.requests = requests

            // we may have remaining open http1 connections from a pervious migration to http2
            if let http1Connections = http1Connections {
                self.connections = http1Connections
            }

            var http2Connections = http2Connections
            let migration = http2Connections.migrateToHTTP1()

            self.connections.migrateFromHTTP2(
                starting: migration.starting,
                backingOff: migration.backingOff
            )

            let createConnections = self.connections.createConnectionsAfterMigrationIfNeeded(
                requiredEventLoopOfPendingRequests: requests.requestCountGroupedByRequiredEventLoop(),
                generalPurposeRequestCountGroupedByPreferredEventLoop:
                    requests.generalPurposeRequestCountGroupedByPreferredEventLoop()
            )

            if !http2Connections.isEmpty {
                self.http2Connections = http2Connections
            }

            // TODO: Potentially cancel unneeded bootstraps (Needs cancellable ClientBootstrap)

            return .init(
                closeConnections: migration.close,
                createConnections: createConnections
            )
        }

        // MARK: - Events -

        mutating func executeRequest(_ request: Request) -> Action {
            switch self.lifecycleState {
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
                    request: .failRequest(request, HTTPClientError.alreadyShutdown, cancelTimeout: false),
                    connection: .none
                )
            }
        }

        private mutating func executeRequestOnPreferredEventLoop(_ request: Request, eventLoop: EventLoop) -> Action {
            if let connection = self.connections.leaseConnection(onPreferred: eventLoop) {
                // Cool, a connection is available. If using this would put us below our needed extra set, we
                // should create another.
                let stats = self.connections.generalPurposeStats
                let needExtraConnection =
                    stats.nonLeased < (self.requests.count + self.preWarmedConnectionCount) && self.connections.canGrow
                let action: StateMachine.ConnectionAction

                if needExtraConnection {
                    action = .createConnectionAndCancelTimeoutTimer(
                        createdID: self.connections.createNewConnection(on: eventLoop),
                        on: eventLoop,
                        cancelTimerID: connection.id
                    )
                } else {
                    action = .cancelTimeoutTimer(connection.id)
                }

                return .init(
                    request: .executeRequest(request, connection, cancelTimeout: false),
                    connection: action
                )
            }

            // No matter what we do now, the request will need to wait!
            self.requests.push(request)
            let requestAction: StateMachine.RequestAction = .scheduleRequestTimeout(
                for: request,
                on: eventLoop
            )

            if !self.connections.canGrow {
                // all connections are busy and there is no room for more connections, we need to wait!
                return .init(request: requestAction, connection: .none)
            }

            // if we are not at max connections, we may want to create a new connection
            if self.connections.startingGeneralPurposeConnections >= self.requests.generalPurposeCount {
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

        private mutating func executeRequestOnRequiredEventLoop(_ request: Request, eventLoop: EventLoop) -> Action {
            if let connection = self.connections.leaseConnection(onRequired: eventLoop) {
                return .init(
                    request: .executeRequest(request, connection, cancelTimeout: false),
                    connection: .cancelTimeoutTimer(connection.id)
                )
            }

            // No matter what we do now, the request will need to wait!
            self.requests.push(request)
            let requestAction: StateMachine.RequestAction = .scheduleRequestTimeout(
                for: request,
                on: eventLoop
            )

            let starting = self.connections.startingEventLoopConnections(on: eventLoop)
            let waiting = self.requests.count(for: eventLoop)

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
            .init(self._newHTTP1ConnectionEstablished(connection))
        }

        private mutating func _newHTTP1ConnectionEstablished(_ connection: Connection) -> EstablishedAction {
            self.failedConsecutiveConnectionAttempts = 0
            self.lastConnectFailure = nil
            let (index, context) = self.connections.newHTTP1ConnectionEstablished(connection)
            return self.nextActionForIdleConnection(at: index, context: context)
        }

        mutating func failedToCreateNewConnection(_ error: Error, connectionID: Connection.ID) -> Action {
            self.failedConsecutiveConnectionAttempts += 1
            self.lastConnectFailure = error

            // We don't care how many waiting requests we have at this point, we will schedule a
            // retry. More tasks, may appear until the backoff has completed. The final
            // decision about the retry will be made in `connectionCreationBackoffDone(_:)`
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
                    preconditionFailure("Failed to create a connection that is unknown to us?")
                }
                return self.nextActionForFailedConnection(at: index, context: context)

            case .shutDown:
                preconditionFailure("The pool is already shutdown all connections must already been torn down")
            }
        }

        mutating func waitingForConnectivity(_ error: Error, connectionID: Connection.ID) -> Action {
            self.lastConnectFailure = error

            return .init(request: .none, connection: .none)
        }

        mutating func connectionCreationBackoffDone(_ connectionID: Connection.ID) -> Action {
            switch self.lifecycleState {
            case .running:
                // The naming of `failConnection` is a little confusing here. All it does is moving the
                // connection state from `.backingOff` to `.closed` here. It also returns the
                // connection's index.
                guard let (index, context) = self.connections.failConnection(connectionID) else {
                    preconditionFailure("Backing off a connection that is unknown to us?")
                }
                // In `nextActionForFailedConnection` a decision will be made whether the failed
                // connection should be replaced or removed.
                return self.nextActionForFailedConnection(at: index, context: context)

            case .shuttingDown, .shutDown:
                // There might be a race between shutdown and a backoff timer firing. On thread A
                // we might call shutdown which removes the backoff timer. On thread B the backoff
                // timer might fire at the same time and be blocked by the state lock. In this case
                // we would look for the backoff timer that was removed just before by the shutdown.
                return .none
            }
        }

        mutating func connectionIdleTimeout(_ connectionID: Connection.ID, on eventLoop: any EventLoop) -> Action {
            // Don't close idle connections if we need pre-warmed connections. Instead, re-arm the idle timer.
            // We still want the idle timers to make sure we eventually fall below the pre-warmed limit.
            if self.preWarmedConnectionCount > 0 {
                let stats = self.connections.generalPurposeStats
                if stats.idle <= self.preWarmedConnectionCount {
                    return .init(
                        request: .none,
                        connection: .scheduleTimeoutTimer(connectionID, on: eventLoop)
                    )
                }
            }

            // Ok, we do actually want the connection count to go down.
            guard let connection = self.connections.closeConnectionIfIdle(connectionID) else {
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

        mutating func http1ConnectionReleased(_ connectionID: Connection.ID) -> Action {
            let (index, context) = self.connections.releaseConnection(connectionID)
            return .init(self.nextActionForIdleConnection(at: index, context: context))
        }

        /// A connection has been unexpectedly closed
        mutating func http1ConnectionClosed(_ connectionID: Connection.ID) -> Action {
            guard let (index, context) = self.connections.failConnection(connectionID) else {
                // When a connection close is initiated by the connection pool, the connection will
                // still report its close to the state machine. In those cases we must ignore the
                // event.
                return .none
            }
            return self.nextActionForFailedConnection(at: index, context: context)
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

        mutating func shutdown() -> Action {
            precondition(self.lifecycleState == .running, "Shutdown must only be called once")

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
            if self.connections.isEmpty && self.http2Connections == nil {
                self.lifecycleState = .shutDown
                isShutdown = .yes(unclean: unclean)
            } else {
                self.lifecycleState = .shuttingDown(unclean: unclean)
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
        ) -> EstablishedAction {
            switch self.lifecycleState {
            case .running:
                // Close the connection if it's expired.
                if context.shouldBeClosed {
                    return self.nextActionForToBeClosedIdleConnection(at: index, context: context)
                } else {
                    switch context.use {
                    case .generalPurpose:
                        return self.nextActionForIdleGeneralPurposeConnection(at: index, context: context)
                    case .eventLoop:
                        return self.nextActionForIdleEventLoopConnection(at: index, context: context)
                    }
                }
            case .shuttingDown(let unclean):
                assert(self.requests.isEmpty)
                let connection = self.connections.closeConnection(at: index)
                if self.connections.isEmpty && self.http2Connections == nil {
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
        ) -> EstablishedAction {
            var requestAction = HTTPConnectionPool.StateMachine.RequestAction.none
            var parkedConnectionDetails: (HTTPConnectionPool.Connection.ID, any EventLoop)? = nil

            // 1. Check if there are waiting requests in the general purpose queue
            if let request = self.requests.popFirst(for: nil) {
                requestAction = .executeRequest(
                    request,
                    self.connections.leaseConnection(at: index),
                    cancelTimeout: true
                )
            }

            // 2. Check if there are waiting requests in the matching eventLoop queue
            if case .none = requestAction, let request = self.requests.popFirst(for: context.eventLoop) {
                requestAction = .executeRequest(
                    request,
                    self.connections.leaseConnection(at: index),
                    cancelTimeout: true
                )
            }

            // 3. Create a timeout timer to ensure the connection is closed if it is idle for too
            //    long, assuming we don't already have a use for it.
            if case .none = requestAction {
                parkedConnectionDetails = self.connections.parkConnection(at: index)
            }

            // 4. We may need to create another connection to make sure we have enough pre-warmed ones.
            //    We need to do that if we have fewer non-leased connections than we need pre-warmed ones _and_ the pool can grow.
            //    Note that in this case we don't need to account for the number of pending requests, as that is 0: step 1
            //    confirmed that.
            let connectionAction: EstablishedConnectionAction

            if self.connections.generalPurposeStats.nonLeased < self.preWarmedConnectionCount
                && self.connections.canGrow
            {
                // Re-use the event loop of the connection that just got created.
                if let parkedConnectionDetails {
                    let newConnectionID = self.connections.createNewConnection(on: parkedConnectionDetails.1)
                    connectionAction = .scheduleTimeoutTimerAndCreateConnection(
                        timeoutID: parkedConnectionDetails.0,
                        newConnectionID: newConnectionID,
                        on: parkedConnectionDetails.1
                    )
                } else {
                    let newConnectionID = self.connections.createNewConnection(on: context.eventLoop)
                    connectionAction = .createConnection(connectionID: newConnectionID, on: context.eventLoop)
                }
            } else if let parkedConnectionDetails {
                connectionAction = .scheduleTimeoutTimer(parkedConnectionDetails.0, on: parkedConnectionDetails.1)
            } else {
                connectionAction = .none
            }

            return .init(
                request: requestAction,
                connection: connectionAction
            )
        }

        private mutating func nextActionForIdleEventLoopConnection(
            at index: Int,
            context: HTTP1Connections.IdleConnectionContext
        ) -> EstablishedAction {
            // Check if there are waiting requests in the matching eventLoop queue
            if let request = self.requests.popFirst(for: context.eventLoop) {
                return .init(
                    request: .executeRequest(request, self.connections.leaseConnection(at: index), cancelTimeout: true),
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

        private mutating func nextActionForToBeClosedIdleConnection(
            at index: Int,
            context: HTTP1Connections.IdleConnectionContext
        ) -> EstablishedAction {
            // Step 1: Tell the connection pool to drop what it knows about this object.
            let connectionToClose = self.connections.closeConnection(at: index)

            // Step 2: Check whether we need a connection to replace this one. We do if we have fewer non-leased connections
            // than we requests + minimumPrewarming count _and_ the pool can grow. Note that in many cases the above closure
            // will have made some space, which is just fine.
            let nonLeased = self.connections.generalPurposeStats.nonLeased
            let neededNonLeased = self.requests.generalPurposeCount + self.preWarmedConnectionCount

            let connectionAction: EstablishedConnectionAction
            if nonLeased < neededNonLeased && self.connections.canGrow {
                // We re-use the EL of the connection we just closed.
                let newConnectionID = self.connections.createNewConnection(on: connectionToClose.eventLoop)
                connectionAction = .closeConnectionAndCreateConnection(
                    closeConnection: connectionToClose,
                    newConnectionID: newConnectionID,
                    on: connectionToClose.eventLoop
                )
            } else {
                connectionAction = .closeConnection(connectionToClose, isShutdown: .no)
            }
            return .init(
                request: .none,
                connection: connectionAction
            )
        }

        // MARK: Failed/Closed connection management

        private mutating func nextActionForFailedConnection(
            at index: Int,
            context: HTTP1Connections.FailedConnectionContext
        ) -> Action {
            switch self.lifecycleState {
            case .running:
                switch context.use {
                case .generalPurpose:
                    return self.nextActionForFailedGeneralPurposeConnection(at: index, context: context)
                case .eventLoop:
                    return self.nextActionForFailedEventLoopConnection(at: index, context: context)
                }

            case .shuttingDown(let unclean):
                assert(self.requests.isEmpty)
                self.connections.removeConnection(at: index)
                if self.connections.isEmpty && self.http2Connections == nil {
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

        private mutating func nextActionForFailedGeneralPurposeConnection(
            at index: Int,
            context: HTTP1Connections.FailedConnectionContext
        ) -> Action {
            let needConnectionForRequest =
                context.connectionsStartingForUseCase
                < (self.requests.generalPurposeCount + self.preWarmedConnectionCount)
            if needConnectionForRequest {
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
            if context.connectionsStartingForUseCase < self.requests.count(for: context.eventLoop) {
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

        private mutating func failAllRequests(reason error: Error) -> RequestAction {
            let allRequests = self.requests.removeAll()
            guard !allRequests.isEmpty else {
                return .none
            }
            return .failRequestsAndCancelTimeouts(allRequests, error)
        }

        // MARK: HTTP2

        mutating func newHTTP2MaxConcurrentStreamsReceived(_ connectionID: Connection.ID, newMaxStreams: Int) -> Action
        {
            // The `http2Connections` are optional here:
            // Connections report events back to us, if they are in a shutdown that was
            // initiated by the state machine. For this reason this callback might be invoked
            // even though all references to HTTP2Connections have already been cleared.
            _ = self.http2Connections?.newHTTP2MaxConcurrentStreamsReceived(connectionID, newMaxStreams: newMaxStreams)
            return .none
        }

        mutating func http2ConnectionGoAwayReceived(_ connectionID: Connection.ID) -> Action {
            // The `http2Connections` are optional here:
            // Connections report events back to us, if they are in a shutdown that was
            // initiated by the state machine. For this reason this callback might be invoked
            // even though all references to HTTP2Connections have already been cleared.
            _ = self.http2Connections?.goAwayReceived(connectionID)
            return .none
        }

        mutating func http2ConnectionClosed(_ connectionID: Connection.ID) -> Action {
            switch self.lifecycleState {
            case .running:
                _ = self.http2Connections?.failConnection(connectionID)
                if self.http2Connections?.isEmpty == true {
                    self.http2Connections = nil
                }
                return .none

            case .shuttingDown(let unclean):
                assert(self.requests.isEmpty)
                _ = self.http2Connections?.failConnection(connectionID)
                if self.http2Connections?.isEmpty == true {
                    self.http2Connections = nil
                }
                if self.connections.isEmpty && self.http2Connections == nil {
                    return .init(
                        request: .none,
                        connection: .cleanupConnections(.init(), isShutdown: .yes(unclean: unclean))
                    )
                }
                return .init(
                    request: .none,
                    connection: .none
                )

            case .shutDown:
                preconditionFailure("It the pool is already shutdown, all connections must have been torn down.")
            }
        }

        mutating func http2ConnectionStreamClosed(_ connectionID: Connection.ID) -> Action {
            // It is save to bang the http2Connections here. If we get this callback but we don't have
            // http2 connections something has gone terribly wrong.
            switch self.lifecycleState {
            case .running:
                let (index, context) = self.http2Connections!.releaseStream(connectionID)
                guard context.isIdle else {
                    return .none
                }

                let connection = self.http2Connections!.closeConnection(at: index)
                if self.http2Connections!.isEmpty {
                    self.http2Connections = nil
                }
                return .init(
                    request: .none,
                    connection: .closeConnection(connection, isShutdown: .no)
                )

            case .shuttingDown(let unclean):
                assert(self.requests.isEmpty)
                let (index, context) = self.http2Connections!.releaseStream(connectionID)
                guard context.isIdle else {
                    return .none
                }

                let connection = self.http2Connections!.closeConnection(at: index)
                if self.http2Connections!.isEmpty {
                    self.http2Connections = nil
                }
                if self.connections.isEmpty && self.http2Connections == nil {
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
    }
}

extension HTTPConnectionPool.HTTP1StateMachine: CustomStringConvertible {
    var description: String {
        let stats = self.connections.stats
        let queued = self.requests.count

        return
            "connections: [connecting: \(stats.connecting) | backoff: \(stats.backingOff) | leased: \(stats.leased) | idle: \(stats.idle)], queued: \(queued)"
    }
}
