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
    /// Represents the state of a single HTTP/1.1 connection
    private struct HTTP1ConnectionState {
        enum State {
            /// the connection is creating a connection. Valid transitions are to: .backingOff, .idle, and .closed
            case starting(maximumUses: Int?)
            /// the connection is waiting to retry the establishing a connection. Valid transitions are to: .closed.
            /// This means, the connection can be removed from the connections without cancelling external
            /// state. The connection state can then be replaced by a new one.
            case backingOff
            /// the connection is idle for a new request. Valid transitions to: .leased and .closed
            case idle(Connection, since: NIODeadline, remainingUses: Int?)
            /// the connection is leased and running for a request. Valid transitions to: .idle and .closed
            case leased(Connection, remainingUses: Int?)
            /// the connection is closed. final state.
            case closed
        }

        private var state: State
        let connectionID: Connection.ID
        let eventLoop: EventLoop

        init(connectionID: Connection.ID, eventLoop: EventLoop, maximumUses: Int?) {
            self.connectionID = connectionID
            self.eventLoop = eventLoop
            self.state = .starting(maximumUses: maximumUses)
        }

        var isConnecting: Bool {
            switch self.state {
            case .starting:
                return true
            case .backingOff, .closed, .idle, .leased:
                return false
            }
        }

        var isBackingOff: Bool {
            switch self.state {
            case .backingOff:
                return true
            case .starting, .closed, .idle, .leased:
                return false
            }
        }

        var isIdle: Bool {
            switch self.state {
            case .idle:
                return true
            case .backingOff, .starting, .leased, .closed:
                return false
            }
        }

        var idleAndNoRemainingUses: Bool {
            switch self.state {
            case .idle(_, since: _, let remainingUses):
                if let remainingUses = remainingUses {
                    return remainingUses <= 0
                } else {
                    return false
                }
            case .backingOff, .starting, .leased, .closed:
                return false
            }
        }

        var canOrWillBeAbleToExecuteRequests: Bool {
            switch self.state {
            case .leased, .backingOff, .idle, .starting:
                return true
            case .closed:
                return false
            }
        }

        var isLeased: Bool {
            switch self.state {
            case .leased:
                return true
            case .backingOff, .starting, .idle, .closed:
                return false
            }
        }

        var idleSince: NIODeadline? {
            switch self.state {
            case .idle(_, since: let idleSince, _):
                return idleSince
            case .backingOff, .starting, .leased, .closed:
                return nil
            }
        }

        var isClosed: Bool {
            switch self.state {
            case .closed:
                return true
            case .idle, .starting, .leased, .backingOff:
                return false
            }
        }

        mutating func connected(_ connection: Connection) {
            switch self.state {
            case .starting(maximumUses: let maxUses):
                self.state = .idle(connection, since: .now(), remainingUses: maxUses)
            case .backingOff, .idle, .leased, .closed:
                preconditionFailure("Invalid state: \(self.state)")
            }
        }

        /// The connection failed to start
        mutating func failedToConnect() {
            switch self.state {
            case .starting:
                self.state = .backingOff
            case .backingOff, .idle, .leased, .closed:
                preconditionFailure("Invalid state: \(self.state)")
            }
        }

        mutating func lease() -> Connection {
            switch self.state {
            case .idle(let connection, since: _, let remainingUses):
                self.state = .leased(connection, remainingUses: remainingUses.map { $0 - 1 })
                return connection
            case .backingOff, .starting, .leased, .closed:
                preconditionFailure("Invalid state: \(self.state)")
            }
        }

        mutating func release() {
            switch self.state {
            case .leased(let connection, let remainingUses):
                self.state = .idle(connection, since: .now(), remainingUses: remainingUses)
            case .backingOff, .starting, .idle, .closed:
                preconditionFailure("Invalid state: \(self.state)")
            }
        }

        mutating func close() -> Connection {
            switch self.state {
            case .idle(let connection, since: _, remainingUses: _):
                self.state = .closed
                return connection
            case .backingOff, .starting, .leased, .closed:
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
            case .backingOff, .idle, .leased:
                self.state = .closed
                return .removeConnection
            case .closed:
                preconditionFailure("Invalid state: \(self.state)")
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
            case .backingOff:
                context.connectBackoff.append(self.connectionID)
                return .removeConnection
            case .starting:
                return .keepConnection
            case .idle(let connection, since: _, remainingUses: _):
                context.close.append(connection)
                return .removeConnection
            case .leased(let connection, remainingUses: _):
                context.cancel.append(connection)
                return .keepConnection
            case .closed:
                preconditionFailure(
                    "Unexpected state: Did not expect to have connections with this state in the state machine: \(self.state)"
                )
            }
        }

        enum MigrateAction {
            case removeConnection
            case keepConnection
        }

        func migrateToHTTP2(_ context: inout HTTP1Connections.HTTP1ToHTTP2MigrationContext) -> MigrateAction {
            switch self.state {
            case .starting:
                context.starting.append((self.connectionID, self.eventLoop))
                return .removeConnection
            case .backingOff:
                context.backingOff.append((self.connectionID, self.eventLoop))
                return .removeConnection
            case .idle(let connection, since: _, remainingUses: _):
                // Idle connections can be removed right away
                context.close.append(connection)
                return .removeConnection
            case .leased:
                return .keepConnection
            case .closed:
                preconditionFailure(
                    "Unexpected state: Did not expect to have connections with this state in the state machine: \(self.state)"
                )
            }
        }
    }

    /// A structure to hold the currently active HTTP/1.1 connections.
    ///
    /// The general purpose connection pool (pool for requests that don't have special `EventLoop`
    /// requirements) will grow up until `maximumConcurrentConnections`. If requests have
    /// special `EventLoop` requirements overflow connections might be opened.
    ///
    /// All connections live in the same `connections` array. In the front are the general purpose
    /// connections. In the back (starting with the `overflowIndex`) are the connections for
    /// requests with special needs.
    struct HTTP1Connections {
        /// The maximum number of connections in the general purpose pool.
        private let maximumConcurrentConnections: Int
        /// A connectionID generator.
        private let generator: Connection.ID.Generator
        /// The connections states
        private var connections: [HTTP1ConnectionState]
        /// The index after which you will find the connections for requests with `EventLoop`
        /// requirements in `connections`.
        private var overflowIndex: Array<HTTP1ConnectionState>.Index
        /// The number of times each connection can be used before it is closed and replaced.
        private let maximumConnectionUses: Int?
        /// How many pre-warmed connections we should create.
        private let preWarmedConnectionCount: Int

        init(
            maximumConcurrentConnections: Int,
            generator: Connection.ID.Generator,
            maximumConnectionUses: Int?,
            preWarmedHTTP1ConnectionCount: Int
        ) {
            self.connections = []
            self.connections.reserveCapacity(min(maximumConcurrentConnections, 1024))
            self.overflowIndex = self.connections.endIndex
            self.maximumConcurrentConnections = maximumConcurrentConnections
            self.generator = generator
            self.maximumConnectionUses = maximumConnectionUses
            self.preWarmedConnectionCount = preWarmedHTTP1ConnectionCount
        }

        var stats: Stats {
            self.connectionStats(in: self.connections.startIndex..<self.connections.endIndex)
        }

        var generalPurposeStats: Stats {
            self.connectionStats(in: self.connections.startIndex..<self.overflowIndex)
        }

        var isEmpty: Bool {
            self.connections.isEmpty
        }

        var canGrow: Bool {
            self.overflowIndex < self.maximumConcurrentConnections
        }

        var startingGeneralPurposeConnections: Int {
            var connecting = 0
            for connectionState in self.connections[0..<self.overflowIndex] {
                if connectionState.isConnecting || connectionState.isBackingOff {
                    // connecting can't be greater than self.connections.count so it can't overflow.
                    // For this reason we can save the bounds check.
                    connecting &+= 1
                }
            }
            return connecting
        }

        private var maximumAdditionalGeneralPurposeConnections: Int {
            self.maximumConcurrentConnections - (self.overflowIndex)
        }

        /// Is there at least one connection that is able to run requests
        var hasActiveConnections: Bool {
            self.connections.contains(where: { $0.isIdle || $0.isLeased })
        }

        func startingEventLoopConnections(on eventLoop: EventLoop) -> Int {
            self.connections[self.overflowIndex..<self.connections.endIndex].reduce(into: 0) { count, connection in
                guard connection.eventLoop === eventLoop else { return }
                if connection.isConnecting || connection.isBackingOff {
                    count &+= 1
                }
            }
        }

        private func connectionStats(in range: Range<Int>) -> Stats {
            var stats = Stats()
            // all additions here can be unchecked, since we will have at max self.connections.count
            // which itself is an Int. For this reason we will never overflow.
            for connectionState in self.connections[range] {
                if connectionState.isConnecting {
                    stats.connecting &+= 1
                } else if connectionState.isBackingOff {
                    stats.backingOff &+= 1
                } else if connectionState.isLeased {
                    stats.leased &+= 1
                } else if connectionState.isIdle {
                    stats.idle &+= 1
                }
            }
            return stats
        }

        // MARK: - Mutations -

        /// A connection's use. Did it serve in the pool or was it specialized for an `EventLoop`?
        enum ConnectionUse {
            case generalPurpose
            case eventLoop(EventLoop)
        }

        /// Information around an idle connection.
        struct IdleConnectionContext {
            /// The `EventLoop` the connection runs on.
            var eventLoop: EventLoop
            /// The connection's use. Either general purpose or for requests with `EventLoop`
            /// requirements.
            var use: ConnectionUse
            /// Whether the connection should be closed.
            var shouldBeClosed: Bool
        }

        /// Information around the failed/closed connection.
        struct FailedConnectionContext {
            /// The eventLoop the connection ran on.
            var eventLoop: EventLoop
            /// The failed connection's use.
            var use: ConnectionUse
            /// Connections that we start up for this use-case
            var connectionsStartingForUseCase: Int
        }

        struct HTTP1ToHTTP2MigrationContext {
            var backingOff: [(Connection.ID, EventLoop)] = []
            var starting: [(Connection.ID, EventLoop)] = []
            var close: [Connection] = []
        }

        // MARK: Connection creation

        mutating func createNewConnection(on eventLoop: EventLoop) -> Connection.ID {
            precondition(self.canGrow)
            let connection = HTTP1ConnectionState(
                connectionID: self.generator.next(),
                eventLoop: eventLoop,
                maximumUses: self.maximumConnectionUses
            )
            self.connections.insert(connection, at: self.overflowIndex)
            self.overflowIndex = self.connections.index(after: self.overflowIndex)
            return connection.connectionID
        }

        mutating func createNewOverflowConnection(on eventLoop: EventLoop) -> Connection.ID {
            let connection = HTTP1ConnectionState(
                connectionID: self.generator.next(),
                eventLoop: eventLoop,
                maximumUses: self.maximumConnectionUses
            )
            self.connections.append(connection)
            return connection.connectionID
        }

        /// A new HTTP/1.1 connection was established.
        ///
        /// This will put the connection into the idle state.
        ///
        /// - Parameter connection: The new established connection.
        /// - Returns: An index and an IdleConnectionContext to determine the next action for the now idle connection.
        ///            Call ``leaseConnection(at:)`` or ``closeConnection(at:)`` with the supplied index after
        ///            this.
        mutating func newHTTP1ConnectionEstablished(_ connection: Connection) -> (Int, IdleConnectionContext) {
            guard let index = self.connections.firstIndex(where: { $0.connectionID == connection.id }) else {
                preconditionFailure("There is a new connection that we didn't request!")
            }
            precondition(
                connection.eventLoop === self.connections[index].eventLoop,
                "Expected the new connection to be on EL"
            )
            self.connections[index].connected(connection)
            let context = self.generateIdleConnectionContextForConnection(at: index)
            return (index, context)
        }

        /// Move the HTTP1ConnectionState to backingOff.
        ///
        /// - Parameter connectionID: The connectionID of the failed connection attempt
        /// - Returns: The eventLoop on which to schedule the backoff timer
        mutating func backoffNextConnectionAttempt(_ connectionID: Connection.ID) -> EventLoop {
            guard let index = self.connections.firstIndex(where: { $0.connectionID == connectionID }) else {
                preconditionFailure("We tried to create a new connection that we know nothing about?")
            }

            self.connections[index].failedToConnect()
            return self.connections[index].eventLoop
        }

        // MARK: Leasing and releasing

        /// Lease a connection on the preferred EventLoop
        ///
        /// If no connection is available on the preferred EventLoop, a connection on
        /// another eventLoop might be returned, if one is available.
        ///
        /// - Parameter eventLoop: The preferred EventLoop for the request
        /// - Returns: A connection to execute a request on.
        mutating func leaseConnection(onPreferred eventLoop: EventLoop) -> Connection? {
            guard let index = self.findIdleConnection(onPreferred: eventLoop) else {
                return nil
            }

            return self.connections[index].lease()
        }

        /// Lease a connection on the required EventLoop
        ///
        /// If no connection is available on the required EventLoop nil is returned.
        ///
        /// - Parameter eventLoop: The required EventLoop for the request
        /// - Returns: A connection to execute a request on.
        mutating func leaseConnection(onRequired eventLoop: EventLoop) -> Connection? {
            guard let index = self.findIdleConnection(onRequired: eventLoop) else {
                return nil
            }

            return self.connections[index].lease()
        }

        mutating func leaseConnection(at index: Int) -> Connection {
            self.connections[index].lease()
        }

        func parkConnection(at index: Int) -> (Connection.ID, EventLoop) {
            precondition(self.connections[index].isIdle)
            return (self.connections[index].connectionID, self.connections[index].eventLoop)
        }

        /// A new HTTP/1.1 connection was released.
        ///
        /// This will put the position into the idle state.
        ///
        /// - Parameter connectionID: The released connection's id.
        /// - Returns: An index and an IdleConnectionContext to determine the next action for the now idle connection.
        ///            Call ``leaseConnection(at:)`` or ``closeConnection(at:)`` with the supplied index after
        ///            this. If you want to park the connection no further call is required.
        mutating func releaseConnection(_ connectionID: Connection.ID) -> (Int, IdleConnectionContext) {
            guard let index = self.connections.firstIndex(where: { $0.connectionID == connectionID }) else {
                preconditionFailure("A connection that we don't know was released? Something is very wrong...")
            }

            self.connections[index].release()
            let context = self.generateIdleConnectionContextForConnection(at: index)
            return (index, context)
        }

        // MARK: Connection close/removal

        /// Closes the connection at the given index. This will also remove the connection right away.
        mutating func closeConnection(at index: Int) -> Connection {
            if index < self.overflowIndex {
                self.overflowIndex = self.connections.index(before: self.overflowIndex)
            }
            var connectionState = self.connections.remove(at: index)
            return connectionState.close()
        }

        mutating func removeConnection(at index: Int) {
            precondition(self.connections[index].isClosed)
            if index < self.overflowIndex {
                self.overflowIndex = self.connections.index(before: self.overflowIndex)
            }
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

        mutating func replaceConnection(at index: Int) -> (Connection.ID, EventLoop) {
            precondition(self.connections[index].isClosed)
            let newConnection = HTTP1ConnectionState(
                connectionID: self.generator.next(),
                eventLoop: self.connections[index].eventLoop,
                maximumUses: self.maximumConnectionUses
            )

            self.connections[index] = newConnection
            return (newConnection.connectionID, newConnection.eventLoop)
        }

        // MARK: Connection failure

        /// Fail a connection. Call this method, if a connection suddenly closed, did not startup correctly,
        /// or the backoff time is done.
        ///
        /// This will put the position into the closed state.
        ///
        /// - Parameter connectionID: The failed connection's id.
        /// - Returns: An optional index and an IdleConnectionContext to determine the next action for the closed connection.
        ///            You must call ``removeConnection(at:)`` or ``replaceConnection(at:)`` with the
        ///            supplied index after this. If nil is returned the connection was closed by the state machine and was
        ///            therefore already removed.
        mutating func failConnection(_ connectionID: Connection.ID) -> (Int, FailedConnectionContext)? {
            guard let index = self.connections.firstIndex(where: { $0.connectionID == connectionID }) else {
                return nil
            }

            let use: ConnectionUse
            switch self.connections[index].fail() {
            case .removeConnection:
                let eventLoop = self.connections[index].eventLoop
                let starting: Int
                if index < self.overflowIndex {
                    use = .generalPurpose
                    starting = self.startingGeneralPurposeConnections
                } else {
                    use = .eventLoop(eventLoop)
                    starting = self.startingEventLoopConnections(on: eventLoop)
                }

                let context = FailedConnectionContext(
                    eventLoop: eventLoop,
                    use: use,
                    connectionsStartingForUseCase: starting
                )
                return (index, context)

            case .none:
                return nil
            }
        }

        // MARK: Migration

        mutating func migrateToHTTP2() -> HTTP1ToHTTP2MigrationContext {
            var migrationContext = HTTP1ToHTTP2MigrationContext()
            let initialOverflowIndex = self.overflowIndex

            self.connections = self.connections.enumerated().compactMap { index, connectionState in
                switch connectionState.migrateToHTTP2(&migrationContext) {
                case .removeConnection:
                    // If the connection has an index smaller than the previous overflow index,
                    // we deal with a general purpose connection.
                    // For this reason we need to decrement the overflow index.
                    if index < initialOverflowIndex {
                        self.overflowIndex = self.connections.index(before: self.overflowIndex)
                    }
                    return nil

                case .keepConnection:
                    return connectionState
                }
            }
            return migrationContext
        }

        /// We only handle starting and backing off connection here.
        /// All already running connections must be handled by the enclosing state machine.
        /// - Parameters:
        ///   - starting: starting HTTP connections from previous state machine
        ///   - backingOff: backing off HTTP connections from previous state machine
        mutating func migrateFromHTTP2(
            starting: [(Connection.ID, EventLoop)],
            backingOff: [(Connection.ID, EventLoop)]
        ) {
            for (connectionID, eventLoop) in starting {
                let newConnection = HTTP1ConnectionState(
                    connectionID: connectionID,
                    eventLoop: eventLoop,
                    maximumUses: self.maximumConnectionUses
                )

                self.connections.insert(newConnection, at: self.overflowIndex)
                /// If we can grow, we mark the connection as a general purpose connection.
                /// Otherwise, it will be an overflow connection which is only used once for requests with a required event loop
                if self.canGrow {
                    self.overflowIndex = self.connections.index(after: self.overflowIndex)
                }
            }

            for (connectionID, eventLoop) in backingOff {
                var backingOffConnection = HTTP1ConnectionState(
                    connectionID: connectionID,
                    eventLoop: eventLoop,
                    maximumUses: self.maximumConnectionUses
                )
                // TODO: Maybe we want to add a static init for backing off connections to HTTP1ConnectionState
                backingOffConnection.failedToConnect()

                self.connections.insert(backingOffConnection, at: self.overflowIndex)
                /// If we can grow, we mark the connection as a general purpose connection.
                /// Otherwise, it will be an overflow connection which is only used once for requests with a required event loop
                if self.canGrow {
                    self.overflowIndex = self.connections.index(after: self.overflowIndex)
                }
            }
        }

        /// We will create new connections for each `requiredEventLoopOfPendingRequests`
        /// In addition, we also create more general purpose connections if we do not have enough to execute
        /// all requests on the given `preferredEventLoopsOfPendingGeneralPurposeRequests`
        /// until we reach `maximumConcurrentConnections`
        /// - Parameters:
        ///   - requiredEventLoopsForPendingRequests:
        ///   event loops for which we have requests with a required event loop.
        ///   Duplicates are not allowed.
        ///   - generalPurposeRequestCountPerPreferredEventLoop:
        ///   request count with no required event loop,
        ///   grouped by preferred event loop and ordered descending by number of requests
        /// - Returns: new connections that must be created
        mutating func createConnectionsAfterMigrationIfNeeded(
            requiredEventLoopOfPendingRequests: [(EventLoop, Int)],
            generalPurposeRequestCountGroupedByPreferredEventLoop: [(EventLoop, Int)]
        ) -> [(Connection.ID, EventLoop)] {
            // create new connections for requests with a required event loop

            // we may already start connections for those requests and do not want to start too many
            let startingRequiredEventLoopConnectionCount = Dictionary(
                self.connections[self.overflowIndex..<self.connections.endIndex].lazy.map {
                    ($0.eventLoop.id, 1)
                },
                uniquingKeysWith: +
            )
            var connectionToCreate =
                requiredEventLoopOfPendingRequests
                .flatMap { eventLoop, requestCount -> [(Connection.ID, EventLoop)] in
                    // We need a connection for each queued request with a required event loop.
                    // Therefore, we look how many request we have queued for a given `eventLoop` and
                    // how many connections we are already starting on the given `eventLoop`.
                    // If we have not enough, we will create additional connections to have at least
                    // on connection per request.
                    let connectionsToStart =
                        requestCount - startingRequiredEventLoopConnectionCount[eventLoop.id, default: 0]
                    return stride(from: 0, to: connectionsToStart, by: 1).lazy.map { _ in
                        (self.createNewOverflowConnection(on: eventLoop), eventLoop)
                    }
                }

            // create new connections for requests without a required event loop

            // TODO: improve algorithm to create connections uniformly across all preferred event loops
            // while paying attention to the number of queued request per event loop
            // Currently we start by creating new connections on the event loop with the most queued
            // requests. If we have created enough connections to cover all requests for the first
            // event loop we will continue with the event loop with the second most queued requests
            // and so on and so forth. The `generalPurposeRequestCountGroupedByPreferredEventLoop`
            // array is already ordered so we can just iterate over it without sorting by request count.
            let newGeneralPurposeConnections: [(Connection.ID, EventLoop)] =
                generalPurposeRequestCountGroupedByPreferredEventLoop
                // we do not want to allocated intermediate arrays.
                .lazy
                // we flatten the grouped list of event loops by lazily repeating the event loop
                // for each request.
                // As a result we get one event loop per request (`[EventLoop]`).
                .flatMap { eventLoop, requestCount in
                    repeatElement(eventLoop, count: requestCount)
                }
                // we may already start connections and do not want to start too many
                .dropLast(self.startingGeneralPurposeConnections)
                // we need to respect the used defined `maximumConcurrentConnections`
                .prefix(self.maximumAdditionalGeneralPurposeConnections)
                // we now create a connection for each remaining event loop
                .map { eventLoop in
                    (self.createNewConnection(on: eventLoop), eventLoop)
                }

            connectionToCreate.append(contentsOf: newGeneralPurposeConnections)

            return connectionToCreate
        }

        // MARK: Shutdown

        mutating func shutdown() -> CleanupContext {
            var cleanupContext = CleanupContext()
            let initialOverflowIndex = self.overflowIndex

            self.connections = self.connections.enumerated().compactMap { index, connectionState in
                switch connectionState.cleanup(&cleanupContext) {
                case .removeConnection:
                    // If the connection has an index smaller than the previous overflow index,
                    // we deal with a general purpose connection.
                    // For this reason we need to decrement the overflow index.
                    if index < initialOverflowIndex {
                        self.overflowIndex = self.connections.index(before: self.overflowIndex)
                    }
                    return nil

                case .keepConnection:
                    return connectionState
                }
            }

            return cleanupContext
        }

        // MARK: - Private functions -

        private func generateIdleConnectionContextForConnection(at index: Int) -> IdleConnectionContext {
            precondition(self.connections[index].isIdle)
            let eventLoop = self.connections[index].eventLoop
            let use: ConnectionUse
            if index < self.overflowIndex {
                use = .generalPurpose
            } else {
                use = .eventLoop(eventLoop)
            }
            let hasNoRemainingUses = self.connections[index].idleAndNoRemainingUses
            return IdleConnectionContext(eventLoop: eventLoop, use: use, shouldBeClosed: hasNoRemainingUses)
        }

        private func findIdleConnection(onPreferred preferredEL: EventLoop) -> Int? {
            var eventLoopMatch: (Int, NIODeadline)?
            var goodMatch: (Int, NIODeadline)?

            // To find an appropriate connection we iterate all existing connections.
            // While we do this we try to find the best fitting connection for our request.
            //
            // A perfect match, runs on the same eventLoop and has been idle the shortest amount
            // of time (returned the most recently).
            //
            // An okay match is not on the same eventLoop, and has been idle for the shortest
            // time.
            for (index, conn) in self.connections.enumerated() {
                guard let connReturn = conn.idleSince else {
                    continue
                }

                if conn.eventLoop === preferredEL {
                    switch eventLoopMatch {
                    case .none:
                        eventLoopMatch = (index, connReturn)
                    case .some((_, let existingMatchReturn)) where connReturn > existingMatchReturn:
                        eventLoopMatch = (index, connReturn)
                    default:
                        break
                    }
                } else {
                    switch goodMatch {
                    case .none:
                        goodMatch = (index, connReturn)
                    case .some((_, let existingMatchReturn)):
                        // We don't require a specific eventLoop. For this reason we want to pick a
                        // matching eventLoop that has been idle the shortest.
                        if connReturn > existingMatchReturn {
                            goodMatch = (index, connReturn)
                        }
                    }
                }
            }

            if let (index, _) = eventLoopMatch {
                return index
            }

            if let (index, _) = goodMatch {
                return index
            }

            return nil
        }

        func findIdleConnection(onRequired requiredEL: EventLoop) -> Int? {
            var match: (Int, NIODeadline)?

            // To find an appropriate connection we iterate all existing connections.
            // While we do this we try to find the best fitting connection for our request.
            //
            // A match, runs on the same eventLoop and has been idle the shortest amount of time.
            for (index, conn) in self.connections.enumerated() {
                // 1. Ensure we are on the correct EL.
                guard conn.eventLoop === requiredEL else {
                    continue
                }

                // 2. Ensure the connection is idle
                guard let connReturn = conn.idleSince else {
                    continue
                }

                switch match {
                case .none:
                    match = (index, connReturn)
                case .some((_, let existingMatchReturn)) where connReturn > existingMatchReturn:
                    // the currently iterated eventLoop has been idle for a shorter amount than
                    // the current best match.
                    match = (index, connReturn)
                default:
                    // the currently iterated eventLoop has been idle for a longer amount than
                    // the current best match. We continue the iteration.
                    continue
                }
            }

            if let (index, _) = match {
                return index
            }

            return nil
        }

        struct Stats {
            var idle: Int = 0
            var leased: Int = 0
            var connecting: Int = 0
            var backingOff: Int = 0

            var nonLeased: Int {
                self.idle + self.connecting + self.backingOff
            }
        }
    }
}
