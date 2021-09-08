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

    enum Errors: Error, Hashable {
        case connectionIDAlreadyUsed
        case connectionNotFound
        case connectionExists
        case connectionNotIdle
        case connectionNotParked
        case connectionIsParked
        case connectionIsClosed
        case connectionIsNotStarting
        case connectionIsNotExecuting
        case connectionDoesNotFulfillEventLoopRequirement
        case connectionDoesNotHaveHTTP2StreamAvailable
        case connectionBackoffTimerExists
        case connectionBackoffTimerNotFound
    }

    fileprivate struct MockConnectionState {
        typealias ID = HTTPConnectionPool.Connection.ID

        private enum State {
            enum HTTP1State {
                case inUse
                case idle(parked: Bool, idleSince: NIODeadline)
            }

            enum HTTP2State {
                case inUse(maxConcurrentStreams: Int, used: Int)
                case idle(maxConcurrentStreams: Int, parked: Bool, lastIdle: NIODeadline)
            }

            case starting
            case http1(HTTP1State)
            case http2(HTTP2State)
            case closed
        }

        let id: ID
        let eventLoop: EventLoop

        private var state: State = .starting

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

        /// Is the connection idle (meaning there are no requests executing on it)
        var isIdle: Bool {
            switch self.state {
            case .starting, .closed, .http1(.inUse), .http2(.inUse):
                return false

            case .http1(.idle), .http2(.idle):
                return true
            }
        }

        /// Is the connection available (can another request be executed on it)
        var isAvailable: Bool {
            switch self.state {
            case .starting, .closed, .http1(.inUse):
                return false

            case .http2(.inUse(let maxStreams, let used)):
                return used < maxStreams

            case .http1(.idle), .http2(.idle):
                return true
            }
        }

        /// Is the connection idle and did we create a timeout timer for it?
        var isParked: Bool {
            switch self.state {
            case .starting, .closed, .http1(.inUse), .http2(.inUse):
                return false

            case .http1(.idle(let parked, _)), .http2(.idle(_, let parked, _)):
                return parked
            }
        }

        /// Is the connection in use (are there requests executing on it)
        var isUsed: Bool {
            switch self.state {
            case .starting, .closed, .http1(.idle), .http2(.idle):
                return false

            case .http1(.inUse), .http2(.inUse):
                return true
            }
        }

        var idleSince: NIODeadline? {
            switch self.state {
            case .starting, .closed, .http1(.inUse), .http2(.inUse):
                return nil

            case .http1(.idle(_, let lastIdle)), .http2(.idle(_, _, let lastIdle)):
                return lastIdle
            }
        }

        mutating func http1Started() throws {
            guard case .starting = self.state else {
                throw Errors.connectionIsNotStarting
            }

            self.state = .http1(.idle(parked: false, idleSince: .now()))
        }

        mutating func park() throws {
            switch self.state {
            case .starting, .closed, .http1(.inUse), .http2(.inUse):
                throw Errors.connectionNotIdle

            case .http1(.idle(true, _)), .http2(.idle(_, true, _)):
                throw Errors.connectionIsParked

            case .http1(.idle(false, let lastIdle)):
                self.state = .http1(.idle(parked: true, idleSince: lastIdle))

            case .http2(.idle(let maxStreams, false, let lastIdle)):
                self.state = .http2(.idle(maxConcurrentStreams: maxStreams, parked: true, lastIdle: lastIdle))
            }
        }

        mutating func activate() throws {
            switch self.state {
            case .starting, .closed, .http1(.inUse), .http2(.inUse):
                throw Errors.connectionNotIdle

            case .http1(.idle(false, _)), .http2(.idle(_, false, _)):
                throw Errors.connectionNotParked

            case .http1(.idle(true, let lastIdle)):
                self.state = .http1(.idle(parked: false, idleSince: lastIdle))

            case .http2(.idle(let maxStreams, true, let lastIdle)):
                self.state = .http2(.idle(maxConcurrentStreams: maxStreams, parked: false, lastIdle: lastIdle))
            }
        }

        mutating func execute(_ request: HTTPSchedulableRequest) throws {
            switch self.state {
            case .starting, .http1(.inUse):
                throw Errors.connectionNotIdle

            case .http1(.idle(true, _)), .http2(.idle(_, true, _)):
                throw Errors.connectionIsParked

            case .http1(.idle(false, _)):
                if let required = request.requiredEventLoop, required !== self.eventLoop {
                    throw Errors.connectionDoesNotFulfillEventLoopRequirement
                }
                self.state = .http1(.inUse)

            case .http2(.idle(let maxStreams, false, _)):
                if let required = request.requiredEventLoop, required !== self.eventLoop {
                    throw Errors.connectionDoesNotFulfillEventLoopRequirement
                }
                if maxStreams < 1 {
                    throw Errors.connectionDoesNotHaveHTTP2StreamAvailable
                }
                self.state = .http2(.inUse(maxConcurrentStreams: maxStreams, used: 1))

            case .http2(.inUse(let maxStreams, let used)):
                if let required = request.requiredEventLoop, required !== self.eventLoop {
                    throw Errors.connectionDoesNotFulfillEventLoopRequirement
                }
                if used >= maxStreams {
                    throw Errors.connectionDoesNotHaveHTTP2StreamAvailable
                }
                self.state = .http2(.inUse(maxConcurrentStreams: maxStreams, used: used + 1))

            case .closed:
                throw Errors.connectionIsClosed
            }
        }

        mutating func finishRequest() throws {
            switch self.state {
            case .starting, .http1(.idle), .http2(.idle):
                throw Errors.connectionIsNotExecuting

            case .http1(.inUse):
                self.state = .http1(.idle(parked: false, idleSince: .now()))

            case .http2(.inUse(let maxStreams, let used)):
                if used == 1 {
                    self.state = .http2(.idle(maxConcurrentStreams: maxStreams, parked: false, lastIdle: .now()))
                } else {
                    self.state = .http2(.inUse(maxConcurrentStreams: maxStreams, used: used))
                }

            case .closed:
                throw Errors.connectionIsClosed
            }
        }

        mutating func close() throws {
            switch self.state {
            case .starting:
                throw Errors.connectionNotIdle
            case .http1(.idle), .http2(.idle):
                self.state = .closed

            case .http1(.inUse), .http2(.inUse):
                throw Errors.connectionNotIdle

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

    var used: Int {
        self.connections.values.filter { $0.isUsed }.count
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
            .max(by: { $0.idleSince! < $1.idleSince! })
            .flatMap { .__testOnly_connection(id: $0.id, eventLoop: $0.eventLoop) }
    }

    var oldestParkedConnection: Connection? {
        self.connections.values
            .filter { $0.isParked }
            .min(by: { $0.idleSince! < $1.idleSince! })
            .flatMap { .__testOnly_connection(id: $0.id, eventLoop: $0.eventLoop) }
    }

    func newestParkedConnection(for eventLoop: EventLoop) -> Connection? {
        self.connections.values
            .filter { $0.eventLoop === eventLoop && $0.isParked }
            .max(by: { $0.idleSince! < $1.idleSince! })
            .flatMap { .__testOnly_connection(id: $0.id, eventLoop: $0.eventLoop) }
    }

    func connections(on eventLoop: EventLoop) -> Int {
        self.connections.values.filter { $0.eventLoop === eventLoop }.count
    }

    // MARK: Connection creation

    mutating func createConnection(_ connectionID: Connection.ID, on eventLoop: EventLoop) throws {
        guard self.connections[connectionID] == nil else {
            throw Errors.connectionExists
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

    /// Closing a connection signals intent. For this reason, it is verified, that the connection is not running any
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
}

extension MockConnectionPool {
    func randomStartingConnection() -> Connection.ID? {
        self.connections.values
            .filter { $0.isStarting }
            .randomElement()
            .map(\.id)
    }

    func randomActiveConnection() -> Connection.ID? {
        self.connections.values
            .filter { $0.isUsed || $0.isParked }
            .randomElement()
            .map(\.id)
    }

    func randomParkedConnection() -> Connection? {
        self.connections.values
            .filter { $0.isParked }
            .randomElement()
            .flatMap { .__testOnly_connection(id: $0.id, eventLoop: $0.eventLoop) }
    }

    func randomLeasedConnection() -> Connection? {
        self.connections.values
            .filter { $0.isUsed }
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
