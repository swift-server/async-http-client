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

import Logging
import NIO
import NIOConcurrencyHelpers
import NIOHTTP1
import NIOSSL
import NIOTLS
import NIOTransportServices
#if canImport(Network)
    import Network
    import Security
#endif
    
protocol HTTPConnectionPoolDelegate {
    func connectionPoolDidShutdown(_ pool: HTTPConnectionPool, unclean: Bool)
}

class HTTPConnectionPool {
    
    struct Connection: Equatable {
        typealias ID = Int

        private enum Reference {
            case http1_1(HTTP1Connection)
            case http2(HTTP2Connection)

            #if DEBUG
                case testing(ID, EventLoop)
            #endif
        }

        private let _ref: Reference

        fileprivate static func http1_1(_ conn: HTTP1Connection) -> Self {
            Connection(_ref: .http1_1(conn))
        }

        fileprivate static func http2(_ conn: HTTP2Connection) -> Self {
            Connection(_ref: .http2(conn))
        }

        #if DEBUG
            static func testing(id: ID, eventLoop: EventLoop) -> Self {
                Connection(_ref: .testing(id, eventLoop))
            }
        #endif

        var id: ID {
            switch self._ref {
            case .http1_1(let connection):
                return connection.id
            case .http2(let connection):
                return connection.id
            #if DEBUG
                case .testing(let id, _):
                    return id
            #endif
            }
        }

        var eventLoop: EventLoop {
            switch self._ref {
            case .http1_1(let connection):
                return connection.channel.eventLoop
            case .http2(let connection):
                return connection.channel.eventLoop
            #if DEBUG
                case .testing(_, let eventLoop):
                    return eventLoop
            #endif
            }
        }

        #if DEBUG
            /// NOTE: This is purely for testing. NEVER, EVER write into the channel from here. Only the real connection should actually
            ///      write into the channel.
            var channel: Channel {
                switch self._ref {
                case .http1_1(let connection):
                    return connection.channel
                case .http2(let connection):
                    return connection.channel
                #if DEBUG
                    case .testing:
                        preconditionFailure("This is only for testing without real IO")
                #endif
                }
            }
        #endif

        @discardableResult
        fileprivate func close() -> EventLoopFuture<Void> {
            switch self._ref {
            case .http1_1(let connection):
                return connection.close()
            case .http2(let connection):
                return connection.close()
            #if DEBUG
                case .testing(_, let eventLoop):
                    return eventLoop.makeSucceededFuture(())
            #endif
            }
        }

        fileprivate func execute(request: HTTPRequestTask) {
            request.willBeExecutedOnConnection(self)
            switch self._ref {
            case .http1_1(let connection):
                return connection.execute(request: request)
            case .http2(let connection):
                return connection.execute(request: request)
            #if DEBUG
                case .testing:
                    break
            #endif
            }
        }

        fileprivate func cancel() {
            switch self._ref {
            case .http1_1(let connection):
                return connection.cancel()
            case .http2(let connection):
                preconditionFailure("Unimplementd")
//                return connection.cancel()
            #if DEBUG
                case .testing:
                    break
            #endif
            }
        }

        static func == (lhs: HTTPConnectionPool.Connection, rhs: HTTPConnectionPool.Connection) -> Bool {
            switch (lhs._ref, rhs._ref) {
            case (.http1_1(let lhsConn), .http1_1(let rhsConn)):
                return lhsConn === rhsConn
            case (.http2(let lhsConn), .http2(let rhsConn)):
                return lhsConn === rhsConn
            #if DEBUG
                case (.testing(let lhsID, let lhsEventLoop), .testing(let rhsID, let rhsEventLoop)):
                    return lhsID == rhsID && lhsEventLoop === rhsEventLoop
            #endif
            default:
                return false
            }
        }
    }
    
    let stateLock = Lock()
    private var _state: StateMachine {
        didSet {
            self.logger.trace("Connection Pool State changed", metadata: [
                "key": "\(self.key)",
                "state": "\(self._state)",
            ])
        }
    }

    let timerLock = Lock()
    private var _waiters = [Waiter.ID: Scheduled<Void>]()
    private var _timer = [Connection.ID: Scheduled<Void>]()

    let key: ConnectionPool.Key
    var logger: Logger

    let eventLoopGroup: EventLoopGroup
    let connectionFactory: ConnectionFactory
    let idleConnectionTimeout: TimeAmount

    let delegate: HTTPConnectionPoolDelegate

    init(eventLoopGroup: EventLoopGroup,
         sslContextCache: SSLContextCache,
         tlsConfiguration: TLSConfiguration?,
         clientConfiguration: HTTPClient.Configuration,
         key: ConnectionPool.Key,
         delegate: HTTPConnectionPoolDelegate,
         idGenerator: Connection.ID.Generator,
         logger: Logger) {
        self.eventLoopGroup = eventLoopGroup
        self.connectionFactory = ConnectionFactory(
            key: key,
            tlsConfiguration: tlsConfiguration,
            clientConfiguration: clientConfiguration,
            sslContextCache: sslContextCache
        )
        self.key = key
        self.delegate = delegate
        self.logger = logger

        self.idleConnectionTimeout = clientConfiguration.connectionPool.idleTimeout

        self._state = StateMachine(
            eventLoopGroup: eventLoopGroup,
            idGenerator: idGenerator,
            maximumConcurrentHTTP1Connections: 8
        )
    }

    func execute(request: HTTPRequestTask) {
        let (eventLoop, required) = request.resolveEventLoop()

        let action = self.stateLock.withLock { () -> StateMachine.Action in
            self._state.executeTask(request, onPreffered: eventLoop, required: required)
        }
        self.run(action: action)
    }

    func shutdown() {
        let action = self.stateLock.withLock { () -> StateMachine.Action in
            self._state.shutdown()
        }
        self.run(action: action)
    }

    func run(action: StateMachine.Action) {
        self.run(connectionAction: action.connection)
        self.run(taskAction: action.task)
    }

    func run(connectionAction: StateMachine.ConnectionAction) {
        switch connectionAction {
        case .createConnection(let connectionID, let eventLoop):
            self.createConnection(connectionID, on: eventLoop)

        case .scheduleTimeoutTimer(let connectionID):
            self.scheduleTimerForConnection(connectionID)

        case .cancelTimeoutTimer(let connectionID):
            self.cancelTimerForConnection(connectionID)

        case .replaceConnection(let oldConnection, with: let newConnectionID, on: let eventLoop):
            oldConnection.close()
            self.createConnection(newConnectionID, on: eventLoop)

        case .closeConnection(let connection, isShutdown: let isShutdown):
            connection.close()

            if case .yes(let unclean) = isShutdown {
                self.delegate.connectionPoolDidShutdown(self, unclean: unclean)
            }

        case .cleanupConnection(let close, let cancel, isShutdown: let isShutdown):
            for connection in close {
                connection.close()
            }

            for connection in cancel {
                connection.cancel()
            }

            if case .yes(let unclean) = isShutdown {
                self.delegate.connectionPoolDidShutdown(self, unclean: unclean)
            }

        case .none:
            break
        }
    }

    func run(taskAction: StateMachine.TaskAction) {
        switch taskAction {
        case .executeTask(let request, let connection, let waiterID):
            connection.execute(request: request)
            if let waiterID = waiterID {
                self.cancelWaiterTimeout(waiterID)
            }

        case .executeTasks(let requests, let connection):
            for (request, waiterID) in requests {
                connection.execute(request: request)
                if let waiterID = waiterID {
                    self.cancelWaiterTimeout(waiterID)
                }
            }

        case .failTask(let request, let error, cancelWaiter: let waiterID):
            request.fail(error)

            if let waiterID = waiterID {
                self.cancelWaiterTimeout(waiterID)
            }

        case .failTasks(let requests, let error):
            for (request, waiterID) in requests {
                request.fail(error)

                if let waiterID = waiterID {
                    self.cancelWaiterTimeout(waiterID)
                }
            }

        case .scheduleWaiterTimeout(let waiterID, let task, on: let eventLoop):
            self.scheduleWaiterTimeout(waiterID, task, on: eventLoop)

        case .cancelWaiterTimeout(let waiterID):
            self.cancelWaiterTimeout(waiterID)

        case .none:
            break
        }
    }

    // MARK: Run actions

    func createConnection(_ connectionID: Connection.ID, on eventLoop: EventLoop) {
        self.connectionFactory.makeConnection(
            for: self,
            connectionID: connectionID,
            eventLoop: eventLoop,
            logger: self.logger
        )
    }

    func scheduleWaiterTimeout(_ id: Waiter.ID, _ task: HTTPRequestTask, on eventLoop: EventLoop) {
        let deadline = task.connectionDeadline
        let scheduled = eventLoop.scheduleTask(deadline: deadline) {
            // The timer has fired. Now we need to do a couple of things:
            //
            // 1. Remove ourselfes from the timer dictionary to not leak any data. If our
            //    waiter entry still exist, we need to tell the state machine, that we want
            //    to fail the request.

            let timeout = self.timerLock.withLock {
                self._waiters.removeValue(forKey: id) != nil
            }

            // 2. If the entry did not exists anymore, we can assume that the request was
            //    scheduled on another connection. The timer still fired anyhow because of a
            //    race. In such a situation we don't need to do anything.
            guard timeout else { return }

            // 3. Tell the state machine about the time
            let action = self.stateLock.withLock {
                self._state.waiterTimeout(id)
            }

            self.run(action: action)
        }

        self.timerLock.withLockVoid {
            precondition(self._waiters[id] == nil)
            self._waiters[id] = scheduled
        }

        task.requestWasQueued(self)
    }

    func cancelWaiterTimeout(_ id: Waiter.ID) {
        let scheduled = self.timerLock.withLock {
            self._waiters.removeValue(forKey: id)
        }

        scheduled?.cancel()
    }

    func scheduleTimerForConnection(_ connectionID: Connection.ID) {
        assert(self._timer[connectionID] == nil)

        let scheduled = self.eventLoopGroup.next().scheduleTask(in: self.idleConnectionTimeout) {
            // there might be a race between a cancelTimer call and the triggering
            // of this scheduled task. both want to acquire the lock
            self.stateLock.withLockVoid {
                guard self._timer.removeValue(forKey: connectionID) != nil else {
                    // a cancel method has potentially won
                    return
                }

                let action = self._state.connectionTimeout(connectionID)
                self.run(action: action)
            }
        }

        self._timer[connectionID] = scheduled
    }

    func cancelTimerForConnection(_ connectionID: Connection.ID) {
        guard let cancelTimer = self._timer.removeValue(forKey: connectionID) else {
            return
        }

        cancelTimer.cancel()
    }
}

extension HTTPConnectionPool {
    func http1ConnectionCreated(_ connection: HTTP1Connection) {
        let action = self.stateLock.withLock {
            self._state.newHTTP1ConnectionCreated(.http1_1(connection))
        }
        self.run(action: action)
    }

    func http2ConnectionCreated(_ connection: HTTP2Connection) {
        let action = self.stateLock.withLock { () -> StateMachine.Action in
            if let settings = connection.settings {
                return self._state.newHTTP2ConnectionCreated(.http2(connection), settings: settings)
            } else {
                // immidiate connection closure before we can register with state machine
                // is the only reason we don't have settings
                struct ImmidiateConnectionClose: Error {}
                return self._state.failedToCreateNewConnection(ImmidiateConnectionClose(), connectionID: connection.id)
            }
        }
        self.run(action: action)
    }

    func failedToCreateHTTPConnection(_ connectionID: Connection.ID, error: Error) {
        let action = self.stateLock.withLock {
            self._state.failedToCreateNewConnection(error, connectionID: connectionID)
        }
        self.run(action: action)
    }
}

extension HTTPConnectionPool: HTTP1ConnectionDelegate {
    func http1ConnectionClosed(_ connection: HTTP1Connection) {
        let action = self.stateLock.withLock {
            self._state.connectionClosed(connection.id)
        }
        self.run(action: action)
    }

    func http1ConnectionReleased(_ connection: HTTP1Connection) {
        let action = self.stateLock.withLock {
            self._state.http1ConnectionReleased(connection.id)
        }
        self.run(action: action)
    }
}

extension HTTPConnectionPool: HTTP2ConnectionDelegate {
    func http2ConnectionClosed(_ connection: HTTP2Connection) {
        self.stateLock.withLock {
            let action = self._state.connectionClosed(connection.id)
            self.run(action: action)
        }
    }

    func http2ConnectionStreamClosed(_ connection: HTTP2Connection, availableStreams: Int) {
        self.stateLock.withLock {
            let action = self._state.http2ConnectionStreamClosed(connection.id, availableStreams: availableStreams)
            self.run(action: action)
        }
    }
}

extension HTTPConnectionPool: HTTP1RequestQueuer {
    func cancelRequest(task: HTTPRequestTask) {
        let waiterID = Waiter.ID(task)
        let action = self.stateLock.withLock {
            self._state.cancelWaiter(waiterID)
        }

        self.run(action: action)
    }
}

extension HTTPRequestTask {
    fileprivate func resolveEventLoop() -> (EventLoop, Bool) {
        switch self.eventLoopPreference.preference {
        case .indifferent:
            return (self.eventLoop, false)
        case .delegate(let el):
            return (el, false)
        case .delegateAndChannel(let el), .testOnly_exact(let el, _):
            return (el, true)
        }
    }
}

struct EventLoopID: Hashable {
    private var id: Identifier

    enum Identifier: Hashable {
        case objectIdentifier(ObjectIdentifier)

        #if DEBUG
            case forTesting(Int)
        #endif
    }

    init(_ eventLoop: EventLoop) {
        self.id = .objectIdentifier(.init(eventLoop))
    }

    #if DEBUG
        init() {
            self.id = .forTesting(.init())
        }

        init(int: Int) {
            self.id = .forTesting(int)
        }
    #endif
}

extension EventLoop {
    var id: EventLoopID { EventLoopID(self) }
}
