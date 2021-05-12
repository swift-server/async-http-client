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
    enum Action<ConnectionType: PoolManageableConnection> {
        case lease(ConnectionType, Waiter<ConnectionType>)
        case create(Waiter<ConnectionType>)
        case replace(ConnectionType, Waiter<ConnectionType>)
        case closeProvider
        case park(ConnectionType)
        case none
        case fail(Waiter<ConnectionType>, Error)
        indirect case closeAnd(ConnectionType, Action<ConnectionType>)
        indirect case parkAnd(ConnectionType, Action<ConnectionType>)
    }

    struct ConnectionsState<ConnectionType: PoolManageableConnection> {
        enum State {
            case active
            case closed
        }

        struct Snapshot<ConnectionType: PoolManageableConnection> {
            var state: State
            var availableConnections: CircularBuffer<ConnectionType>
            var leasedConnections: Set<ConnectionKey<ConnectionType>>
            var waiters: CircularBuffer<Waiter<ConnectionType>>
            var openedConnectionsCount: Int
            var pending: Int
        }

        let maximumConcurrentConnections: Int
        let eventLoop: EventLoop

        private var state: State = .active

        /// Opened connections that are available.
        private var availableConnections: CircularBuffer<ConnectionType> = .init(initialCapacity: 8)

        /// Opened connections that are leased to the user.
        private var leasedConnections: Set<ConnectionKey<ConnectionType>> = .init()

        /// Consumers that weren't able to get a new connection without exceeding
        /// `maximumConcurrentConnections` get a `Future<Connection>`
        /// whose associated promise is stored in `Waiter`. The promise is completed
        /// as soon as possible by the provider, in FIFO order.
        private var waiters: CircularBuffer<Waiter<ConnectionType>> = .init(initialCapacity: 8)

        /// Number of opened or opening connections, used to keep track of all connections and enforcing `maximumConcurrentConnections` limit.
        private var openedConnectionsCount: Int = 0

        /// Number of enqueued requests, used to track if it is safe to delete the provider.
        private var pending: Int = 0

        init(maximumConcurrentConnections: Int = 8, eventLoop: EventLoop) {
            self.maximumConcurrentConnections = maximumConcurrentConnections
            self.eventLoop = eventLoop
        }

        func testsOnly_getInternalState() -> Snapshot<ConnectionType> {
            return Snapshot(state: self.state, availableConnections: self.availableConnections, leasedConnections: self.leasedConnections, waiters: self.waiters, openedConnectionsCount: self.openedConnectionsCount, pending: self.pending)
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

        mutating func acquire(waiter: Waiter<ConnectionType>) -> Action<ConnectionType> {
            switch self.state {
            case .active:
                self.pending -= 1

                let (eventLoop, required) = self.resolvePreference(waiter.preference)
                if required {
                    // If there is an opened connection on the same EL - use it
                    if let found = self.availableConnections.firstIndex(where: { $0.eventLoop === eventLoop }) {
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

        mutating func release(connection: ConnectionType, closing: Bool) -> Action<ConnectionType> {
            switch self.state {
            case .active:
                assert(self.leasedConnections.contains(ConnectionKey(connection)))

                if connection.isActiveEstimation, !closing { // If connection is alive, we can offer it to a next waiter
                    if let waiter = self.waiters.popFirst() {
                        // There should be no case where we have both capacity and a waiter here.
                        // Waiter can only exists if there was no capacity at aquire. If some connection
                        // is released when we have waiter it can only indicate that we should lease (if EL are the same),
                        // or replace (if they are different). But we cannot increase connection count here.
                        assert(!self.hasCapacity)

                        let (eventLoop, required) = self.resolvePreference(waiter.preference)

                        // If returned connection is on same EL or we do not require special EL - lease it
                        if connection.eventLoop === eventLoop || !required {
                            return .lease(connection, waiter)
                        }

                        // If we cannot create new connections, we will have to replace returned connection with a new one on the required loop
                        // We will keep the `openedConnectionCount`, since .replace === .create, so we decrease and increase the `openedConnectionCount`
                        self.leasedConnections.remove(ConnectionKey(connection))
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
                self.openedConnectionsCount -= 1
                self.leasedConnections.remove(ConnectionKey(connection))

                return self.processNextWaiter()
            }
        }

        mutating func offer(connection: ConnectionType) -> Action<ConnectionType> {
            switch self.state {
            case .active:
                self.leasedConnections.insert(ConnectionKey(connection))
                return .none
            case .closed: // This can happen when we close the client while connections was being established
                self.openedConnectionsCount -= 1
                return .closeAnd(connection, self.processNextWaiter())
            }
        }

        mutating func connectFailed() -> Action<ConnectionType> {
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

        mutating func remoteClosed(connection: ConnectionType) -> Action<ConnectionType> {
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

        mutating func timeout(connection: ConnectionType) -> Action<ConnectionType> {
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

        mutating func processNextWaiter() -> Action<ConnectionType> {
            if let waiter = self.waiters.popFirst() {
                // There should be no case where we have waiters and available connections at the same time.
                //
                // This method is called in following cases:
                //
                // 1. from `release` when connection is inactive and cannot be re-used
                // 2. from `connectFailed` when we failed to establish a new connection
                // 3. from `remoteClose` when connection was closed by the remote side and cannot be re-used
                // 4. from `timeout` when connection was closed due to idle timeout and cannot be re-used.
                //
                // In all cases connection, which triggered the transition, will not be in `available` state.
                //
                // Given that the waiter can only be present in the pool if there were no available connections
                // (otherwise it had been leased a connection immediately on getting the connection), we do not
                // see a situation when we can lease another available connection, therefore the only course
                // of action is to create a new connection for the waiter.
                assert(self.availableConnections.isEmpty)

                self.openedConnectionsCount += 1
                return .create(waiter)
            }

            // if capacity is at max and the are no waiters and no in-flight requests for connection, we are closing this provider
            if self.isEmpty {
                // deactivate and remove
                self.state = .closed
                return .closeProvider
            }

            return .none
        }

        mutating func close() -> (CircularBuffer<Waiter<ConnectionType>>, CircularBuffer<ConnectionType>, Set<ConnectionKey<ConnectionType>>, Bool)? {
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
