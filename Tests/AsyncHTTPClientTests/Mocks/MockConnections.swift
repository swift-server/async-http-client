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

@testable import AsyncHTTPClient
import Logging
import NIO
import NIOHTTP1

struct MockConnections {
    typealias Connection = HTTPConnectionPool.Connection

    enum Errors: Error {
        case connectionIDAlreadyUsed
        case connectionNotFound
        case connectionNotIdle
        case connectionAlreadyParked
        case connectionNotParked
        case connectionIsParked
        case connectionIsClosed
        case connectionIsNotStarting
        case connectionIsNotExecuting
        case connectionDoesNotFulFillEventLoopRequirement
    }

    private struct MockConnection {
        typealias ID = HTTPConnectionPool.Connection.ID

        enum State {
            case starting
            case http1(leased: Bool, lastReturn: NIODeadline)
            case http2(streams: Int, used: Int)
            case closed
        }

        let id: ID
        let eventLoop: EventLoop

        private(set) var state: State = .starting
        private(set) var isParked: Bool = false

        init(id: ID, eventLoop: EventLoop) {
            self.id = id
            self.eventLoop = eventLoop
        }

        var isStarting: Bool {
            switch self.state {
            case .starting:
                return true
            default:
                return false
            }
        }

        var isIdle: Bool {
            switch self.state {
            case .starting:
                return false
            case .http1(let leased, _):
                return !leased
            case .http2(_, let used):
                return used == 0
            case .closed:
                return false
            }
        }

        var isLeased: Bool {
            switch self.state {
            case .starting:
                return false
            case .http1(let leased, _):
                return leased
            case .http2(_, let used):
                return used > 0
            case .closed:
                return false
            }
        }

        var lastReturned: NIODeadline? {
            switch self.state {
            case .starting:
                return nil
            case .http1(_, let lastReturn):
                return lastReturn
            case .http2:
                return nil
            case .closed:
                return nil
            }
        }

        mutating func http1Started() throws {
            guard case .starting = self.state else {
                throw Errors.connectionIsNotStarting
            }

            self.state = .http1(leased: false, lastReturn: .now())
        }

        mutating func park() throws {
            guard self.isIdle else {
                throw Errors.connectionNotIdle
            }

            guard !self.isParked else {
                throw Errors.connectionAlreadyParked
            }

            self.isParked = true
        }

        mutating func activate() throws {
            guard self.isIdle else {
                throw Errors.connectionNotIdle
            }

            guard self.isParked else {
                throw Errors.connectionNotParked
            }

            self.isParked = false
        }

        mutating func execute(_ request: HTTPRequestTask) throws {
            guard !self.isParked else {
                throw Errors.connectionIsParked
            }

            switch request.eventLoopPreference.preference {
            case .indifferent, .delegate:
                break
            case .delegateAndChannel(on: let required), .testOnly_exact(channelOn: let required, _):
                if required !== self.eventLoop {
                    throw Errors.connectionDoesNotFulFillEventLoopRequirement
                }
            }

            switch self.state {
            case .starting:
                preconditionFailure("Should be unreachable")
            case .http1(leased: true, _):
                throw Errors.connectionNotIdle
            case .http1(leased: false, let lastReturn):
                self.state = .http1(leased: true, lastReturn: lastReturn)
            case .http2(let streams, let used) where used >= streams:
                throw Errors.connectionNotIdle
            case .http2(let streams, var used):
                used += 1
                self.state = .http2(streams: streams, used: used)
            case .closed:
                throw Errors.connectionIsClosed
            }
        }

        mutating func finishRequest() throws {
            guard !self.isParked else {
                throw Errors.connectionIsParked
            }

            switch self.state {
            case .starting:
                throw Errors.connectionIsNotExecuting
            case .http1(leased: true, _):
                self.state = .http1(leased: false, lastReturn: .now())
            case .http1(leased: false, _):
                throw Errors.connectionIsNotExecuting
            case .http2(_, let used) where used <= 0:
                throw Errors.connectionIsNotExecuting
            case .http2(let streams, var used):
                used -= 1
                self.state = .http2(streams: streams, used: used)
            case .closed:
                throw Errors.connectionIsClosed
            }
        }

        mutating func close() throws {
            switch self.state {
            case .starting:
                throw Errors.connectionNotIdle
            case .http1(let leased, _):
                if leased {
                    throw Errors.connectionNotIdle
                }
            case .http2(_, let used):
                if used > 0 {
                    throw Errors.connectionNotIdle
                }
            case .closed:
                throw Errors.connectionIsClosed
            }
        }
    }

    private var connections = [MockConnection.ID: MockConnection]()

    init() {}

    var parked: Int {
        self.connections.values.filter { $0.isParked }.count
    }

    var leased: Int {
        self.connections.values.filter { $0.isLeased }.count
    }

    var starting: Int {
        self.connections.values.filter { $0.isStarting }.count
    }

    var count: Int {
        self.connections.count
    }

    var isEmpty: Bool {
        self.connections.isEmpty
    }

    var newestParkedConnection: HTTPConnectionPool.Connection? {
        self.connections.values
            .filter { $0.isParked }
            .sorted(by: { $0.lastReturned! > $1.lastReturned! })
            .first
            .flatMap { .testing(id: $0.id, eventLoop: $0.eventLoop) }
    }

    var oldestParkedConnection: HTTPConnectionPool.Connection? {
        self.connections.values
            .filter { $0.isParked }
            .sorted(by: { $0.lastReturned! < $1.lastReturned! })
            .first
            .flatMap { .testing(id: $0.id, eventLoop: $0.eventLoop) }
    }

    func newestParkedConnection(for eventLoop: EventLoop) -> HTTPConnectionPool.Connection? {
        self.connections.values
            .filter { $0.eventLoop === eventLoop && $0.isParked }
            .sorted(by: { $0.lastReturned! > $1.lastReturned! })
            .first
            .flatMap { .testing(id: $0.id, eventLoop: $0.eventLoop) }
    }

    func connections(on eventLoop: EventLoop) -> Int {
        self.connections.values.filter { $0.eventLoop === eventLoop }.count
    }

    mutating func createConnection(_ connectionID: Connection.ID, on eventLoop: EventLoop) throws {
        guard self.connections[connectionID] == nil else {
            throw Errors.connectionIDAlreadyUsed
        }
        self.connections[connectionID] = .init(id: connectionID, eventLoop: eventLoop)
    }

    /// Closing a connection signals intend. For this reason, it is verified, that the connection is not running any
    /// requests when closing.
    mutating func closeConnection(_ connection: Connection) throws {
        guard var mockConnection = self.connections.removeValue(forKey: connection.id) else {
            throw Errors.connectionNotFound
        }

        try mockConnection.close()
    }

    /// Aborting a connection does not verify if the connection does anything right now
    mutating func abortConnection(_ connectionID: Connection.ID) throws {
        guard self.connections.removeValue(forKey: connectionID) != nil else {
            throw Errors.connectionNotFound
        }
    }

    mutating func succeedConnectionCreationHTTP1(_ connectionID: Connection.ID) throws -> HTTPConnectionPool.Connection {
        guard var connection = self.connections[connectionID] else {
            throw Errors.connectionNotFound
        }

        try connection.http1Started()
        self.connections[connection.id] = connection
        return .testing(id: connection.id, eventLoop: connection.eventLoop)
    }

    mutating func failConnectionCreation(_ connectionID: Connection.ID) throws {
        guard let connection = self.connections[connectionID] else {
            throw Errors.connectionNotFound
        }

        guard connection.isStarting else {
            throw Errors.connectionIsNotStarting
        }

        self.connections[connection.id] = nil
    }

    mutating func parkConnection(_ connectionID: Connection.ID) throws {
        guard var connection = self.connections[connectionID] else {
            throw Errors.connectionNotFound
        }

        try connection.park()
        self.connections[connectionID] = connection
    }

    mutating func activateConnection(_ connectionID: Connection.ID) throws {
        guard var connection = self.connections[connectionID] else {
            throw Errors.connectionNotFound
        }

        try connection.activate()
        self.connections[connectionID] = connection
    }

    mutating func execute(_ request: HTTPRequestTask, on connection: Connection) throws {
        guard var connection = self.connections[connection.id] else {
            throw Errors.connectionNotFound
        }

        try connection.execute(request)
        self.connections[connection.id] = connection
    }

    mutating func finishExecution(_ connectionID: Connection.ID) throws {
        guard var connection = self.connections[connectionID] else {
            throw Errors.connectionNotFound
        }

        try connection.finishRequest()
        self.connections[connectionID] = connection
    }

    mutating func randomStartingConnection() -> HTTPConnectionPool.Connection.ID? {
        self.connections.values
            .filter { $0.isStarting }
            .randomElement()
            .map(\.id)
    }

    mutating func randomParkedConnection() -> HTTPConnectionPool.Connection? {
        self.connections.values
            .filter { $0.isParked }
            .randomElement()
            .flatMap { .testing(id: $0.id, eventLoop: $0.eventLoop) }
    }

    mutating func randomLeasedConnection() -> HTTPConnectionPool.Connection? {
        self.connections.values
            .filter { $0.isLeased }
            .randomElement()
            .flatMap { .testing(id: $0.id, eventLoop: $0.eventLoop) }
    }

    enum SetupError: Error {
        case totalNumberOfConnectionsMustBeLowerThanIdle
        case expectedConnectionToBeCreated
        case expectedTaskToBeAddedToWaiters
        case expectedPreviouslyWaitedTaskToBeRunNow
        case expectedNoConnectionAction
        case expectedConnectionToBeParked
    }

    static func http1(
        elg: EventLoopGroup,
        on eventLoop: EventLoop? = nil,
        numberOfConnections: Int,
        maxNumberOfConnections: Int = 8
    ) throws -> (Self, HTTPConnectionPool.StateMachine) {
        var state = HTTPConnectionPool.StateMachine(
            eventLoopGroup: elg,
            idGenerator: .init(),
            maximumConcurrentHTTP1Connections: maxNumberOfConnections
        )
        var connections = MockConnections()
        var waiters = MockWaiters()

        for _ in 0..<numberOfConnections {
            let mockTask = MockHTTPRequestTask(eventLoop: eventLoop ?? elg.next())
            let action = state.executeTask(mockTask, onPreffered: mockTask.eventLoop, required: false)

            guard case .scheduleWaiterTimeout(let waiterID, let taskToWait, on: let waitEL) = action.task,
                taskToWait === mockTask,
                mockTask.eventLoop === waitEL else {
                throw SetupError.expectedTaskToBeAddedToWaiters
            }

            guard case .createConnection(let connectionID, on: let eventLoop) = action.connection else {
                throw SetupError.expectedConnectionToBeCreated
            }

            try connections.createConnection(connectionID, on: eventLoop)
            try waiters.wait(mockTask, id: waiterID)
        }

        while let connectionID = connections.randomStartingConnection() {
            let newConnection = try connections.succeedConnectionCreationHTTP1(connectionID)
            let action = state.newHTTP1ConnectionCreated(newConnection)

            guard case .executeTask(let mockTask, newConnection, cancelWaiter: .some(let waiterID)) = action.task else {
                throw SetupError.expectedPreviouslyWaitedTaskToBeRunNow
            }

            guard case .none = action.connection else {
                throw SetupError.expectedNoConnectionAction
            }

            let task = try waiters.get(waiterID, task: mockTask)
            try connections.execute(task, on: newConnection)
            try connections.finishExecution(connectionID)

            guard state.http1ConnectionReleased(connectionID) == .init(.none, .scheduleTimeoutTimer(connectionID)) else {
                throw SetupError.expectedConnectionToBeParked
            }

            try connections.parkConnection(connectionID)
        }

        return (connections, state)
    }
}

struct MockWaiters {
    enum Errors: Error {
        case waiterIDNotFound
        case waiterIDAlreadyUsed
        case waiterIDDoesNotMatchTask
    }

    struct Waiter {
        typealias ID = HTTPConnectionPool.Waiter.ID

        let id: ID
        let request: HTTPRequestTask
    }

    init() {
        self.waiters = [:]
    }

    private(set) var waiters: [Waiter.ID: Waiter]

    var count: Int {
        self.waiters.count
    }

    var isEmpty: Bool {
        self.waiters.isEmpty
    }

    mutating func wait(_ request: HTTPRequestTask, id: Waiter.ID) throws {
        guard self.waiters[id] == nil else {
            throw Errors.waiterIDAlreadyUsed
        }

        self.waiters[id] = Waiter(id: id, request: request)
    }

    mutating func fail(_ id: Waiter.ID, task: HTTPRequestTask) throws {
        guard let waiter = self.waiters.removeValue(forKey: id) else {
            throw Errors.waiterIDNotFound
        }
        guard waiter.request === task else {
            throw Errors.waiterIDDoesNotMatchTask
        }
    }

    mutating func get(_ id: Waiter.ID, task: HTTPRequestTask) throws -> HTTPRequestTask {
        guard let waiter = self.waiters.removeValue(forKey: id) else {
            throw Errors.waiterIDNotFound
        }
        guard waiter.request === task else {
            throw Errors.waiterIDDoesNotMatchTask
        }
        return waiter.request
    }
}

class MockHTTPRequestTask: HTTPRequestTask {
    let eventLoopPreference: HTTPClient.EventLoopPreference
    let logger: Logger
    let connectionDeadline: NIODeadline
    let idleReadTimeout: TimeAmount?

    init(eventLoop: EventLoop,
         logger: Logger = Logger(label: "mock"),
         connectionTimeout: TimeAmount = .seconds(60),
         idleReadTimeout: TimeAmount? = nil,
         requiresEventLoopForChannel: Bool = false) {
        self.logger = logger

        self.connectionDeadline = .now() + connectionTimeout
        self.idleReadTimeout = idleReadTimeout

        if requiresEventLoopForChannel {
            self.eventLoopPreference = .delegateAndChannel(on: eventLoop)
        } else {
            self.eventLoopPreference = .delegate(on: eventLoop)
        }
    }

    var eventLoop: EventLoop {
        switch self.eventLoopPreference.preference {
        case .indifferent, .testOnly_exact:
            preconditionFailure("Unimplemented")
        case .delegate(on: let eventLoop), .delegateAndChannel(on: let eventLoop):
            return eventLoop
        }
    }

    func requestWasQueued(_: HTTP1RequestQueuer) {
        preconditionFailure("Unimplemented")
    }

    func willBeExecutedOnConnection(_: HTTPConnectionPool.Connection) {
        preconditionFailure("Unimplemented")
    }

    func willExecuteRequest(_: HTTP1RequestExecutor) -> Bool {
        preconditionFailure("Unimplemented")
    }

    func requestHeadSent(_: HTTPRequestHead) {
        preconditionFailure("Unimplemented")
    }

    func startRequestBodyStream() {
        preconditionFailure("Unimplemented")
    }

    func pauseRequestBodyStream() {
        preconditionFailure("Unimplemented")
    }

    func resumeRequestBodyStream() {
        preconditionFailure("Unimplemented")
    }

    var request: HTTPClient.Request {
        preconditionFailure("Unimplemented")
    }

    func nextRequestBodyPart(channelEL: EventLoop) -> EventLoopFuture<IOData?> {
        preconditionFailure("Unimplemented")
    }

    func didSendRequestHead(_: HTTPRequestHead) {
        preconditionFailure("Unimplemented")
    }

    func didSendRequestPart(_: IOData) {
        preconditionFailure("Unimplemented")
    }

    func didSendRequest() {
        preconditionFailure("Unimplemented")
    }

    func receiveResponseHead(_: HTTPResponseHead) {
        preconditionFailure("Unimplemented")
    }

    func receiveResponseBodyPart(_: ByteBuffer) {
        preconditionFailure("Unimplemented")
    }

    func receiveResponseEnd() {
        preconditionFailure("Unimplemented")
    }

    func fail(_: Error) {
        preconditionFailure("Unimplemented")
    }
}
