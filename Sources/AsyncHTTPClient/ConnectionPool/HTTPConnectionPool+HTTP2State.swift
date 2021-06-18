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
@_implementationOnly import NIOHTTP2

extension HTTPConnectionPool {
    struct HTTP2ConnectionState {
        private enum State {
            case starting
            case active(Connection, maxStreams: Int, usedStreams: Int, lastIdle: NIODeadline)
            case draining(Connection, maxStreams: Int, usedStreams: Int)
            case closed
        }

        var isActive: Bool {
            switch self.state {
            case .starting:
                return false
            case .active:
                return true
            case .draining:
                return false
            case .closed:
                return false
            }
        }

        var isAvailable: Bool {
            switch self.state {
            case .starting:
                return false
            case .active(_, let maxStreams, let usedStreams, _):
                return usedStreams < maxStreams
            case .draining:
                return false
            case .closed:
                return false
            }
        }

        var isStarting: Bool {
            switch self.state {
            case .starting:
                return true
            case .active:
                return false
            case .draining:
                return false
            case .closed:
                return false
            }
        }

        var isIdle: Bool {
            switch self.state {
            case .starting:
                return false
            case .active(_, _, let usedStreams, _):
                return usedStreams == 0
            case .draining:
                return false
            case .closed:
                return false
            }
        }

        var usedAndMaxStreams: (Int, Int)? {
            switch self.state {
            case .starting:
                return nil
            case .active(_, let maxStreams, let usedStreams, _):
                return (usedStreams, maxStreams)
            case .draining:
                return nil
            case .closed:
                return nil
            }
        }

        private var state: State
        let eventLoop: EventLoop
        let connectionID: Connection.ID

        var availableAndLastIdle: NIODeadline? {
            switch self.state {
            case .starting:
                return nil
            case .active(_, let maxStreams, let usedStreams, let lastReturn):
                if usedStreams < maxStreams {
                    return lastReturn
                }
                return nil
            case .draining, .closed:
                return nil
            }
        }

        mutating func started(_ conn: Connection, maxStreams: Int) {
            guard case .starting = self.state else {
                preconditionFailure("Invalid state")
            }
            self.state = .active(conn, maxStreams: maxStreams, usedStreams: 0, lastIdle: .now())
        }

        @discardableResult
        mutating func lease(_ count: Int) -> Connection {
            guard case .active(let conn, let maxStreams, var usedStreams, let lastIdle) = self.state else {
                preconditionFailure("Invalid state")
            }
            usedStreams += count
            assert(usedStreams <= maxStreams)
            self.state = .active(conn, maxStreams: maxStreams, usedStreams: usedStreams, lastIdle: lastIdle)
            return conn
        }

        mutating func release() {
            guard case .active(let conn, let maxStreams, var usedStreams, var lastIdle) = self.state else {
                preconditionFailure("Invalid state")
            }
            usedStreams -= 1
            assert(usedStreams >= 0)
            if usedStreams == 0 {
                lastIdle = .now()
            }
            self.state = .active(conn, maxStreams: maxStreams, usedStreams: usedStreams, lastIdle: lastIdle)
        }

        mutating func close() -> Connection {
            guard case .active(let conn, _, 0, _) = self.state else {
                preconditionFailure("Invalid state")
            }
            self.state = .closed
            return conn
        }

        init(connectionID: Connection.ID, eventLoop: EventLoop) {
            self.connectionID = connectionID
            self.eventLoop = eventLoop
            self.state = .starting
        }
    }

    struct HTTP2StateMachine {
        typealias Action = HTTPConnectionPool.StateMachine.Action

        private(set) var estimatedStreamsPerConnection = 100

        private(set) var connections = [HTTP2ConnectionState]()
        private(set) var http1Connections = [HTTP1ConnectionState]()

        private(set) var generalPurposeQueue: CircularBuffer<Waiter>
        private(set) var eventLoopBoundQueues: [EventLoopID: CircularBuffer<Waiter>]

        private(set) var isShuttingDown: Bool = false

        init(http1StateMachine: HTTP1StateMachine, eventLoopGroup: EventLoopGroup) {
            self.isShuttingDown = false
            #warning("fixme!")
            self.connections.reserveCapacity(8)
            self.generalPurposeQueue = .init(initialCapacity: http1StateMachine.waiters.count)
            self.eventLoopBoundQueues = [:]
            eventLoopGroup.makeIterator().forEach {
                self.eventLoopBoundQueues[$0.id] = .init()
            }

            http1StateMachine.connections.forEach { connection in
                switch connection.state {
                case .active:
                    self.http1Connections.append(connection)
                case .starting(let waiter):
                    let http2Connections = HTTP2ConnectionState(
                        connectionID: connection.connectionID,
                        eventLoop: connection.eventLoop
                    )
                    self.connections.append(http2Connections)

                    if let waiter = waiter {
                        if let targetEventLoop = waiter.eventLoopRequirement {
                            self.eventLoopBoundQueues[targetEventLoop.id]!.append(waiter)
                        } else {
                            self.generalPurposeQueue.append(waiter)
                        }
                    }
                case .failed, .closed:
                    preconditionFailure("Failed or closed connections should not be hold onto")
                }
            }

            var http1Waiters = http1StateMachine.waiters
            while let waiter = http1Waiters.popFirst() {
                switch waiter.eventLoopRequirement {
                case .none:
                    self.generalPurposeQueue.append(waiter)
                case .some(let eventLoop):
                    self.eventLoopBoundQueues[eventLoop.id]!.append(waiter)
                }
            }
        }

        mutating func executeTask(_ task: HTTPRequestTask, onPreffered prefferedEL: EventLoop, required: Bool) -> Action {
            // get a connection that matches the eventLoopPrefference from the persisted connections
            if required {
                if let index = self.connections.firstIndex(where: { $0.eventLoop === prefferedEL }) {
                    var connectionState = self.connections[index]
                    if connectionState.isAvailable {
                        var connectionAction: StateMachine.ConnectionAction = .none
                        if connectionState.isIdle {
                            connectionAction = .cancelTimeoutTimer(connectionState.connectionID)
                        }

                        let connection = connectionState.lease(1)
                        self.connections[index] = connectionState

                        return .init(
                            .executeTask(task, connection, cancelWaiter: nil),
                            connectionAction
                        )
                    }

                    let waiter = Waiter(task: task, eventLoopRequirement: prefferedEL)
                    self.eventLoopBoundQueues[prefferedEL.id]!.append(waiter)
                    return .init(
                        .scheduleWaiterTimeout(waiter.id, task, on: prefferedEL),
                        .none
                    )
                }

                let waiter = Waiter(task: task, eventLoopRequirement: prefferedEL)
                self.eventLoopBoundQueues[prefferedEL.id]!.append(waiter)
                let newConnection = HTTP2ConnectionState(connectionID: .init(), eventLoop: prefferedEL)
                self.connections.append(newConnection)

                return .init(
                    .scheduleWaiterTimeout(waiter.id, task, on: prefferedEL),
                    .createConnection(newConnection.connectionID, on: prefferedEL)
                )
            }

            // do we have a connection that matches our EL
            var goodMatch: (Int, NIODeadline)?
            var bestMatch: Int?

            for (index, conn) in self.connections.enumerated() {
                guard let lastIdle = conn.availableAndLastIdle else {
                    continue
                }

                // if we find an available EL that matches the preffered, let's use this
                if conn.eventLoop === prefferedEL {
                    bestMatch = index
                    break
                }

                // otherwise let's use the connection that has been idle the longest
                switch goodMatch {
                case .none:
                    goodMatch = (index, lastIdle)
                case .some(let (index, currentIdle)):
                    if currentIdle < lastIdle {
                        continue
                    }
                    goodMatch = (index, lastIdle)
                }
            }

            if let index = bestMatch ?? goodMatch?.0 {
                var connectionState = self.connections[index]
                assert(connectionState.isAvailable)

                var connectionAction: StateMachine.ConnectionAction = .none
                if connectionState.isIdle {
                    connectionAction = .cancelTimeoutTimer(connectionState.connectionID)
                }

                let connection = connectionState.lease(1)
                self.connections[index] = connectionState

                return .init(
                    .executeTask(task, connection, cancelWaiter: nil),
                    connectionAction
                )
            }

            if self.connections.count == 0 {
                let waiter = Waiter(task: task, eventLoopRequirement: prefferedEL)
                self.generalPurposeQueue.append(waiter)
                let newConnection = HTTP2ConnectionState(connectionID: .init(), eventLoop: prefferedEL)
                self.connections.append(newConnection)
                return .init(
                    .scheduleWaiterTimeout(waiter.id, task, on: prefferedEL),
                    .createConnection(newConnection.connectionID, on: prefferedEL)
                )
            }

            let waiter = Waiter(task: task, eventLoopRequirement: prefferedEL)
            self.generalPurposeQueue.append(waiter)

            return .init(
                .scheduleWaiterTimeout(waiter.id, task, on: prefferedEL),
                .none
            )
        }

        mutating func newHTTP2ConnectionCreated(_ connection: Connection, settings: HTTP2Settings) -> Action {
            let maxConcurrentStreams = settings.first(where: { $0.parameter == .maxConcurrentStreams })?.value ?? 100

            guard let index = self.connections.firstIndex(where: { $0.connectionID == connection.id }) else {
                preconditionFailure("There is a new connection, that we didn't request!")
            }

            var connectionState = self.connections[index]

            connectionState.started(connection, maxStreams: maxConcurrentStreams)
            var remainingStreams = maxConcurrentStreams

            let schedulable = min(maxConcurrentStreams, self.generalPurposeQueue.count)
            let startIndex = self.generalPurposeQueue.startIndex
            let endIndex = self.generalPurposeQueue.index(startIndex, offsetBy: schedulable)
            var tasksToExecute = self.generalPurposeQueue[startIndex..<endIndex].map {
                ($0.task, cancelWaiter: $0.id)
            }

            self.generalPurposeQueue.removeFirst(schedulable)
            connectionState.lease(schedulable)

            remainingStreams -= schedulable

            // if there is more room available, pick requests from the EventLoop queue
            if connectionState.isAvailable {
                assert(remainingStreams > 0)

                let eventLoop = connectionState.eventLoop
                let eventLoopID = eventLoop.id
                var eventLoopBoundQueue = self.eventLoopBoundQueues[eventLoopID]!
                self.eventLoopBoundQueues[eventLoopID] = nil // prevent CoW
                let schedulable = min(maxConcurrentStreams, eventLoopBoundQueue.count)
                let startIndex = eventLoopBoundQueue.startIndex
                let endIndex = eventLoopBoundQueue.index(startIndex, offsetBy: schedulable)

                tasksToExecute.reserveCapacity(tasksToExecute.count + schedulable)
                eventLoopBoundQueue[startIndex..<endIndex].forEach {
                    tasksToExecute.append(($0.task, cancelWaiter: $0.id))
                }

                eventLoopBoundQueue.removeFirst(schedulable)
                connectionState.lease(schedulable)
                self.eventLoopBoundQueues[eventLoopID] = eventLoopBoundQueue
            }

            self.connections[index] = connectionState

            return .init(.executeTasks(tasksToExecute, connection), .none)
        }

        mutating func failedToCreateNewConnection(_ error: Error, connectionID: Connection.ID) -> Action {
            guard let index = self.connections.firstIndex(where: { $0.connectionID == connectionID }) else {
                preconditionFailure("There is a new connection, that we didn't request!")
            }

            let connection = self.connections[index]
            let eventLoopID = connection.eventLoop.id
            var eventLoopQueue = self.eventLoopBoundQueues.removeValue(forKey: eventLoopID)!

            let activeConnectionExists = self.connections.contains(where: { $0.isActive })
            let waitersToFailCount = activeConnectionExists
                ? eventLoopQueue.count
                : eventLoopQueue.count + self.generalPurposeQueue.count

            var tasksToFail = [(HTTPRequestTask, cancelWaiter: Waiter.ID?)]()
            tasksToFail.reserveCapacity(waitersToFailCount)

            if activeConnectionExists {
                // If creating a connection fails and we there is no active connection, fail all
                // waiters.
                self.generalPurposeQueue.forEach { tasksToFail.append(($0.task, $0.id)) }
                self.generalPurposeQueue.removeAll(keepingCapacity: true)
            }

            eventLoopQueue.forEach { tasksToFail.append(($0.task, $0.id)) }
            eventLoopQueue.removeAll(keepingCapacity: true)
            self.eventLoopBoundQueues[eventLoopID] = eventLoopQueue

            self.connections.remove(at: index)
            return .init(.failTasks(tasksToFail, error), .none)
        }

        mutating func connectionTimeout(_ connectionID: Connection.ID) -> Action {
            guard let index = self.connections.firstIndex(where: { $0.connectionID == connectionID }) else {
                // There might be a race between a connection closure and the timeout event. If
                // we receive a connection close at the same time as a connection timeout, we may
                // remove the connection before, we can consume the timeout event
                return .init(.none, .none)
            }

            assert(!self.isShuttingDown, "If we are shutting down, we must not have any idle connections")

            var connectionState = self.connections[index]
            guard connectionState.isIdle else {
                // There might be a race between a connection lease and the timeout event. If
                // a connection is leased at the same time as a connection timeout triggers, the
                // lease may happen directly before the timeout. In this case we obviously do
                // nothing.
                return .init(.none, .none)
            }

            self.connections.remove(at: index)
            return .init(.none, .closeConnection(connectionState.close(), isShutdown: .yes(unclean: false)))
        }

        mutating func http1ConnectionReleased(_: Connection.ID) -> Action {
            preconditionFailure("This needs an implementation. Needs to be implemented once we allow pool transitions")
        }

        /// A connection is done processing a task
        mutating func http2ConnectionStreamClosed(_ connectionID: Connection.ID, availableStreams: Int) -> Action {
            guard let index = self.connections.firstIndex(where: { $0.connectionID == connectionID }) else {
                preconditionFailure("Expected to have a connection for id: \(connectionID)")
            }

            var connectionState = self.connections[index]
            let eventLoopID = connectionState.eventLoop.id
            assert(!connectionState.isStarting)
            let wasAvailable = connectionState.isAvailable
            connectionState.release()

            // the connection was full. is there's anything queued, we should schedule this now

            if wasAvailable == false {
                if let waiter = self.generalPurposeQueue.popFirst() {
                    let connection = connectionState.lease(1)
                    self.connections[index] = connectionState
                    return .init(.executeTask(waiter.task, connection, cancelWaiter: waiter.id), .none)
                }

                if let waiter = self.eventLoopBoundQueues[eventLoopID]!.popFirst() {
                    assert(waiter.eventLoopRequirement!.id == eventLoopID)
                    let connection = connectionState.lease(1)
                    self.connections[index] = connectionState
                    return .init(.executeTask(waiter.task, connection, cancelWaiter: waiter.id), .none)
                }
            }

            // there are no more waiters left to take care of
            assert(self.generalPurposeQueue.isEmpty)
            assert(self.eventLoopBoundQueues[eventLoopID]!.isEmpty)

            self.connections[index] = connectionState

            if connectionState.isIdle {
                return .init(.none, .scheduleTimeoutTimer(connectionID))
            }

            return .init(.none, .none)
        }

        /// A connection has been closed
        mutating func connectionClosed(_ connectionID: Connection.ID) -> Action {
            guard let index = self.connections.firstIndex(where: { $0.connectionID == connectionID }) else {
                preconditionFailure("There must be at least one connection with id: \(connectionID)")
            }

            let oldConnectionState = self.connections.remove(at: index)

            if !self.generalPurposeQueue.isEmpty {
                // a connection was closed and we have something waiting
                // if something is waiting... we don't have any eventLoop bound connection with
                // space. Otherwise we would already have transitioned this connection into a
                // overflow connection.

                var starting = 0
                self.connections.forEach { if $0.isStarting == true { starting += 1 } }
                let waiting = self.generalPurposeQueue.count
                let potentialRoom = starting * self.estimatedStreamsPerConnection

                if potentialRoom < waiting {
                    preconditionFailure("Better syntax with eventLoopID")
//                        let eventLoopID = oldConnectionState.eventLoopID
//                        let newConnectionState = HTTP2ConnectionState(connectionID: .init(), eventLoopID: eventLoopID)
//                        self.persistentConnections.append(newConnectionState)
//                        return .createNewConnection(eventLoopID, connectionID: newConnectionState.connectionID)
                }
            }

            // the connection was lost, but we don't have any tasks waiting... let's wait until
            // we have a need to recreate a new connection
            return .init(.none, .none)
        }

        mutating func timeoutWaiter(_: Waiter.ID) -> Action {
            preconditionFailure("Unimplemented")
        }

        mutating func cancelWaiter(_: Waiter.ID) -> Action {
            preconditionFailure("Unimplemented")
        }

        mutating func shutdown() -> Action {
            preconditionFailure()
        }
    }
}

extension HTTPConnectionPool.HTTP2StateMachine: CustomStringConvertible {
    var description: String {
        var starting = 0
        var active = ""

        for connectionState in self.connections {
            if connectionState.isStarting {
                starting += 1
            } else if let (used, max) = connectionState.usedAndMaxStreams {
                if active.isEmpty {
                    active += "(\(used)/\(max))"
                } else {
                    active += ", (\(used)/\(max))"
                }
            }
        }

        let waiters = generalPurposeQueue.count + self.eventLoopBoundQueues.reduce(0) { $0 + $1.value.count }

        return "connections: [starting: \(starting) | active: \(active)], waiters: \(waiters)"
    }
}
