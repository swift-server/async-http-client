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
    struct HTTP1ConnectionState {
        enum State {
            case starting(Waiter?)
            case active(Connection, isAvailable: Bool, lastReturn: NIODeadline)
            case failed
            case closed
        }

        private(set) var state: State
        let eventLoop: EventLoop
        let connectionID: Connection.ID

        init(connectionID: Connection.ID, eventLoop: EventLoop, waiter: Waiter) {
            self.connectionID = connectionID
            self.eventLoop = eventLoop
            self.state = .starting(waiter)
        }

        var isStarting: Bool {
            switch self.state {
            case .starting:
                return true
            case .failed, .closed, .active:
                return false
            }
        }

        var isAvailable: Bool {
            switch self.state {
            case .active(_, let isAvailable, _):
                return isAvailable
            case .starting, .failed, .closed:
                return false
            }
        }

        var isLeased: Bool {
            switch self.state {
            case .active(_, let isAvailable, _):
                return !isAvailable
            case .starting, .failed, .closed:
                return false
            }
        }

        var availableAndLastReturn: NIODeadline? {
            switch self.state {
            case .active(_, true, let lastReturn):
                return lastReturn
            case .active(_, false, _):
                return nil
            case .starting, .failed, .closed:
                return nil
            }
        }

        mutating func started(_ connection: Connection) -> Waiter? {
            guard case .starting(let waiter) = self.state else {
                preconditionFailure("Invalid state: \(self.state)")
            }
            self.state = .active(connection, isAvailable: true, lastReturn: .now())
            return waiter
        }

        mutating func failed() -> Waiter? {
            guard case .starting(let waiter) = self.state else {
                preconditionFailure("Invalid state")
            }
            self.state = .failed
            return waiter
        }

        @discardableResult
        mutating func lease() -> Connection {
            guard case .active(let conn, isAvailable: true, let lastReturn) = self.state else {
                preconditionFailure("Invalid state")
            }
            self.state = .active(conn, isAvailable: false, lastReturn: lastReturn)
            return conn
        }

        mutating func release() {
            guard case .active(let conn, isAvailable: false, _) = self.state else {
                preconditionFailure("Invalid state")
            }
            self.state = .active(conn, isAvailable: true, lastReturn: .now())
        }

        mutating func close() -> Connection {
            guard case .active(let conn, isAvailable: true, _) = self.state else {
                preconditionFailure("Invalid state")
            }
            self.state = .closed
            return conn
        }

        mutating func cancel() -> Connection {
            guard case .active(let conn, isAvailable: false, _) = self.state else {
                preconditionFailure("Invalid state")
            }
            return conn
        }

        mutating func removeStartWaiter() -> Waiter? {
            guard case .starting(let waiter) = self.state else {
                preconditionFailure("Invalid state")
            }
            self.state = .starting(nil)
            return waiter
        }
    }

    struct HTTP1StateMachine {
        enum State: Equatable {
            case running
            case shuttingDown(unclean: Bool)
            case shutDown
        }

        typealias Action = HTTPConnectionPool.StateMachine.Action

        let maximumConcurrentConnections: Int
        let idGenerator: Connection.ID.Generator
        private(set) var connections: [HTTP1ConnectionState] {
            didSet {
                assert(self.connections.count <= self.maximumConcurrentConnections)
            }
        }

        private(set) var waiters: CircularBuffer<Waiter>
        private(set) var state: State = .running

        init(idGenerator: Connection.ID.Generator, maximumConcurrentConnections: Int) {
            self.idGenerator = idGenerator
            self.maximumConcurrentConnections = maximumConcurrentConnections
            self.connections = []
            self.connections.reserveCapacity(self.maximumConcurrentConnections)
            self.waiters = []
            self.waiters.reserveCapacity(32)
        }

        mutating func executeTask(_ task: HTTPRequestTask, onPreffered prefferedEL: EventLoop, required: Bool) -> Action {
            var eventLoopMatch: (Int, NIODeadline)?
            var goodMatch: (Int, NIODeadline)?

            switch self.state {
            case .running:
                break
            case .shuttingDown, .shutDown:
                // it is fairly unlikely that this condition is met, since the ConnectionPoolManager
                // also fails new requests immidiatly, if it is shutting down. However there might
                // be race conditions in which a request passes through a running connection pool
                // manager, but hits a connection pool that is already shutting down.
                //
                // (Order in one lock does not guarantee order in the next lock!)
                return .init(.failTask(task, HTTPClientError.alreadyShutdown, cancelWaiter: nil), .none)
            }

            // queuing fast path...
            // If something is already queued, we can just directly add it to the queue. This saves
            // a number of comparisons.
            if !self.waiters.isEmpty {
                let waiter = Waiter(task: task, eventLoopRequirement: required ? prefferedEL : nil)
                self.waiters.append(waiter)
                return .init(.scheduleWaiterTimeout(waiter.id, task, on: prefferedEL), .none)
            }

            // To find an appropiate connection we iterate all existing connections.
            // While we do this we try to find the best fitting connection for our request.
            //
            // A perfect match, runs on the same eventLoop and has been idle the shortest amount
            // of time.
            //
            // An okay match is not on the same eventLoop, and has been idle for the shortest
            // time (if the eventLoop is not enforced). If the eventLoop is enforced we take the
            // connection that has been idle the longest.
            for (index, conn) in self.connections.enumerated() {
                guard let connReturn = conn.availableAndLastReturn else {
                    continue
                }

                if conn.eventLoop === prefferedEL {
                    switch eventLoopMatch {
                    case .none:
                        eventLoopMatch = (index, connReturn)
                    case .some((_, let existingMatchReturn)) where connReturn > existingMatchReturn:
                        eventLoopMatch = (index, connReturn)
                    default:
                        break
                    }
                } else {
                    switch (required, goodMatch) {
                    case (true, .none) where self.connections.count < self.maximumConcurrentConnections:
                        // If we require a specific eventLoop, and we have space for new connections,
                        // we should create a new connection if, we don't find a perfect match.
                        // We only continue the search to maybe find a perfect match.
                        break
                    case (true, .none):
                        // We require a specific eventLoop, but there is no room for a new one.
                        goodMatch = (index, connReturn)
                    case (true, .some((_, let existingMatchReturn))):
                        // We require a specific eventLoop, but there is no room for a new one.
                        if connReturn < existingMatchReturn {
                            // The current candidate has been idle for longer than our current
                            // replacement candidate. For this reason swap
                            goodMatch = (index, connReturn)
                        }
                    case (false, .none):
                        goodMatch = (index, connReturn)
                    case (false, .some((_, let existingMatchReturn))):
                        // We don't require a specific eventLoop. For this reason we want to pick a
                        // matching eventLoop that has been idle the shortest.
                        if connReturn > existingMatchReturn {
                            goodMatch = (index, connReturn)
                        }
                    }
                }
            }

            // if we found an eventLoopMatch, we can execute the task right away
            if let (index, _) = eventLoopMatch {
                assert(self.waiters.isEmpty, "If a connection is available, why are there any waiters")
                var connectionState = self.connections[index]
                let connection = connectionState.lease()
                self.connections[index] = connectionState
                return .init(
                    .executeTask(task, connection, cancelWaiter: nil),
                    .cancelTimeoutTimer(connectionState.connectionID)
                )
            }

            // if we found a good match, let's use this
            if let (index, _) = goodMatch {
                assert(self.waiters.isEmpty, "If a connection is available, why are there any waiters")
                if !required {
                    var connectionState = self.connections[index]
                    let connectionID = connectionState.connectionID
                    let connection = connectionState.lease()
                    self.connections[index] = connectionState
                    return .init(
                        .executeTask(task, connection, cancelWaiter: nil),
                        .cancelTimeoutTimer(connectionID)
                    )
                } else {
                    assert(self.connections.count - self.maximumConcurrentConnections == 0)
                    var oldConnectionState = self.connections[index]
                    let newConnectionID = self.idGenerator.next()
                    let newWaiter = Waiter(task: task, eventLoopRequirement: prefferedEL)
                    self.connections[index] = .init(connectionID: newConnectionID, eventLoop: prefferedEL, waiter: newWaiter)
                    return .init(
                        .scheduleWaiterTimeout(newWaiter.id, task, on: prefferedEL),
                        .replaceConnection(oldConnectionState.close(), with: newConnectionID, on: prefferedEL)
                    )
                }
            }

            // we didn't find any match at all... Let's create a new connection, if there is room
            // left
            if self.connections.count < self.maximumConcurrentConnections {
                let newConnectionID = self.idGenerator.next()
                let newWaiter = Waiter(task: task, eventLoopRequirement: prefferedEL)
                self.connections.append(.init(connectionID: newConnectionID, eventLoop: prefferedEL, waiter: newWaiter))
                return .init(
                    .scheduleWaiterTimeout(newWaiter.id, task, on: prefferedEL),
                    .createConnection(newConnectionID, on: prefferedEL)
                )
            }

            // all connections are busy, and there is no more room to create further connections
            let waiter = Waiter(task: task, eventLoopRequirement: required ? prefferedEL : nil)
            self.waiters.append(waiter)
            return .init(
                .scheduleWaiterTimeout(waiter.id, task, on: prefferedEL),
                .none
            )
        }

        mutating func newHTTP1ConnectionCreated(_ connection: Connection) -> Action {
            guard let index = self.connections.firstIndex(where: { $0.connectionID == connection.id }) else {
                preconditionFailure("There is a new connection, that we didn't request!")
            }

            var connectionState = self.connections[index]

            switch self.state {
            case .running:
                let maybeWaiter = connectionState.started(connection)

                // 1. check if we have an associated waiter with this connection
                if let waiter = maybeWaiter {
                    connectionState.lease()
                    self.connections[index] = connectionState
                    return .init(
                        .executeTask(waiter.task, connection, cancelWaiter: waiter.id),
                        .none
                    )
                }

                // 2. if we don't have an associated waiter for this connection, pick the first one
                //    from the queue
                if let nextWaiter = self.waiters.popFirst() {
                    // ensure the request can be run on this eventLoop
                    guard nextWaiter.canBeRun(on: connectionState.eventLoop) else {
                        let eventLoop = nextWaiter.eventLoopRequirement!
                        let newConnection = HTTP1ConnectionState(
                            connectionID: self.idGenerator.next(),
                            eventLoop: eventLoop,
                            waiter: nextWaiter
                        )
                        self.connections[index] = newConnection
                        return .init(
                            .none,
                            .replaceConnection(connectionState.close(), with: newConnection.connectionID, on: eventLoop)
                        )
                    }

                    let connection = connectionState.lease()
                    self.connections[index] = connectionState
                    return .init(
                        .executeTask(nextWaiter.task, connection, cancelWaiter: nextWaiter.id),
                        .none
                    )
                }

                self.connections[index] = connectionState
                return .init(.none, .scheduleTimeoutTimer(connectionState.connectionID))

            case .shuttingDown(unclean: let unclean):
                // if we are in shutdown, we want to get rid off this connection asap.
                guard connectionState.started(connection) == nil else {
                    preconditionFailure("Expected to remove the waiter when shutdown is issued")
                }

                self.connections.remove(at: index)
                let isShutdown: StateMachine.ConnectionAction.IsShutdown
                if self.connections.isEmpty {
                    self.state = .shutDown
                    isShutdown = .yes(unclean: unclean)
                } else {
                    isShutdown = .no
                }

                return .init(.none, .closeConnection(connectionState.close(), isShutdown: isShutdown))

            case .shutDown:
                preconditionFailure("The pool is already shutdown all connections must already been torn down")
            }
        }

        mutating func failedToCreateNewConnection(_ error: Error, connectionID: Connection.ID) -> Action {
            guard let index = self.connections.firstIndex(where: { $0.connectionID == connectionID }) else {
                preconditionFailure("We tried to create a new connection, that we know nothing about?")
            }

            var connectionState = self.connections[index]

            switch self.state {
            case .running:
                var taskAction: StateMachine.TaskAction = .none
                if let failedWaiter = connectionState.failed() {
                    taskAction = .failTask(failedWaiter.task, error, cancelWaiter: failedWaiter.id)
                }

                if let nextWaiter = self.waiters.popFirst() {
                    assert(self.connections.count == self.maximumConcurrentConnections,
                           "Why do we have waiters, if we could open more connections?")

                    let eventLoop = nextWaiter.eventLoopRequirement ?? connectionState.eventLoop
                    let newConnectionState = HTTP1ConnectionState(
                        connectionID: self.idGenerator.next(),
                        eventLoop: eventLoop,
                        waiter: nextWaiter
                    )
                    self.connections[index] = newConnectionState
                    return .init(taskAction, .createConnection(newConnectionState.connectionID, on: eventLoop))
                }

                self.connections.remove(at: index)
                return .init(taskAction, .none)

            case .shuttingDown(unclean: let unclean):
                guard connectionState.failed() == nil else {
                    preconditionFailure("Expected to remove the waiter when shutdown is issued")
                }

                self.connections.remove(at: index)
                let isShutdown: StateMachine.ConnectionAction.IsShutdown
                if self.connections.isEmpty {
                    self.state = .shutDown
                    isShutdown = .yes(unclean: unclean)
                } else {
                    isShutdown = .no
                }

                // the cleanupAction here is pretty lazy :)
                return .init(.none, .cleanupConnection(close: [], cancel: [], isShutdown: isShutdown))

            case .shutDown:
                preconditionFailure("The pool is already shutdown all connections must already been torn down")
            }
        }

        mutating func connectionTimeout(_ connectionID: Connection.ID) -> Action {
            guard let index = self.connections.firstIndex(where: { $0.connectionID == connectionID }) else {
                // because of a race this connection (connection close runs against trigger of timeout)
                // was already removed from the state machine.
                return .init(.none, .none)
            }

            assert(self.state == .running, "If we are shutting down, we must not have any idle connections")

            var connectionState = self.connections[index]
            guard connectionState.isAvailable else {
                // connection is not available anymore, we may have just leased it for a task
                return .init(.none, .none)
            }

            assert(self.waiters.isEmpty, "We have an idle connection, that times out, but waiters? Something is very wrong!")

            self.connections.remove(at: index)
            return .init(.none, .closeConnection(connectionState.close(), isShutdown: .no))
        }

        mutating func http1ConnectionReleased(_ connectionID: Connection.ID) -> Action {
            guard let index = self.connections.firstIndex(where: { $0.connectionID == connectionID }) else {
                preconditionFailure("A connection that we don't know was released? Something is very wrong...")
            }

            var connectionState = self.connections[index]
            connectionState.release()

            switch self.state {
            case .running:
                guard let nextWaiter = self.waiters.popFirst() else {
                    // there is no more work todo immidiatly
                    self.connections[index] = connectionState
                    return .init(.none, .scheduleTimeoutTimer(connectionID))
                }

                assert(self.connections.count == self.maximumConcurrentConnections,
                       "Why do we have waiters, if we could open more connections?")

                guard nextWaiter.canBeRun(on: connectionState.eventLoop) else {
                    let eventLoop = nextWaiter.eventLoopRequirement!
                    let newConnection = HTTP1ConnectionState(
                        connectionID: self.idGenerator.next(),
                        eventLoop: eventLoop,
                        waiter: nextWaiter
                    )
                    self.connections[index] = newConnection
                    return .init(.none, .replaceConnection(connectionState.close(), with: newConnection.connectionID, on: eventLoop))
                }

                let connection = connectionState.lease()
                self.connections[index] = connectionState
                return .init(
                    .executeTask(nextWaiter.task, connection, cancelWaiter: nextWaiter.id),
                    .none
                )

            case .shuttingDown(unclean: let unclean):
                assert(self.waiters.isEmpty, "Expected to have already cancelled all waiters")

                self.connections.remove(at: index)
                let isShutdown: StateMachine.ConnectionAction.IsShutdown
                if self.connections.isEmpty {
                    self.state = .shutDown
                    isShutdown = .yes(unclean: unclean)
                } else {
                    isShutdown = .no
                }

                return .init(.none, .closeConnection(connectionState.close(), isShutdown: isShutdown))

            case .shutDown:
                preconditionFailure("The pool is already shutdown all connections must already been torn down")
            }
        }

        /// A connection is done processing a task
        mutating func http2ConnectionStreamClosed(_ connectionID: Connection.ID, availableStreams: Int) -> Action {
            #warning("TODO: Must be implemented to allow transitions from http/2 back to http/1.1")
            preconditionFailure("Not implemented for now")
        }

        /// A connection has been closed
        mutating func connectionClosed(_ connectionID: Connection.ID) -> Action {
            guard let index = self.connections.firstIndex(where: { $0.connectionID == connectionID }) else {
                // because of a race this connection (connection close runs against replace)
                // was already removed from the state machine.
                return .init(.none, .none)
            }

            switch self.state {
            case .running:
                guard let nextWaiter = self.waiters.popFirst() else {
                    self.connections.remove(at: index)
                    return .init(.none, .none)
                }

                let closedConnection = self.connections[index]
                assert(self.connections.count == self.maximumConcurrentConnections,
                       "Why do we have waiters, if we could open more connections?")

                let eventLoop = nextWaiter.eventLoopRequirement ?? closedConnection.eventLoop
                let newConnection = HTTP1ConnectionState(
                    connectionID: self.idGenerator.next(),
                    eventLoop: eventLoop,
                    waiter: nextWaiter
                )
                self.connections[index] = newConnection
                return .init(.none, .createConnection(newConnection.connectionID, on: eventLoop))

            case .shuttingDown(unclean: let unclean):
                assert(self.waiters.isEmpty, "Expected to have already cancelled all waiters")

                self.connections.remove(at: index)
                if self.connections.isEmpty {
                    self.state = .shutDown
                    return .init(.none, .cleanupConnection(close: [], cancel: [], isShutdown: .yes(unclean: unclean)))
                } else {
                    return .init(.none, .none)
                }

            case .shutDown:
                preconditionFailure("The pool is already shutdown all connections must already been torn down")
            }
        }

        mutating func timeoutWaiter(_ waitID: Waiter.ID) -> Action {
            // 1. check waiters in starting connections
            let connectionIndex = self.connections.firstIndex(where: {
                switch $0.state {
                case .starting(let waiter):
                    return waiter?.id == waitID
                case .active, .failed, .closed:
                    return false
                }
            })

            if let connectionIndex = connectionIndex {
                var connectionState = self.connections[connectionIndex]
                var taskAction: StateMachine.TaskAction = .none
                if let waiter = connectionState.removeStartWaiter() {
                    taskAction = .failTask(waiter.task, HTTPClientError.connectTimeout, cancelWaiter: nil)
                }
                self.connections[connectionIndex] = connectionState

                return .init(taskAction, .none)
            }

            // 2. check waiters in queue
            let waiterIndex = self.waiters.firstIndex(where: { $0.id == waitID })
            if let waiterIndex = waiterIndex {
                // TBD: This is slow. Do we maybe want something more sophisticated here?
                let waiter = self.waiters.remove(at: waiterIndex)
                return .init(
                    .failTask(waiter.task, HTTPClientError.getConnectionFromPoolTimeout, cancelWaiter: nil),
                    .none
                )
            }

            // 3. we reach this point, because the waiter may already have been scheduled. The waiter
            //    was not cancelled because of a race condition
            return .init(.none, .none)
        }

        mutating func cancelWaiter(_ waitID: Waiter.ID) -> Action {
            // 1. check waiters in starting connections
            let connectionIndex = self.connections.firstIndex(where: {
                switch $0.state {
                case .starting(let waiter):
                    return waiter?.id == waitID
                case .active, .failed, .closed:
                    return false
                }
            })

            if let connectionIndex = connectionIndex {
                var connectionState = self.connections[connectionIndex]
                var taskAction: StateMachine.TaskAction = .none
                if let waiter = connectionState.removeStartWaiter() {
                    taskAction = .failTask(waiter.task, HTTPClientError.cancelled, cancelWaiter: waiter.id)
                }
                self.connections[connectionIndex] = connectionState

                return .init(taskAction, .none)
            }

            // 2. check waiters in queue
            let waiterIndex = self.waiters.firstIndex(where: { $0.id == waitID })
            if let waiterIndex = waiterIndex {
                // TBD: This is potentially slow. Do we maybe want something more sophisticated here?
                let waiter = self.waiters.remove(at: waiterIndex)
                return .init(
                    .failTask(waiter.task, HTTPClientError.cancelled, cancelWaiter: waitID),
                    .none
                )
            }

            // 3. we reach this point, because the waiter may already have been forwarded to an
            //    idle connection. The connection will need to handle the cancellation in that case.
            return .init(.none, .none)
        }

        mutating func shutdown() -> Action {
            precondition(self.state == .running, "Shutdown must only be called once")

            var taskAction: StateMachine.TaskAction = .none

            // If we have remaining waiters, we should fail all of them with a cancelled error
            var tasks = self.waiters.map { ($0.task, $0.id) }
            self.waiters.removeAll()

            var close = [Connection]()
            var cancel = [Connection]()

            self.connections = self.connections.compactMap { connectionState -> HTTPConnectionPool.HTTP1ConnectionState? in
                var connectionState = connectionState

                if connectionState.isStarting {
                    // starting connections cant be cancelled so far... we will need to wait until
                    // the connection starts up or fails.

                    if let waiter = connectionState.removeStartWaiter() {
                        tasks.append((waiter.task, waiter.id))
                    }

                    return connectionState
                } else if connectionState.isAvailable {
                    close.append(connectionState.close())
                    return nil
                } else if connectionState.isLeased {
                    cancel.append(connectionState.cancel())
                    return connectionState
                }

                preconditionFailure("Must not be reached. Any of the above conditions should be true")
            }

            // If there aren't any more connections, everything is shutdown
            let isShutdown: StateMachine.ConnectionAction.IsShutdown
            let unclean = !(cancel.isEmpty && tasks.isEmpty)
            if self.connections.isEmpty {
                self.state = .shutDown
                isShutdown = .yes(unclean: unclean)
            } else {
                self.state = .shuttingDown(unclean: unclean)
                isShutdown = .no
            }

            if !tasks.isEmpty {
                taskAction = .failTasks(tasks, HTTPClientError.cancelled)
            }

            return .init(taskAction, .cleanupConnection(close: close, cancel: cancel, isShutdown: isShutdown))
        }
    }
}

extension HTTPConnectionPool.HTTP1StateMachine: CustomStringConvertible {
    var description: String {
        var starting = 0
        var leased = 0
        var parked = 0

        for connectionState in self.connections {
            if connectionState.isStarting {
                starting += 1
            } else if connectionState.isLeased {
                leased += 1
            } else if connectionState.isAvailable {
                parked += 1
            }
        }

        let waiters = self.waiters.count

        return "connections: [starting: \(starting) | leased: \(leased) | parked: \(parked)], waiters: \(waiters)"
    }
}
