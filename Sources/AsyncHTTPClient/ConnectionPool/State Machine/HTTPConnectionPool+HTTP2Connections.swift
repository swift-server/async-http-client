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
    private struct HTTP2ConnectionState {
        private enum State {
            /// the pool is establishing a connection. Valid transitions are to: .backingOff, .active and .closed
            case starting(maximumUses: Int?)
            /// the connection is waiting to retry to establish a connection. Valid transitions are to .closed.
            /// From .closed a new connection state must be created for a retry.
            case backingOff
            /// the connection is active and is able to run requests. Valid transitions are to: .draining and .closed
            case active(Connection, maxStreams: Int, usedStreams: Int, lastIdle: NIODeadline, remainingUses: Int?)
            /// the connection is active and is running requests. No new requests must be scheduled.
            /// Valid transitions to: .draining and .closed
            case draining(Connection, maxStreams: Int, usedStreams: Int)
            /// the connection is closed
            case closed
        }

        var isStartingOrBackingOff: Bool {
            switch self.state {
            case .starting, .backingOff:
                return true
            case .active, .draining, .closed:
                return false
            }
        }

        var canOrWillBeAbleToExecuteRequests: Bool {
            switch self.state {
            case .starting, .backingOff, .active:
                return true
            case .draining, .closed:
                return false
            }
        }

        var isStartingOrActive: Bool {
            switch self.state {
            case .starting, .active:
                return true
            case .draining, .backingOff, .closed:
                return false
            }
        }

        /// A connection is established and can potentially execute requests if not all streams are leased
        var isActive: Bool {
            switch self.state {
            case .active:
                return true
            case .starting, .backingOff, .draining, .closed:
                return false
            }
        }

        /// A request can be scheduled on the connection
        var isAvailable: Bool {
            switch self.state {
            case .active(_, let maxStreams, let usedStreams, _, let remainingUses):
                if let remainingUses = remainingUses {
                    return usedStreams < maxStreams && remainingUses > 0
                } else {
                    return usedStreams < maxStreams
                }
            case .starting, .backingOff, .draining, .closed:
                return false
            }
        }

        /// The connection is active, but there are no running requests on the connection.
        /// Every idle connection is available, but not every available connection is idle.
        var isIdle: Bool {
            switch self.state {
            case .active(_, _, let usedStreams, _, _):
                return usedStreams == 0
            case .starting, .backingOff, .draining, .closed:
                return false
            }
        }

        var isClosed: Bool {
            switch self.state {
            case .starting, .backingOff, .draining, .active:
                return false
            case .closed:
                return true
            }
        }

        private var state: State
        let eventLoop: EventLoop
        let connectionID: Connection.ID

        /// should be called after the connection was successfully established
        /// - Parameters:
        ///   - conn: HTTP2 connection
        ///   - maxStreams: max streams settings from the server
        /// - Returns: number of available streams which can be leased
        mutating func connected(_ conn: Connection, maxStreams: Int) -> Int {
            switch self.state {
            case .active, .draining, .backingOff, .closed:
                preconditionFailure("Invalid state: \(self.state)")

            case .starting(let maxUses):
                self.state = .active(
                    conn,
                    maxStreams: maxStreams,
                    usedStreams: 0,
                    lastIdle: .now(),
                    remainingUses: maxUses
                )
                if let maxUses = maxUses {
                    return min(maxStreams, maxUses)
                } else {
                    return maxStreams
                }
            }
        }

        /// should be called after receiving new http2 settings from the server
        /// - Parameters:
        ///   - maxStreams: max streams settings from the server
        /// - Returns: number of available streams which can be leased
        mutating func newMaxConcurrentStreams(_ maxStreams: Int) -> Int {
            switch self.state {
            case .starting, .backingOff, .closed:
                preconditionFailure("Invalid state for updating max concurrent streams: \(self.state)")

            case .active(let conn, _, let usedStreams, let lastIdle, let remainingUses):
                self.state = .active(
                    conn,
                    maxStreams: maxStreams,
                    usedStreams: usedStreams,
                    lastIdle: lastIdle,
                    remainingUses: remainingUses
                )
                let availableStreams = max(maxStreams - usedStreams, 0)
                if let remainingUses = remainingUses {
                    return min(remainingUses, availableStreams)
                } else {
                    return availableStreams
                }

            case .draining(let conn, _, let usedStreams):
                self.state = .draining(conn, maxStreams: maxStreams, usedStreams: usedStreams)
                return 0
            }
        }

        mutating func goAwayReceived() -> EventLoop {
            switch self.state {
            case .starting, .backingOff, .closed:
                preconditionFailure("Invalid state for draining a connection: \(self.state)")

            case .active(let conn, let maxStreams, let usedStreams, _, _):
                self.state = .draining(conn, maxStreams: maxStreams, usedStreams: usedStreams)
                return conn.eventLoop

            case .draining(let conn, _, _):
                // we could potentially receive another go away while we drain all active streams and we just ignore it
                return conn.eventLoop
            }
        }

        /// The connection failed to start
        mutating func failedToConnect() {
            switch self.state {
            case .starting:
                self.state = .backingOff
            case .backingOff, .active, .draining, .closed:
                preconditionFailure("Invalid state: \(self.state)")
            }
        }

        enum FailAction {
            case removeConnection
            case none
        }

        mutating func fail() -> FailAction {
            switch self.state {
            case .starting:
                // If the connection fails while we are starting it, the fail call raced with
                // `failedToConnect` (promises are succeeded or failed before channel handler
                // callbacks). let's keep the state in `starting`, so that `failedToConnect` can
                // create a backoff timer.
                return .none
            case .active, .backingOff, .draining:
                self.state = .closed
                return .removeConnection
            case .closed:
                preconditionFailure("Invalid state: \(self.state)")
            }
        }

        mutating func lease(_ count: Int) -> Connection {
            switch self.state {
            case .starting, .backingOff, .draining, .closed:
                preconditionFailure("Invalid state for leasing a stream: \(self.state)")

            case .active(let conn, let maxStreams, var usedStreams, let lastIdle, let remainingUses):
                usedStreams += count
                precondition(usedStreams <= maxStreams, "tried to lease a connection which is not available")
                precondition(
                    remainingUses.map { $0 >= count } ?? true,
                    "tried to lease streams from a connection which does not have enough remaining streams"
                )
                self.state = .active(
                    conn,
                    maxStreams: maxStreams,
                    usedStreams: usedStreams,
                    lastIdle: lastIdle,
                    remainingUses: remainingUses.map { $0 - count }
                )
                return conn
            }
        }

        /// should be called after a request has finished and the stream can be used again for a new request
        /// - Returns: number of available streams which can be leased
        mutating func release() -> Int {
            switch self.state {
            case .starting, .backingOff, .closed:
                preconditionFailure("Invalid state: \(self.state)")

            case .active(let conn, let maxStreams, var usedStreams, var lastIdle, let remainingUses):
                precondition(usedStreams > 0, "we cannot release more streams than we have leased")
                usedStreams &-= 1
                if usedStreams == 0 {
                    lastIdle = .now()
                }

                self.state = .active(
                    conn,
                    maxStreams: maxStreams,
                    usedStreams: usedStreams,
                    lastIdle: lastIdle,
                    remainingUses: remainingUses
                )
                let availableStreams = max(maxStreams &- usedStreams, 0)
                if let remainingUses = remainingUses {
                    return min(availableStreams, remainingUses)
                } else {
                    return availableStreams
                }

            case .draining(let conn, let maxStreams, var usedStreams):
                precondition(usedStreams > 0, "we cannot release more streams than we have leased")
                usedStreams &-= 1
                self.state = .draining(conn, maxStreams: maxStreams, usedStreams: usedStreams)
                return 0
            }
        }

        mutating func close() -> Connection {
            switch self.state {
            case .active(let conn, _, 0, _, _):
                self.state = .closed
                return conn

            case .starting, .backingOff, .draining, .closed, .active:
                preconditionFailure("Invalid state for closing a connection: \(self.state)")
            }
        }

        enum CleanupAction {
            case removeConnection
            case keepConnection
        }

        /// Cleanup the current connection for shutdown.
        ///
        /// This method is called, when the connections shall shutdown. Depending on the state
        /// the connection is in, it adds itself to one of the arrays that are used to signal shutdown
        /// intent to the underlying connections. Connections that are backing off can be easily
        /// dropped (since, we only need to cancel the backoff timer), connections that are leased
        /// need to be cancelled (notifying the `ChannelHandler` that we want to cancel the
        /// running request), connections that are idle can be closed right away. Sadly we can't
        /// cancel connection starts right now. For this reason we need to wait for them to succeed
        /// or fail until we finalize the shutdown.
        ///
        /// - Parameter context: A cleanup context to add the connection to based on its state.
        /// - Returns: A cleanup action indicating if the connection can be removed from the
        ///            connection list.
        func cleanup(_ context: inout CleanupContext) -> CleanupAction {
            switch self.state {
            case .starting:
                return .keepConnection

            case .backingOff:
                context.connectBackoff.append(self.connectionID)
                return .removeConnection

            case .active(let connection, _, let usedStreams, _, _):
                precondition(usedStreams >= 0)
                if usedStreams == 0 {
                    context.close.append(connection)
                    return .removeConnection
                } else {
                    context.cancel.append(connection)
                    return .keepConnection
                }

            case .draining(let connection, _, _):
                context.cancel.append(connection)
                return .keepConnection

            case .closed:
                preconditionFailure(
                    "Unexpected state for cleanup: Did not expect to have closed connections in the state machine."
                )
            }
        }

        func addStats(into stats: inout HTTP2Connections.Stats) {
            switch self.state {
            case .starting:
                stats.startingConnections &+= 1

            case .backingOff:
                stats.backingOffConnections &+= 1

            case .active(_, let maxStreams, let usedStreams, _, _):
                stats.availableStreams += max(maxStreams - usedStreams, 0)
                stats.leasedStreams += usedStreams
                stats.availableConnections &+= 1
                precondition(usedStreams >= 0)
                if usedStreams == 0 {
                    stats.idleConnections &+= 1
                }
            case .draining(_, _, let usedStreams):
                stats.drainingConnections &+= 1
                stats.leasedStreams += usedStreams
                precondition(usedStreams >= 0)
            case .closed:
                break
            }
        }

        enum MigrateAction {
            case removeConnection
            case keepConnection
        }

        func migrateToHTTP1(
            context: inout HTTP2Connections.HTTP2ToHTTP1MigrationContext
        ) -> MigrateAction {
            switch self.state {
            case .starting:
                context.starting.append((self.connectionID, self.eventLoop))
                return .removeConnection

            case .active(let connection, _, let usedStreams, _, _):
                precondition(usedStreams >= 0)
                if usedStreams == 0 {
                    context.close.append(connection)
                    return .removeConnection
                } else {
                    return .keepConnection
                }

            case .draining:
                return .keepConnection

            case .backingOff:
                context.backingOff.append((self.connectionID, self.eventLoop))
                return .removeConnection

            case .closed:
                preconditionFailure(
                    "Unexpected state: Did not expect to have connections with this state in the state machine: \(self.state)"
                )
            }
        }

        init(connectionID: Connection.ID, eventLoop: EventLoop, maximumUses: Int?) {
            self.connectionID = connectionID
            self.eventLoop = eventLoop
            self.state = .starting(maximumUses: maximumUses)
        }
    }

    struct HTTP2Connections {
        /// A connectionID generator.
        private let generator: Connection.ID.Generator
        /// The connections states
        private var connections: [HTTP2ConnectionState]
        /// The number of times each connection can be used before it is closed and replaced.
        private let maximumConnectionUses: Int?

        var isEmpty: Bool {
            self.connections.isEmpty
        }

        var stats: Stats {
            self.connections.reduce(into: Stats()) { stats, connection in
                connection.addStats(into: &stats)
            }
        }

        init(generator: Connection.ID.Generator, maximumConnectionUses: Int?) {
            self.generator = generator
            self.connections = []
            self.maximumConnectionUses = maximumConnectionUses
        }

        // MARK: Migration

        /// We only handle starting and backing off connection here.
        /// All already running connections must be handled by the enclosing state machine.
        /// - Parameters:
        ///   - starting: starting HTTP connections from previous state machine
        ///   - backingOff: backing off HTTP connections from previous state machine
        mutating func migrateFromHTTP1(
            starting: [(Connection.ID, EventLoop)],
            backingOff: [(Connection.ID, EventLoop)]
        ) {
            for (connectionID, eventLoop) in starting {
                let newConnection = HTTP2ConnectionState(
                    connectionID: connectionID,
                    eventLoop: eventLoop,
                    maximumUses: self.maximumConnectionUses
                )
                self.connections.append(newConnection)
            }

            for (connectionID, eventLoop) in backingOff {
                var backingOffConnection = HTTP2ConnectionState(
                    connectionID: connectionID,
                    eventLoop: eventLoop,
                    maximumUses: self.maximumConnectionUses
                )
                // TODO: Maybe we want to add a static init for backing off connections to HTTP2ConnectionState
                backingOffConnection.failedToConnect()
                self.connections.append(backingOffConnection)
            }
        }

        /// We will create new connections for `requiredEventLoopsOfPendingRequests`
        /// if we do not already have a connection that can or will be able to execute requests on the given event loop.
        /// - Parameters:
        ///   - requiredEventLoopsForPendingRequests: event loops for which we have requests with a required event loop. Duplicates are not allowed.
        /// - Returns: new connections that need to be created
        mutating func createConnectionsAfterMigrationIfNeeded(
            requiredEventLoopsOfPendingRequests: [EventLoop]
        ) -> [(Connection.ID, EventLoop)] {
            // create new connections for requests with a required event loop
            let eventLoopsWithConnectionThatCanOrWillBeAbleToExecuteRequests = Set(
                self.connections.lazy
                    .filter {
                        $0.canOrWillBeAbleToExecuteRequests
                    }.map {
                        $0.eventLoop.id
                    }
            )
            return requiredEventLoopsOfPendingRequests.compactMap { eventLoop -> (Connection.ID, EventLoop)? in
                guard !eventLoopsWithConnectionThatCanOrWillBeAbleToExecuteRequests.contains(eventLoop.id)
                else { return nil }
                let connectionID = self.createNewConnection(on: eventLoop)
                return (connectionID, eventLoop)
            }
        }

        struct HTTP2ToHTTP1MigrationContext {
            var backingOff: [(Connection.ID, EventLoop)] = []
            var starting: [(Connection.ID, EventLoop)] = []
            var close: [Connection] = []
        }

        mutating func migrateToHTTP1() -> HTTP2ToHTTP1MigrationContext {
            var context = HTTP2ToHTTP1MigrationContext()
            self.connections.removeAll { connection in
                switch connection.migrateToHTTP1(context: &context) {
                case .removeConnection:
                    return true
                case .keepConnection:
                    return false
                }
            }
            return context
        }

        // MARK: Connection creation

        /// true if one ore more connections are active
        var hasActiveConnections: Bool {
            self.connections.contains { $0.isActive }
        }

        /// used in general purpose connection scenarios to check if at least one connection is starting, backing off or active
        var hasConnectionThatCanOrWillBeAbleToExecuteRequests: Bool {
            self.connections.contains { $0.canOrWillBeAbleToExecuteRequests }
        }

        /// used in eventLoop scenarios. does at least one connection exist for this eventLoop, or should we create a new one?
        /// - Parameter eventLoop: connection `EventLoop` to search for
        /// - Returns: true if at least one connection is starting, backing off or active for the given `eventLoop`
        func hasConnectionThatCanOrWillBeAbleToExecuteRequests(for eventLoop: EventLoop) -> Bool {
            self.connections.contains {
                $0.eventLoop === eventLoop && $0.canOrWillBeAbleToExecuteRequests
            }
        }

        func hasActiveConnection(for eventLoop: EventLoop) -> Bool {
            self.connections.contains {
                $0.eventLoop === eventLoop && $0.isActive
            }
        }

        /// used after backoff is done to determine if we need to create a new connection
        /// - Parameters:
        ///   - eventLoop: connection `EventLoop` to search for
        /// - Returns: if we have a starting or active general purpose connection and if we have also one for the given `eventLoop`
        func backingOffTimerDone(
            for eventLoop: EventLoop
        ) -> RetryConnectionCreationContext {
            var hasGeneralPurposeConnection: Bool = false
            var hasConnectionOnSpecifiedEventLoop: Bool = false
            for connection in self.connections {
                guard connection.isStartingOrActive else { continue }
                hasGeneralPurposeConnection = true
                guard connection.eventLoop === eventLoop else { continue }
                hasConnectionOnSpecifiedEventLoop = true
                break
            }
            return RetryConnectionCreationContext(
                hasGeneralPurposeConnection: hasGeneralPurposeConnection,
                hasConnectionOnSpecifiedEventLoop: hasConnectionOnSpecifiedEventLoop
            )
        }

        mutating func createNewConnection(on eventLoop: EventLoop) -> Connection.ID {
            assert(
                !self.hasConnectionThatCanOrWillBeAbleToExecuteRequests(for: eventLoop),
                "we should not create more than one connection per event loop"
            )

            let connection = HTTP2ConnectionState(
                connectionID: self.generator.next(),
                eventLoop: eventLoop,
                maximumUses: self.maximumConnectionUses
            )
            self.connections.append(connection)
            return connection.connectionID
        }

        /// A new HTTP/2 connection was established.
        ///
        /// This will put the connection into the idle state.
        ///
        /// - Parameter connection: The new established connection.
        /// - Returns: An index and an ``EstablishedConnectionContext`` to determine the next action for the now idle connection.
        ///            Call ``leaseStreams(at:count:)`` or ``closeConnection(at:)`` with the supplied index after
        ///            this.
        mutating func newHTTP2ConnectionEstablished(
            _ connection: Connection,
            maxConcurrentStreams: Int
        ) -> (Int, EstablishedConnectionContext) {
            guard let index = self.connections.firstIndex(where: { $0.connectionID == connection.id }) else {
                preconditionFailure("There is a new connection that we didn't request!")
            }
            precondition(
                connection.eventLoop === self.connections[index].eventLoop,
                "Expected the new connection to be on EL"
            )
            let availableStreams = self.connections[index].connected(connection, maxStreams: maxConcurrentStreams)
            let context = EstablishedConnectionContext(
                availableStreams: availableStreams,
                eventLoop: connection.eventLoop,
                isIdle: self.connections[index].isIdle,
                connectionID: connection.id
            )
            return (index, context)
        }

        /// Move the connection state to backingOff.
        ///
        /// - Parameter connectionID: The connectionID of the failed connection attempt
        /// - Returns: The eventLoop on which to schedule the backoff timer
        /// - Precondition: connection needs to be in the `.starting` state
        mutating func backoffNextConnectionAttempt(_ connectionID: Connection.ID) -> EventLoop {
            guard let index = self.connections.firstIndex(where: { $0.connectionID == connectionID }) else {
                preconditionFailure("We tried to create a new connection that we know nothing about?")
            }

            self.connections[index].failedToConnect()
            return self.connections[index].eventLoop
        }

        // MARK: Connection lifecycle events

        /// Sets the connection with the given `connectionId` to the draining state.
        /// - Returns: the `EventLoop` to create a new connection on if applicable
        /// - Precondition: connection with given `connectionId` must be either `.active` or already in the `.draining` state
        mutating func goAwayReceived(_ connectionID: Connection.ID) -> GoAwayContext? {
            guard let index = self.connections.firstIndex(where: { $0.connectionID == connectionID }) else {
                // When a connection close is initiated by the connection pool (e.g. because the
                // connection was idle for too long), the connection will still report further
                // events to the state machine even though we don't care about its state anymore.
                //
                // This is because the HTTP2Connection has a strong let reference to its delegate.
                return nil
            }
            let eventLoop = self.connections[index].goAwayReceived()
            return GoAwayContext(eventLoop: eventLoop)
        }

        /// Update the maximum number of concurrent streams for the given connection.
        /// - Parameters:
        ///   - connectionID: The connectionID for which we received new settings
        ///   - newMaxStreams: new maximum concurrent streams
        /// - Returns: index of the connection and new number of available streams in the `EstablishedConnectionContext`
        /// - Precondition: Connections must be in the `.active` or `.draining` state.
        mutating func newHTTP2MaxConcurrentStreamsReceived(
            _ connectionID: Connection.ID,
            newMaxStreams: Int
        ) -> (Int, EstablishedConnectionContext)? {
            guard let index = self.connections.firstIndex(where: { $0.connectionID == connectionID }) else {
                // When a connection close is initiated by the connection pool (e.g. because the
                // connection was idle for too long), the connection will still report its events to
                // the state machine and hence to this `HTTP2Connections` struct. In those cases we
                // must ignore the event.
                return nil
            }
            let availableStreams = self.connections[index].newMaxConcurrentStreams(newMaxStreams)
            let context = EstablishedConnectionContext(
                availableStreams: availableStreams,
                eventLoop: self.connections[index].eventLoop,
                isIdle: self.connections[index].isIdle,
                connectionID: connectionID
            )
            return (index, context)
        }

        // MARK: Leasing and releasing

        mutating func leaseStream(onPreferred eventLoop: EventLoop) -> (Connection, LeasedStreamContext)? {
            guard let index = self.findAvailableConnection(onPreferred: eventLoop) else { return nil }
            return self.leaseStreams(at: index, count: 1)
        }

        /// tries to find an available connection on the preferred `eventLoop`. If it can't find one with the given `eventLoop`, it returns the first available connection
        private func findAvailableConnection(onPreferred eventLoop: EventLoop) -> Int? {
            var availableConnectionIndex: Int?
            for (offset, connection) in self.connections.enumerated() {
                guard connection.isAvailable else { continue }
                if connection.eventLoop === eventLoop {
                    return self.connections.index(self.connections.startIndex, offsetBy: offset)
                } else if availableConnectionIndex == nil {
                    availableConnectionIndex = self.connections.index(self.connections.startIndex, offsetBy: offset)
                }
            }
            return availableConnectionIndex
        }

        mutating func leaseStream(onRequired eventLoop: EventLoop) -> (Connection, LeasedStreamContext)? {
            guard let index = self.findAvailableConnection(onRequired: eventLoop) else { return nil }
            return self.leaseStreams(at: index, count: 1)
        }

        /// tries to find an available connection on the required `eventLoop`
        private func findAvailableConnection(onRequired eventLoop: EventLoop) -> Int? {
            self.connections.firstIndex(where: { $0.eventLoop === eventLoop && $0.isAvailable })
        }

        /// lease `count` streams after connections establishment
        /// - Parameters:
        ///   - index: index of the connection you got by calling `newHTTP2ConnectionEstablished(_:maxConcurrentStreams:)`
        ///   - count: number of streams you want to lease. You get the current available streams from the `EstablishedConnectionContext` which `newHTTP2ConnectionEstablished(_:maxConcurrentStreams:)` returns
        /// - Returns: connection to execute `count` requests on
        /// - precondition: `index` needs to be valid. `count` must be greater than or equal to *1* and not exceed the number of available streams.
        mutating func leaseStreams(at index: Int, count: Int) -> (Connection, LeasedStreamContext) {
            precondition(count >= 1, "stream lease count must be greater than or equal to 1")
            let isIdle = self.connections[index].isIdle
            let connection = self.connections[index].lease(count)
            let context = LeasedStreamContext(wasIdle: isIdle)
            return (connection, context)
        }

        mutating func releaseStream(_ connectionID: Connection.ID) -> (Int, EstablishedConnectionContext) {
            guard let index = self.connections.firstIndex(where: { $0.connectionID == connectionID }) else {
                preconditionFailure("We tried to release a connection we do not know anything about")
            }
            let availableStreams = self.connections[index].release()
            let context = EstablishedConnectionContext(
                availableStreams: availableStreams,
                eventLoop: self.connections[index].eventLoop,
                isIdle: self.connections[index].isIdle,
                connectionID: connectionID
            )
            return (index, context)
        }

        // MARK: Connection close/removal

        /// Closes the connection at the given index. This will also remove the connection right away.
        /// - Parameter index: index of the connection which we get from `releaseStream(_:)`
        /// - Returns: closed and removed connection
        mutating func closeConnection(at index: Int) -> Connection {
            let connection = self.connections[index].close()
            self.removeConnection(at: index)
            return connection
        }

        /// removes a closed connection.
        /// - Parameter index: index of the connection which we get from `failConnection(_:)`
        /// - Precondition: connection must be closed
        mutating func removeConnection(at index: Int) {
            precondition(self.connections[index].isClosed, "We tried to remove a connection which is not closed")
            self.connections.remove(at: index)
        }

        mutating func closeConnectionIfIdle(_ connectionID: Connection.ID) -> Connection? {
            guard let index = self.connections.firstIndex(where: { $0.connectionID == connectionID }) else {
                // because of a race this connection (connection close runs against trigger of timeout)
                // was already removed from the state machine.
                return nil
            }
            guard self.connections[index].isIdle else {
                // connection is not idle anymore, we may have just leased it for a request
                return nil
            }
            return self.closeConnection(at: index)
        }

        /// replaces a closed connection by creating a new starting connection.
        /// - Parameter index: index of the connection which we got from `failConnection(_:)`
        /// - Precondition: connection must be closed
        mutating func createNewConnectionByReplacingClosedConnection(at index: Int) -> (Connection.ID, EventLoop) {
            precondition(self.connections[index].isClosed)
            let newConnection = HTTP2ConnectionState(
                connectionID: self.generator.next(),
                eventLoop: self.connections[index].eventLoop,
                maximumUses: self.maximumConnectionUses
            )

            self.connections[index] = newConnection
            return (newConnection.connectionID, newConnection.eventLoop)
        }

        mutating func failConnection(_ connectionID: Connection.ID) -> (Int, FailedConnectionContext)? {
            guard let index = self.connections.firstIndex(where: { $0.connectionID == connectionID }) else {
                // When a connection close is initiated by the connection pool (e.g. because the
                // connection was idle for too long), the connection will still report its close to
                // the state machine and then to this `HTTP2Connections` struct. In those cases we
                // must ignore the event.
                return nil
            }

            switch self.connections[index].fail() {
            case .none:
                return nil

            case .removeConnection:
                let eventLoop = self.connections[index].eventLoop
                let context = FailedConnectionContext(eventLoop: eventLoop)
                return (index, context)
            }
        }

        mutating func shutdown() -> CleanupContext {
            var cleanupContext = CleanupContext()
            self.connections.removeAll(where: { connectionState in
                switch connectionState.cleanup(&cleanupContext) {
                case .removeConnection:
                    return true
                case .keepConnection:
                    return false
                }
            })
            return cleanupContext
        }

        // MARK: Result structs

        struct RetryConnectionCreationContext {
            /// true if at least one connection is starting or active regardless of the event loop.
            let hasGeneralPurposeConnection: Bool

            ///  true if at least one connection is starting or active for the given `eventLoop`
            let hasConnectionOnSpecifiedEventLoop: Bool
        }

        /// Information around a connection which is either in the .active or .draining state.
        struct EstablishedConnectionContext {
            /// number of streams which can be leased
            var availableStreams: Int
            /// The eventLoop the connection is running on.
            var eventLoop: EventLoop
            /// true if no stream is leased
            var isIdle: Bool
            /// id of the connection
            var connectionID: Connection.ID
        }

        struct LeasedStreamContext {
            /// true if the connection was idle before leasing the stream
            var wasIdle: Bool
        }

        struct GoAwayContext {
            /// The eventLoop the connection is running on.
            var eventLoop: EventLoop
        }

        /// Information around the failed/closed connection.
        struct FailedConnectionContext {
            /// The eventLoop the connection ran on.
            var eventLoop: EventLoop
        }

        struct Stats: Equatable {
            var startingConnections: Int = 0
            var backingOffConnections: Int = 0
            var idleConnections: Int = 0
            var availableConnections: Int = 0
            var drainingConnections: Int = 0
            var leasedStreams: Int = 0
            var availableStreams: Int = 0
        }
    }
}
