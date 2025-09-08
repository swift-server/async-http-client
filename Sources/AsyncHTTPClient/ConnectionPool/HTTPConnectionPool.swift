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
import NIOConcurrencyHelpers
import NIOCore
import NIOSSL

protocol HTTPConnectionPoolDelegate {
    func connectionPoolDidShutdown(_ pool: HTTPConnectionPool, unclean: Bool)
}

final class HTTPConnectionPool:
    // TODO: Refactor to use `NIOLockedValueBox` which will allow this to be checked
    @unchecked Sendable
{
    private let stateLock = NIOLock()
    private var _state: StateMachine
    /// The connection idle timeout timers. Protected by the stateLock
    private var _idleTimer = [Connection.ID: Scheduled<Void>]()
    /// The connection backoff timeout timers. Protected by the stateLock
    private var _backoffTimer = [Connection.ID: Scheduled<Void>]()
    /// The request connection timeout timers. Protected by the stateLock
    private var _requestTimer = [Request.ID: Scheduled<Void>]()

    private static let fallbackConnectTimeout: TimeAmount = .seconds(30)

    let key: ConnectionPool.Key

    private var logger: Logger

    private let eventLoopGroup: EventLoopGroup
    private let connectionFactory: ConnectionFactory
    private let clientConfiguration: HTTPClient.Configuration
    private let idleConnectionTimeout: TimeAmount

    let delegate: HTTPConnectionPoolDelegate

    init(
        eventLoopGroup: EventLoopGroup,
        sslContextCache: SSLContextCache,
        tlsConfiguration: TLSConfiguration?,
        clientConfiguration: HTTPClient.Configuration,
        key: ConnectionPool.Key,
        delegate: HTTPConnectionPoolDelegate,
        idGenerator: Connection.ID.Generator,
        backgroundActivityLogger logger: Logger
    ) {
        self.eventLoopGroup = eventLoopGroup
        self.connectionFactory = ConnectionFactory(
            key: key,
            tlsConfiguration: tlsConfiguration,
            clientConfiguration: clientConfiguration,
            sslContextCache: sslContextCache
        )
        self.clientConfiguration = clientConfiguration
        self.key = key
        self.delegate = delegate
        var logger = logger
        logger[metadataKey: "ahc-pool-key"] = "\(key)"
        self.logger = logger

        self.idleConnectionTimeout = clientConfiguration.connectionPool.idleTimeout

        self._state = StateMachine(
            idGenerator: idGenerator,
            maximumConcurrentHTTP1Connections: clientConfiguration.connectionPool
                .concurrentHTTP1ConnectionsPerHostSoftLimit,
            retryConnectionEstablishment: clientConfiguration.connectionPool.retryConnectionEstablishment,
            preferHTTP1: clientConfiguration.httpVersion == .http1Only,
            maximumConnectionUses: clientConfiguration.maximumUsesPerConnection,
            preWarmedHTTP1ConnectionCount: clientConfiguration.connectionPool.preWarmedHTTP1ConnectionCount
        )
    }

    func executeRequest(_ request: HTTPSchedulableRequest) {
        self.modifyStateAndRunActions { $0.executeRequest(.init(request)) }
    }

    func shutdown() {
        self.logger.debug("Shutting down connection pool")
        self.modifyStateAndRunActions { $0.shutdown() }
    }

    // MARK: - Private Methods -

    // MARK: Actions

    /// An `HTTPConnectionPool` internal action type that matches the `StateMachine`'s action.
    /// However it splits up the actions into actions that need to be executed inside the `stateLock`
    /// and outside the `stateLock`.
    private struct Actions {
        enum ConnectionAction {
            enum Unlocked {
                case createConnection(Connection.ID, on: EventLoop)
                case closeConnection(Connection, isShutdown: StateMachine.ConnectionAction.IsShutdown)
                case closeConnectionAndCreateConnection(
                    close: Connection,
                    newConnectionID: Connection.ID,
                    on: EventLoop
                )
                case cleanupConnections(CleanupContext, isShutdown: StateMachine.ConnectionAction.IsShutdown)
                case migration(
                    createConnections: [(Connection.ID, EventLoop)],
                    closeConnections: [Connection]
                )
                case none
            }

            enum Locked {
                case scheduleBackoffTimer(Connection.ID, backoff: TimeAmount, on: EventLoop)
                case cancelBackoffTimers([Connection.ID])
                case scheduleTimeoutTimer(Connection.ID, on: EventLoop)
                case cancelTimeoutTimer(Connection.ID)
                case none
            }
        }

        enum RequestAction {
            enum Unlocked {
                case executeRequest(Request, Connection)
                case executeRequests([Request], Connection)
                case failRequest(Request, Error)
                case failRequests([Request], Error)
                case none
            }

            enum Locked {
                case scheduleRequestTimeout(for: Request, on: EventLoop)
                case cancelRequestTimeout(Request.ID)
                case cancelRequestTimeouts([Request])
                case none
            }
        }

        struct Locked {
            var connection: ConnectionAction.Locked
            var request: RequestAction.Locked
        }

        struct Unlocked {
            var connection: ConnectionAction.Unlocked
            var request: RequestAction.Unlocked
        }

        var locked: Locked
        var unlocked: Unlocked

        init(from stateMachineAction: StateMachine.Action) {
            self.locked = Locked(connection: .none, request: .none)
            self.unlocked = Unlocked(connection: .none, request: .none)

            switch stateMachineAction.request {
            case .executeRequest(let request, let connection, let cancelTimeout):
                if cancelTimeout {
                    self.locked.request = .cancelRequestTimeout(request.id)
                }
                self.unlocked.request = .executeRequest(request, connection)
            case .executeRequestsAndCancelTimeouts(let requests, let connection):
                self.locked.request = .cancelRequestTimeouts(requests)
                self.unlocked.request = .executeRequests(requests, connection)
            case .failRequest(let request, let error, let cancelTimeout):
                if cancelTimeout {
                    self.locked.request = .cancelRequestTimeout(request.id)
                }
                self.unlocked.request = .failRequest(request, error)
            case .failRequestsAndCancelTimeouts(let requests, let error):
                self.locked.request = .cancelRequestTimeouts(requests)
                self.unlocked.request = .failRequests(requests, error)
            case .scheduleRequestTimeout(for: let request, on: let eventLoop):
                self.locked.request = .scheduleRequestTimeout(for: request, on: eventLoop)
            case .none:
                break
            }

            switch stateMachineAction.connection {
            case .createConnection(let connectionID, on: let eventLoop):
                self.unlocked.connection = .createConnection(connectionID, on: eventLoop)
            case .scheduleBackoffTimer(let connectionID, let backoff, on: let eventLoop):
                self.locked.connection = .scheduleBackoffTimer(connectionID, backoff: backoff, on: eventLoop)
            case .scheduleTimeoutTimer(let connectionID, on: let eventLoop):
                self.locked.connection = .scheduleTimeoutTimer(connectionID, on: eventLoop)
            case .scheduleTimeoutTimerAndCreateConnection(let timeoutID, let newConnectionID, let eventLoop):
                self.locked.connection = .scheduleTimeoutTimer(timeoutID, on: eventLoop)
                self.unlocked.connection = .createConnection(newConnectionID, on: eventLoop)
            case .cancelTimeoutTimer(let connectionID):
                self.locked.connection = .cancelTimeoutTimer(connectionID)
            case .createConnectionAndCancelTimeoutTimer(let createdID, on: let eventLoop, cancelTimerID: let cancelID):
                self.unlocked.connection = .createConnection(createdID, on: eventLoop)
                self.locked.connection = .cancelTimeoutTimer(cancelID)
            case .closeConnection(let connection, let isShutdown):
                self.unlocked.connection = .closeConnection(connection, isShutdown: isShutdown)
            case .closeConnectionAndCreateConnection(
                let closeConnection,
                let newConnectionID,
                let eventLoop
            ):
                self.unlocked.connection = .closeConnectionAndCreateConnection(
                    close: closeConnection,
                    newConnectionID: newConnectionID,
                    on: eventLoop
                )
            case .cleanupConnections(var cleanupContext, let isShutdown):
                self.locked.connection = .cancelBackoffTimers(cleanupContext.connectBackoff)
                cleanupContext.connectBackoff = []
                self.unlocked.connection = .cleanupConnections(cleanupContext, isShutdown: isShutdown)
            case .migration(
                let createConnections,
                let closeConnections,
                let scheduleTimeout
            ):
                if let (connectionID, eventLoop) = scheduleTimeout {
                    self.locked.connection = .scheduleTimeoutTimer(connectionID, on: eventLoop)
                }
                self.unlocked.connection = .migration(
                    createConnections: createConnections,
                    closeConnections: closeConnections
                )
            case .none:
                break
            }
        }
    }

    // MARK: Run actions

    private func modifyStateAndRunActions(_ closure: (inout StateMachine) -> StateMachine.Action) {
        let unlockedActions = self.stateLock.withLock { () -> Actions.Unlocked in
            let stateMachineAction = closure(&self._state)
            let poolAction = Actions(from: stateMachineAction)
            self.runLockedConnectionAction(poolAction.locked.connection)
            self.runLockedRequestAction(poolAction.locked.request)
            return poolAction.unlocked
        }
        self.runUnlockedActions(unlockedActions)
    }

    private func runLockedConnectionAction(_ action: Actions.ConnectionAction.Locked) {
        switch action {
        case .scheduleBackoffTimer(let connectionID, let backoff, on: let eventLoop):
            self.scheduleConnectionStartBackoffTimer(connectionID, backoff, on: eventLoop)

        case .scheduleTimeoutTimer(let connectionID, on: let eventLoop):
            self.scheduleIdleTimerForConnection(connectionID, on: eventLoop)

        case .cancelTimeoutTimer(let connectionID):
            self.cancelIdleTimerForConnection(connectionID)

        case .cancelBackoffTimers(let connectionIDs):
            for connectionID in connectionIDs {
                self.cancelConnectionStartBackoffTimer(connectionID)
            }

        case .none:
            break
        }
    }

    private func runLockedRequestAction(_ action: Actions.RequestAction.Locked) {
        switch action {
        case .scheduleRequestTimeout(for: let request, on: let eventLoop):
            self.scheduleRequestTimeout(request, on: eventLoop)

        case .cancelRequestTimeout(let requestID):
            self.cancelRequestTimeout(requestID)

        case .cancelRequestTimeouts(let requests):
            for request in requests { self.cancelRequestTimeout(request.id) }

        case .none:
            break
        }
    }

    private func runUnlockedActions(_ actions: Actions.Unlocked) {
        self.runUnlockedConnectionAction(actions.connection)
        self.runUnlockedRequestAction(actions.request)
    }

    private func runUnlockedConnectionAction(_ action: Actions.ConnectionAction.Unlocked) {
        switch action {
        case .createConnection(let connectionID, let eventLoop):
            self.createConnection(connectionID, on: eventLoop)

        case .closeConnection(let connection, let isShutdown):
            self.logger.trace(
                "close connection",
                metadata: [
                    "ahc-connection-id": "\(connection.id)"
                ]
            )

            // we are not interested in the close promise...
            connection.close(promise: nil)

            if case .yes(let unclean) = isShutdown {
                self.delegate.connectionPoolDidShutdown(self, unclean: unclean)
            }

        case .closeConnectionAndCreateConnection(
            let connectionToClose,
            let newConnectionID,
            let eventLoop
        ):
            self.logger.trace(
                "closing and creating connection",
                metadata: [
                    "ahc-connection-id": "\(connectionToClose.id)"
                ]
            )

            self.createConnection(newConnectionID, on: eventLoop)

            // we are not interested in the close promise...
            connectionToClose.close(promise: nil)

        case .cleanupConnections(let cleanupContext, let isShutdown):
            for connection in cleanupContext.close {
                connection.close(promise: nil)
            }

            for connection in cleanupContext.cancel {
                connection.shutdown()
            }

            for connectionID in cleanupContext.connectBackoff {
                self.cancelConnectionStartBackoffTimer(connectionID)
            }

            if case .yes(let unclean) = isShutdown {
                self.delegate.connectionPoolDidShutdown(self, unclean: unclean)
            }

        case .migration(let createConnections, let closeConnections):
            for connection in closeConnections {
                connection.close(promise: nil)
            }

            for (connectionID, eventLoop) in createConnections {
                self.createConnection(connectionID, on: eventLoop)
            }

        case .none:
            break
        }
    }

    private func runUnlockedRequestAction(_ action: Actions.RequestAction.Unlocked) {
        switch action {
        case .executeRequest(let request, let connection):
            connection.executeRequest(request.req)

        case .executeRequests(let requests, let connection):
            for request in requests {
                connection.executeRequest(request.req)
            }

        case .failRequest(let request, let error):
            request.req.fail(error)

        case .failRequests(let requests, let error):
            for request in requests { request.req.fail(error) }

        case .none:
            break
        }
    }

    private func createConnection(_ connectionID: Connection.ID, on eventLoop: EventLoop) {
        self.logger.trace(
            "Opening fresh connection",
            metadata: [
                "ahc-connection-id": "\(connectionID)"
            ]
        )
        // Even though this function is called make it actually creates/establishes a connection.
        // TBD: Should we rename it? To what?
        self.connectionFactory.makeConnection(
            for: self,
            connectionID: connectionID,
            http1ConnectionDelegate: self,
            http2ConnectionDelegate: self,
            deadline: .now() + (self.clientConfiguration.timeout.connect ?? Self.fallbackConnectTimeout),
            eventLoop: eventLoop,
            logger: self.logger
        )
    }

    private func scheduleRequestTimeout(_ request: Request, on eventLoop: EventLoop) {
        let requestID = request.id
        let scheduled = eventLoop.scheduleTask(deadline: request.connectionDeadline) {
            // there might be a race between a the timeout timer and the pool scheduling the
            // request on another thread.
            self.modifyStateAndRunActions { stateMachine in
                if self._requestTimer.removeValue(forKey: requestID) != nil {
                    // The timer still exists. State Machines assumes it is alive. Inform state
                    // machine.
                    return stateMachine.timeoutRequest(requestID)
                }
                return .none
            }
        }

        assert(self._requestTimer[requestID] == nil)
        self._requestTimer[requestID] = scheduled

        request.req.requestWasQueued(self)
    }

    private func cancelRequestTimeout(_ id: Request.ID) {
        guard let cancelTimer = self._requestTimer.removeValue(forKey: id) else {
            preconditionFailure("Expected to have a timer for request \(id) at this point.")
        }
        cancelTimer.cancel()
    }

    private func scheduleIdleTimerForConnection(_ connectionID: Connection.ID, on eventLoop: EventLoop) {
        self.logger.trace(
            "Schedule idle connection timeout timer",
            metadata: [
                "ahc-connection-id": "\(connectionID)"
            ]
        )
        let scheduled = eventLoop.scheduleTask(in: self.idleConnectionTimeout) {
            // there might be a race between a cancelTimer call and the triggering
            // of this scheduled task. both want to acquire the lock
            self.modifyStateAndRunActions { stateMachine in
                if self._idleTimer.removeValue(forKey: connectionID) != nil {
                    // The timer still exists. State Machines assumes it is alive
                    return stateMachine.connectionIdleTimeout(connectionID, on: eventLoop)
                }
                return .none
            }
        }

        assert(self._idleTimer[connectionID] == nil)
        self._idleTimer[connectionID] = scheduled
    }

    private func cancelIdleTimerForConnection(_ connectionID: Connection.ID) {
        self.logger.trace(
            "Cancel idle connection timeout timer",
            metadata: [
                "ahc-connection-id": "\(connectionID)"
            ]
        )
        guard let cancelTimer = self._idleTimer.removeValue(forKey: connectionID) else {
            preconditionFailure("Expected to have an idle timer for connection \(connectionID) at this point.")
        }
        cancelTimer.cancel()
    }

    private func scheduleConnectionStartBackoffTimer(
        _ connectionID: Connection.ID,
        _ timeAmount: TimeAmount,
        on eventLoop: EventLoop
    ) {
        self.logger.trace(
            "Schedule connection creation backoff timer",
            metadata: [
                "ahc-connection-id": "\(connectionID)"
            ]
        )

        let scheduled = eventLoop.scheduleTask(in: timeAmount) {
            // there might be a race between a backoffTimer and the pool shutting down.
            self.modifyStateAndRunActions { stateMachine in
                if self._backoffTimer.removeValue(forKey: connectionID) != nil {
                    // The timer still exists. State Machines assumes it is alive
                    return stateMachine.connectionCreationBackoffDone(connectionID)
                }
                return .none
            }
        }

        assert(self._backoffTimer[connectionID] == nil)
        self._backoffTimer[connectionID] = scheduled
    }

    private func cancelConnectionStartBackoffTimer(_ connectionID: Connection.ID) {
        guard let backoffTimer = self._backoffTimer.removeValue(forKey: connectionID) else {
            preconditionFailure("Expected to have a backoff timer for connection \(connectionID) at this point.")
        }
        backoffTimer.cancel()
    }
}

// MARK: - Protocol methods -

extension HTTPConnectionPool: HTTPConnectionRequester {
    func http1ConnectionCreated(_ connection: HTTP1Connection.SendableView) {
        self.logger.trace(
            "successfully created connection",
            metadata: [
                "ahc-connection-id": "\(connection.id)",
                "ahc-http-version": "http/1.1",
            ]
        )
        self.modifyStateAndRunActions {
            $0.newHTTP1ConnectionCreated(.http1_1(connection))
        }
    }

    func http2ConnectionCreated(_ connection: HTTP2Connection.SendableView, maximumStreams: Int) {
        self.logger.trace(
            "successfully created connection",
            metadata: [
                "ahc-connection-id": "\(connection.id)",
                "ahc-http-version": "http/2",
                "ahc-max-streams": "\(maximumStreams)",
            ]
        )
        self.modifyStateAndRunActions {
            $0.newHTTP2ConnectionCreated(.http2(connection), maxConcurrentStreams: maximumStreams)
        }
    }

    func failedToCreateHTTPConnection(_ connectionID: HTTPConnectionPool.Connection.ID, error: Error) {
        self.logger.debug(
            "connection attempt failed",
            metadata: [
                "ahc-error": "\(error)",
                "ahc-connection-id": "\(connectionID)",
            ]
        )
        self.modifyStateAndRunActions {
            $0.failedToCreateNewConnection(error, connectionID: connectionID)
        }
    }

    func waitingForConnectivity(_ connectionID: HTTPConnectionPool.Connection.ID, error: Error) {
        self.logger.debug(
            "waiting for connectivity",
            metadata: [
                "ahc-error": "\(error)",
                "ahc-connection-id": "\(connectionID)",
            ]
        )
        self.modifyStateAndRunActions {
            $0.waitingForConnectivity(error, connectionID: connectionID)
        }
    }
}

extension HTTPConnectionPool: HTTP1ConnectionDelegate {
    func http1ConnectionClosed(_ id: HTTPConnectionPool.Connection.ID) {
        self.logger.debug(
            "connection closed",
            metadata: [
                "ahc-connection-id": "\(id)",
                "ahc-http-version": "http/1.1",
            ]
        )
        self.modifyStateAndRunActions {
            $0.http1ConnectionClosed(id)
        }
    }

    func http1ConnectionReleased(_ id: HTTPConnectionPool.Connection.ID) {
        self.logger.trace(
            "releasing connection",
            metadata: [
                "ahc-connection-id": "\(id)",
                "ahc-http-version": "http/1.1",
            ]
        )
        self.modifyStateAndRunActions {
            $0.http1ConnectionReleased(id)
        }
    }
}

extension HTTPConnectionPool: HTTP2ConnectionDelegate {
    func http2Connection(_ id: HTTPConnectionPool.Connection.ID, newMaxStreamSetting: Int) {
        self.logger.debug(
            "new max stream setting",
            metadata: [
                "ahc-connection-id": "\(id)",
                "ahc-http-version": "http/2",
                "ahc-max-streams": "\(newMaxStreamSetting)",
            ]
        )
        self.modifyStateAndRunActions {
            $0.newHTTP2MaxConcurrentStreamsReceived(id, newMaxStreams: newMaxStreamSetting)
        }
    }

    func http2ConnectionGoAwayReceived(_ id: HTTPConnectionPool.Connection.ID) {
        self.logger.debug(
            "connection go away received",
            metadata: [
                "ahc-connection-id": "\(id)",
                "ahc-http-version": "http/2",
            ]
        )
        self.modifyStateAndRunActions {
            $0.http2ConnectionGoAwayReceived(id)
        }
    }

    func http2ConnectionClosed(_ id: HTTPConnectionPool.Connection.ID) {
        self.logger.debug(
            "connection closed",
            metadata: [
                "ahc-connection-id": "\(id)",
                "ahc-http-version": "http/2",
            ]
        )
        self.modifyStateAndRunActions {
            $0.http2ConnectionClosed(id)
        }
    }

    func http2ConnectionStreamClosed(_ id: HTTPConnectionPool.Connection.ID, availableStreams: Int) {
        self.logger.trace(
            "stream closed",
            metadata: [
                "ahc-connection-id": "\(id)",
                "ahc-http-version": "http/2",
            ]
        )
        self.modifyStateAndRunActions {
            $0.http2ConnectionStreamClosed(id)
        }
    }
}

extension HTTPConnectionPool: HTTPRequestScheduler {
    func cancelRequest(_ request: HTTPSchedulableRequest) {
        let requestID = Request(request).id
        self.modifyStateAndRunActions {
            $0.cancelRequest(requestID)
        }
    }
}

extension HTTPConnectionPool {
    struct Connection: Hashable {
        typealias ID = Int

        private enum Reference {
            case http1_1(HTTP1Connection.SendableView)
            case http2(HTTP2Connection.SendableView)
            case __testOnly_connection(ID, EventLoop)
        }

        private let _ref: Reference

        fileprivate static func http1_1(_ conn: HTTP1Connection.SendableView) -> Self {
            Connection(_ref: .http1_1(conn))
        }

        fileprivate static func http2(_ conn: HTTP2Connection.SendableView) -> Self {
            Connection(_ref: .http2(conn))
        }

        static func __testOnly_connection(id: ID, eventLoop: EventLoop) -> Self {
            Connection(_ref: .__testOnly_connection(id, eventLoop))
        }

        var id: ID {
            switch self._ref {
            case .http1_1(let connection):
                return connection.id
            case .http2(let connection):
                return connection.id
            case .__testOnly_connection(let id, _):
                return id
            }
        }

        var eventLoop: EventLoop {
            switch self._ref {
            case .http1_1(let connection):
                return connection.channel.eventLoop
            case .http2(let connection):
                return connection.channel.eventLoop
            case .__testOnly_connection(_, let eventLoop):
                return eventLoop
            }
        }

        fileprivate func executeRequest(_ request: HTTPExecutableRequest) {
            switch self._ref {
            case .http1_1(let connection):
                return connection.executeRequest(request)
            case .http2(let connection):
                return connection.executeRequest(request)
            case .__testOnly_connection:
                break
            }
        }

        /// Shutdown cancels any running requests on the connection and then closes the connection
        fileprivate func shutdown() {
            switch self._ref {
            case .http1_1(let connection):
                return connection.shutdown()
            case .http2(let connection):
                return connection.shutdown()
            case .__testOnly_connection:
                break
            }
        }

        /// Closes the connection without cancelling running requests. Use this when you are sure, that the
        /// connection is currently idle.
        fileprivate func close(promise: EventLoopPromise<Void>?) {
            switch self._ref {
            case .http1_1(let connection):
                return connection.close(promise: promise)
            case .http2(let connection):
                return connection.close(promise: promise)
            case .__testOnly_connection:
                promise?.succeed(())
            }
        }

        static func == (lhs: HTTPConnectionPool.Connection, rhs: HTTPConnectionPool.Connection) -> Bool {
            switch (lhs._ref, rhs._ref) {
            case (.http1_1(let lhsConn), .http1_1(let rhsConn)):
                return lhsConn.id == rhsConn.id
            case (.http2(let lhsConn), .http2(let rhsConn)):
                return lhsConn.id == rhsConn.id
            case (
                .__testOnly_connection(let lhsID, let lhsEventLoop), .__testOnly_connection(let rhsID, let rhsEventLoop)
            ):
                return lhsID == rhsID && lhsEventLoop === rhsEventLoop
            default:
                return false
            }
        }

        func hash(into hasher: inout Hasher) {
            switch self._ref {
            case .http1_1(let conn):
                hasher.combine(conn.id)
            case .http2(let conn):
                hasher.combine(conn.id)
            case .__testOnly_connection(let id, let eventLoop):
                hasher.combine(id)
                hasher.combine(eventLoop.id)
            }
        }
    }
}

extension HTTPConnectionPool {
    /// This is a wrapper that we use inside the connection pool state machine to ensure that
    /// the actual request can not be accessed at any time. Further it exposes all that is needed within
    /// the state machine. A request ID and the `EventLoop` requirement.
    struct Request {
        struct ID: Hashable {
            let objectIdentifier: ObjectIdentifier
            let eventLoopID: EventLoopID?

            fileprivate init(_ request: HTTPSchedulableRequest, eventLoopRequirement eventLoopID: EventLoopID?) {
                self.objectIdentifier = ObjectIdentifier(request)
                self.eventLoopID = eventLoopID
            }
        }

        fileprivate let req: HTTPSchedulableRequest

        init(_ request: HTTPSchedulableRequest) {
            self.req = request
        }

        var id: HTTPConnectionPool.Request.ID {
            HTTPConnectionPool.Request.ID(self.req, eventLoopRequirement: self.requiredEventLoop?.id)
        }

        var requiredEventLoop: EventLoop? {
            self.req.requiredEventLoop
        }

        var preferredEventLoop: EventLoop {
            self.req.preferredEventLoop
        }

        var connectionDeadline: NIODeadline {
            self.req.connectionDeadline
        }

        func __testOnly_wrapped_request() -> HTTPSchedulableRequest {
            self.req
        }
    }
}

struct EventLoopID: Hashable {
    private var id: Identifier

    private enum Identifier: Hashable {
        case objectIdentifier(ObjectIdentifier)
        case __testOnly_fakeID(Int)
    }

    init(_ eventLoop: EventLoop) {
        self.init(.objectIdentifier(ObjectIdentifier(eventLoop)))
    }

    private init(_ id: Identifier) {
        self.id = id
    }

    static func __testOnly_fakeID(_ id: Int) -> EventLoopID {
        EventLoopID(.__testOnly_fakeID(id))
    }
}

extension EventLoop {
    var id: EventLoopID { EventLoopID(self) }
}
