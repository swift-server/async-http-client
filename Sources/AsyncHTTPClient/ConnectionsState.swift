//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2019-2020 Apple Inc. and the AsyncHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO

extension HTTP1ConnectionProvider {
    enum Action {
        case lease(Connection, Waiter)
        case create(Waiter)
        case replace(Connection, Waiter)
        case closeProvider
        case park(Connection)
        case none
        case fail(Waiter, Error)
        indirect case closeAnd(Connection, Action)
        indirect case parkAnd(Connection, Action)
    }

    struct ConnectionsState {
        enum State {
            case active
            case closed
        }

        struct Snapshot {
            var state: State
            var availableConnections: CircularBuffer<Connection>
            var leasedConnections: Set<ConnectionKey>
            var waiters: CircularBuffer<Waiter>
            var openedConnectionsCount: Int
            var pending: Int
        }

        let maximumConcurrentConnections: Int
        let eventLoop: EventLoop

        private var state: State = .active

        /// Opened connections that are available.
        private var availableConnections: CircularBuffer<Connection> = .init(initialCapacity: 8)

        /// Opened connections that are leased to the user.
        private var leasedConnections: Set<ConnectionKey> = .init()

        /// Consumers that weren't able to get a new connection without exceeding
        /// `maximumConcurrentConnections` get a `Future<Connection>`
        /// whose associated promise is stored in `Waiter`. The promise is completed
        /// as soon as possible by the provider, in FIFO order.
        private var waiters: CircularBuffer<Waiter> = .init(initialCapacity: 8)

        /// Number of opened or opening connections, used to keep track of all connections and enforcing `maximumConcurrentConnections` limit.
        private var openedConnectionsCount: Int = 0

        /// Number of enqueued requests, used to track if it is safe to delete the provider.
        private var pending: Int = 0

        init(maximumConcurrentConnections: Int = 8, eventLoop: EventLoop) {
            self.maximumConcurrentConnections = maximumConcurrentConnections
            self.eventLoop = eventLoop
        }

        func testsOnly_getInternalState() -> Snapshot {
            return Snapshot(state: self.state, availableConnections: self.availableConnections, leasedConnections: self.leasedConnections, waiters: self.waiters, openedConnectionsCount: self.openedConnectionsCount, pending: self.pending)
        }

        mutating func testsOnly_setInternalState(_ snapshot: Snapshot) {
            self.state = snapshot.state
            self.availableConnections = snapshot.availableConnections
            self.leasedConnections = snapshot.leasedConnections
            self.waiters = snapshot.waiters
            self.openedConnectionsCount = snapshot.openedConnectionsCount
            self.pending = snapshot.pending
        }

        func assertInvariants() {
            assert(self.waiters.isEmpty)
            assert(self.availableConnections.isEmpty)
            assert(self.leasedConnections.isEmpty)
            assert(self.openedConnectionsCount == 0)
            assert(self.pending == 0)
        }

        mutating func enqueue() -> Bool {
            switch self.state {
            case .active:
                self.pending += 1
                return true
            case .closed:
                return false
            }
        }

        private var hasCapacity: Bool {
            return self.openedConnectionsCount < self.maximumConcurrentConnections
        }

        private var isEmpty: Bool {
            return self.openedConnectionsCount == 0 && self.pending == 0
        }

        mutating func acquire(waiter: Waiter) -> Action {
            switch self.state {
            case .active:
                self.pending -= 1

                let (eventLoop, required) = self.resolvePreference(waiter.preference)
                if required {
                    // If there is an opened connection on the same EL - use it
                    if let found = self.availableConnections.firstIndex(where: { $0.channel.eventLoop === eventLoop }) {
                        let connection = self.availableConnections.remove(at: found)
                        self.leasedConnections.insert(ConnectionKey(connection))
                        return .lease(connection, waiter)
                    }

                    // If we can create additional connection, create
                    if self.hasCapacity {
                        self.openedConnectionsCount += 1
                        return .create(waiter)
                    }

                    // If we cannot create additional connection, but there is one in the pool, replace it
                    if let connection = self.availableConnections.popFirst() {
                        return .replace(connection, waiter)
                    }

                    self.waiters.append(waiter)
                    return .none
                } else if let connection = self.availableConnections.popFirst() {
                    self.leasedConnections.insert(ConnectionKey(connection))
                    return .lease(connection, waiter)
                } else if self.hasCapacity {
                    self.openedConnectionsCount += 1
                    return .create(waiter)
                } else {
                    self.waiters.append(waiter)
                    return .none
                }
            case .closed:
                return .fail(waiter, HTTPClientError.alreadyShutdown)
            }
        }

        mutating func release(connection: Connection, closing: Bool) -> Action {
            switch self.state {
            case .active:
                assert(self.leasedConnections.contains(ConnectionKey(connection)))

                if connection.isActiveEstimation, !closing { // If connection is alive, we can offer it to a next waiter
                    if let waiter = self.waiters.popFirst() {
                        let (eventLoop, required) = self.resolvePreference(waiter.preference)

                        // If returned connection is on same EL or we do not require special EL - lease it
                        if connection.channel.eventLoop === eventLoop || !required {
                            return .lease(connection, waiter)
                        }

                        // If there is an opened connection on the same loop, lease it and park returned
                        if let found = self.availableConnections.firstIndex(where: { $0.channel.eventLoop === eventLoop }) {
                            self.leasedConnections.remove(ConnectionKey(connection))
                            let replacement = self.availableConnections.swap(at: found, with: connection)
                            self.leasedConnections.insert(ConnectionKey(replacement))
                            return .parkAnd(connection, .lease(replacement, waiter))
                        }

                        // If we can create new connection - do it
                        if self.hasCapacity {
                            self.leasedConnections.remove(ConnectionKey(connection))
                            self.availableConnections.append(connection)
                            self.openedConnectionsCount += 1
                            return .parkAnd(connection, .create(waiter))
                        }

                        // If we cannot create new connections, we will have to replace returned connection with a new one on the required loop
                        return .replace(connection, waiter)
                    } else { // or park, if there are no waiters
                        self.leasedConnections.remove(ConnectionKey(connection))
                        self.availableConnections.append(connection)
                        return .park(connection)
                    }
                } else { // if connection is not alive, we delete it and process the next waiter
                    // this connections is now gone, we will either create new connection or do nothing
                    self.openedConnectionsCount -= 1
                    self.leasedConnections.remove(ConnectionKey(connection))

                    return self.processNextWaiter()
                }
            case .closed:
                if nil != self.leasedConnections.remove(ConnectionKey(connection)) {
                    self.openedConnectionsCount -= 1
                }

                return self.processNextWaiter()
            }
        }

        mutating func offer(connection: Connection) -> Action {
            switch self.state {
            case .active:
                self.leasedConnections.insert(ConnectionKey(connection))
                return .none
            case .closed: // This can happen when we close the client while connections was being established
                self.openedConnectionsCount -= 1
                return .closeAnd(connection, self.processNextWaiter())
            }
        }

        mutating func drop(connection: Connection) {
            switch self.state {
            case .active:
                self.leasedConnections.remove(ConnectionKey(connection))
            case .closed:
                assertionFailure("should not happen")
            }
        }

        mutating func connectFailed() -> Action {
            switch self.state {
            case .active:
                self.openedConnectionsCount -= 1
                return self.processNextWaiter()
            case .closed:
                // This can happen in the following scenario: user initiates a connection that will fail to connect,
                // user calls `syncShutdown` before we received an error from the bootstrap. In this scenario,
                // pool will be `.closed` but connection will be still in the process of being established/failed,
                // so then this process finishes, it will get to this point.
                // We need to call `processNextWaiter` to finish deleting provider from the pool.
                self.openedConnectionsCount -= 1
                return self.processNextWaiter()
            }
        }

        mutating func remoteClosed(connection: Connection) -> Action {
            switch self.state {
            case .active:
                // Connection can be closed remotely while we wait for `.lease` action to complete.
                // If this happens when connections is leased, we do not remove it from leased connections,
                // it will be done when a new replacement will be ready for it.
                if self.leasedConnections.contains(ConnectionKey(connection)) {
                    return .none
                }

                // If this connection is not in use, the have to release it as well
                self.openedConnectionsCount -= 1
                self.availableConnections.removeAll { $0 === connection }

                return self.processNextWaiter()
            case .closed:
                self.openedConnectionsCount -= 1
                return self.processNextWaiter()
            }
        }

        mutating func timeout(connection: Connection) -> Action {
            switch self.state {
            case .active:
                // We can get timeout and inUse = true when we decided to lease the connection, but this action is not executed yet.
                // In this case we can ignore timeout notification.
                if self.leasedConnections.contains(ConnectionKey(connection)) {
                    return .none
                }

                // If connection was not in use, we release it from the pool, increasing available capacity
                self.openedConnectionsCount -= 1
                self.availableConnections.removeAll { $0 === connection }

                return .closeAnd(connection, self.processNextWaiter())
            case .closed:
                // This situation can happen when we call close, state changes, but before we call `close` on all
                // available connections, in this case we should close this connection and, potentially,
                // delete the provider
                self.openedConnectionsCount -= 1
                self.availableConnections.removeAll { $0 === connection }

                return .closeAnd(connection, self.processNextWaiter())
            }
        }

        mutating func processNextWaiter() -> Action {
            if let waiter = self.waiters.popFirst() {
                let (eventLoop, required) = self.resolvePreference(waiter.preference)

                // If specific EL is required, we have only two options - find open one or create a new one
                if required, let found = self.availableConnections.firstIndex(where: { $0.channel.eventLoop === eventLoop }) {
                    let connection = self.availableConnections.remove(at: found)
                    self.leasedConnections.insert(ConnectionKey(connection))
                    return .lease(connection, waiter)
                } else if !required, let connection = self.availableConnections.popFirst() {
                    self.leasedConnections.insert(ConnectionKey(connection))
                    return .lease(connection, waiter)
                } else {
                    self.openedConnectionsCount += 1
                    return .create(waiter)
                }
            }

            // if capacity is at max and the are no waiters and no in-flight requests for connection, we are closing this provider
            if self.isEmpty {
                // deactivate and remove
                self.state = .closed
                return .closeProvider
            }

            return .none
        }

        mutating func close() -> (CircularBuffer<Waiter>, CircularBuffer<Connection>, Set<ConnectionKey>, Bool)? {
            switch self.state {
            case .active:
                let waiters = self.waiters
                self.waiters.removeAll()

                let available = self.availableConnections
                self.availableConnections.removeAll()

                let leased = self.leasedConnections

                self.state = .closed

                return (waiters, available, leased, self.openedConnectionsCount - available.count == 0)
            case .closed:
                return nil
            }
        }

        private func resolvePreference(_ preference: HTTPClient.EventLoopPreference) -> (EventLoop, Bool) {
            switch preference.preference {
            case .indifferent:
                return (self.eventLoop, false)
            case .delegate(let el):
                return (el, false)
            case .delegateAndChannel(let el), .testOnly_exact(let el, _):
                return (el, true)
            }
        }
    }
}
