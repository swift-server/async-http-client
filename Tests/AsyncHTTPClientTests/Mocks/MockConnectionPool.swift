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

/// A mock connection pool (not creating any actual connections) that is used to validate
/// connection actions returned by the `HTTPConnectionPool.StateMachine`.
struct MockConnectionPool {
    typealias Connection = HTTPConnectionPool.Connection

    enum Errors: Error {
        case connectionIDAlreadyUsed
        case connectionNotFound
        case connectionExists
        case connectionNotIdle
        case connectionAlreadyParked
        case connectionNotParked
        case connectionIsParked
        case connectionIsClosed
        case connectionIsNotStarting
        case connectionIsNotExecuting
        case connectionDoesNotFulfillEventLoopRequirement
        case connectionBackoffTimerExists
        case connectionBackoffTimerNotFound
    }

    private struct MockConnectionState {
        typealias ID = HTTPConnectionPool.Connection.ID

        enum State {
            case starting
            case http1(leased: Bool, lastIdle: NIODeadline)
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
            case .starting, .closed:
                return false
            case .http1(let leased, _):
                return !leased
            case .http2(_, let used):
                return used == 0
            }
        }

        var isLeased: Bool {
            switch self.state {
            case .starting, .closed:
                return false
            case .http1(let leased, _):
                return leased
            case .http2(_, let used):
                return used > 0
            }
        }

        var lastIdle: NIODeadline? {
            switch self.state {
            case .starting, .closed:
                return nil
            case .http1(_, let lastReturn):
                return lastReturn
            case .http2:
                return nil
            }
        }

        mutating func http1Started() throws {
            guard case .starting = self.state else {
                throw Errors.connectionIsNotStarting
            }

            self.state = .http1(leased: false, lastIdle: .now())
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

        mutating func execute(_ request: HTTPSchedulableRequest) throws {
            guard !self.isParked else {
                throw Errors.connectionIsParked
            }

            if let required = request.requiredEventLoop, required !== self.eventLoop {
                throw Errors.connectionDoesNotFulfillEventLoopRequirement
            }

            switch self.state {
            case .starting:
                preconditionFailure("Should be unreachable")
            case .http1(leased: true, _):
                throw Errors.connectionNotIdle
            case .http1(leased: false, let lastIdle):
                self.state = .http1(leased: true, lastIdle: lastIdle)
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
                self.state = .http1(leased: false, lastIdle: .now())
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

    private var connections = [Connection.ID: MockConnectionState]()
    private var backoff = Set<Connection.ID>()

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

    var newestParkedConnection: Connection? {
        self.connections.values
            .filter { $0.isParked }
            .max(by: { $0.lastIdle! < $1.lastIdle! })
            .flatMap { .__testOnly_connection(id: $0.id, eventLoop: $0.eventLoop) }
    }

    var oldestParkedConnection: Connection? {
        self.connections.values
            .filter { $0.isParked }
            .min(by: { $0.lastIdle! < $1.lastIdle! })
            .flatMap { .__testOnly_connection(id: $0.id, eventLoop: $0.eventLoop) }
    }

    func newestParkedConnection(for eventLoop: EventLoop) -> Connection? {
        self.connections.values
            .filter { $0.eventLoop === eventLoop && $0.isParked }
            .sorted(by: { $0.lastIdle! > $1.lastIdle! })
            .max(by: { $0.lastIdle! < $1.lastIdle! })
            .flatMap { .__testOnly_connection(id: $0.id, eventLoop: $0.eventLoop) }
    }

    func connections(on eventLoop: EventLoop) -> Int {
        self.connections.values.filter { $0.eventLoop === eventLoop }.count
    }

    // MARK: Connection creation

    mutating func createConnection(_ connectionID: Connection.ID, on eventLoop: EventLoop) throws {
        guard self.connections[connectionID] == nil else {
            throw Errors.connectionIDAlreadyUsed
        }
        self.connections[connectionID] = .init(id: connectionID, eventLoop: eventLoop)
    }

    mutating func succeedConnectionCreationHTTP1(_ connectionID: Connection.ID) throws -> Connection {
        guard var connection = self.connections[connectionID] else {
            throw Errors.connectionNotFound
        }

        try connection.http1Started()
        self.connections[connection.id] = connection
        return .__testOnly_connection(id: connection.id, eventLoop: connection.eventLoop)
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

    mutating func startConnectionBackoffTimer(_ connectionID: Connection.ID) throws {
        guard self.connections[connectionID] == nil else {
            throw Errors.connectionExists
        }

        guard !self.backoff.contains(connectionID) else {
            throw Errors.connectionBackoffTimerExists
        }

        self.backoff.insert(connectionID)
    }

    mutating func connectionBackoffTimerDone(_ connectionID: Connection.ID) throws {
        guard self.backoff.remove(connectionID) != nil else {
            throw Errors.connectionBackoffTimerNotFound
        }
    }

    mutating func cancelConnectionBackoffTimer(_ connectionID: Connection.ID) throws {
        guard self.backoff.remove(connectionID) != nil else {
            throw Errors.connectionBackoffTimerNotFound
        }
    }

    // MARK: Connection destruction

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

    // MARK: Connection usage

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

    mutating func execute(_ request: HTTPSchedulableRequest, on connection: Connection) throws {
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

    mutating func randomStartingConnection() -> Connection.ID? {
        self.connections.values
            .filter { $0.isStarting }
            .randomElement()
            .map(\.id)
    }

    mutating func randomActiveConnection() -> Connection.ID? {
        self.connections.values
            .filter { $0.isLeased || $0.isParked }
            .randomElement()
            .map(\.id)
    }

    mutating func randomParkedConnection() -> Connection? {
        self.connections.values
            .filter { $0.isParked }
            .randomElement()
            .flatMap { .__testOnly_connection(id: $0.id, eventLoop: $0.eventLoop) }
    }

    mutating func randomLeasedConnection() -> Connection? {
        self.connections.values
            .filter { $0.isLeased }
            .randomElement()
            .flatMap { .__testOnly_connection(id: $0.id, eventLoop: $0.eventLoop) }
    }

    func randomBackingOffConnection() -> Connection.ID? {
        self.backoff.randomElement()
    }

    mutating func closeRandomActiveConnection() -> Connection.ID? {
        guard let connectionID = self.randomActiveConnection() else {
            return nil
        }

        self.connections.removeValue(forKey: connectionID)
        return connectionID
    }
}

/// A request that can be used when testing the `HTTPConnectionPool.StateMachine`
/// with the `MockConnectionPool`.
class MockHTTPRequest: HTTPSchedulableRequest {
    let logger: Logger
    let connectionDeadline: NIODeadline
    let idleReadTimeout: TimeAmount?

    let preferredEventLoop: EventLoop
    let requiredEventLoop: EventLoop?

    init(eventLoop: EventLoop,
         logger: Logger = Logger(label: "mock"),
         connectionTimeout: TimeAmount = .seconds(60),
         idleReadTimeout: TimeAmount? = nil,
         requiresEventLoopForChannel: Bool = false) {
        self.logger = logger

        self.connectionDeadline = .now() + connectionTimeout
        self.idleReadTimeout = idleReadTimeout

        self.preferredEventLoop = eventLoop
        if requiresEventLoopForChannel {
            self.requiredEventLoop = eventLoop
        } else {
            self.requiredEventLoop = nil
        }
    }

    var eventLoop: EventLoop {
        return self.preferredEventLoop
    }

    // MARK: HTTPSchedulableRequest

    func requestWasQueued(_: HTTPRequestScheduler) {
        preconditionFailure("Unimplemented")
    }

    func fail(_: Error) {
        preconditionFailure("Unimplemented")
    }

    // MARK: HTTPExecutableRequest

    var requestHead: HTTPRequestHead {
        preconditionFailure("Unimplemented")
    }

    var requestFramingMetadata: RequestFramingMetadata {
        preconditionFailure("Unimplemented")
    }

    func willExecuteRequest(_: HTTPRequestExecutor) {
        preconditionFailure("Unimplemented")
    }

    func requestHeadSent() {
        preconditionFailure("Unimplemented")
    }

    func resumeRequestBodyStream() {
        preconditionFailure("Unimplemented")
    }

    func pauseRequestBodyStream() {
        preconditionFailure("Unimplemented")
    }

    func receiveResponseHead(_: HTTPResponseHead) {
        preconditionFailure("Unimplemented")
    }

    func receiveResponseBodyParts(_: CircularBuffer<ByteBuffer>) {
        preconditionFailure("Unimplemented")
    }

    func succeedRequest(_: CircularBuffer<ByteBuffer>?) {
        preconditionFailure("Unimplemented")
    }
}
