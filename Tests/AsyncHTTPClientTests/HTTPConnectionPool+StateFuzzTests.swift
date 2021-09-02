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
import NIO
import NIOHTTP1
import XCTest

class HTTPConnectionPool_StateMachineFuzzTests: XCTestCase {
    enum FuzzError: Error, Equatable {
        case failedToCreateConnection
        case expectedRequestToCancel
        case unexpectedConnectionAction(HTTPConnectionPool.StateMachine.ConnectionAction)
    }

    func testFuzzing() {
        // we start with a connection pool that allows eight connections and has four active.
        let threads = (1...64).randomElement()!
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: threads)
        defer { XCTAssertNoThrow(try elg.syncShutdownGracefully()) }
        guard let (pool, initialMachine) = try? MockConnectionPool.http1(elg: elg, numberOfConnections: 4) else {
            return XCTFail("Test setup failed")
        }

        var stateMachine = initialMachine
        var fuzzState = FuzzState(
            pool: pool,
            waiters: MockWaiters(),
            eventLoopGroup: elg,
            elgThreadCount: threads
        )

        let iterations = (8000...10000).randomElement()!
        var events = [FuzzEvent]()
        var actions = [HTTPConnectionPool.StateMachine.Action]()
        events.reserveCapacity(iterations)

        do {
            for _ in 0..<iterations {
                let event = fuzzState.translate(.random())
                let action: HTTPConnectionPool.StateMachine.Action
                switch event {
                case .executeRequest(let request):
                    action = stateMachine.executeRequest(request)

                case .startConnectionSuccess(let connection):
                    action = stateMachine.newHTTP1ConnectionCreated(connection)

                case .startConnectionFailure(let connectionID):
                    action = stateMachine.failedToCreateNewConnection(
                        FuzzError.failedToCreateConnection,
                        connectionID: connectionID
                    )

                case .connectionBackoffTimerDone(let connectionID):
                    action = stateMachine.connectionCreationBackoffDone(connectionID)

                case .returnConnection(let connection):
                    action = stateMachine.http1ConnectionReleased(connection.id)

                case .closeConnection(let connectionID):
                    action = stateMachine.connectionClosed(connectionID)

                case .timeoutConnection(let connectionID):
                    action = stateMachine.connectionIdleTimeout(connectionID)

                case .timeoutWaiter(let waiterID):
                    action = stateMachine.waiterTimeout(waiterID)
                }

                events.append(event)
                actions.append(action)
                try fuzzState.run(action, for: event)
            }

//            let action = stateMachine.shutdown()
//            actions.append(action)
//
//            guard case .cleanupConnections(let context, _) = action.connection else {
//                throw FuzzError.unexpectedConnectionAction(action.connection)
//            }
//            try fuzzState.run(action, for: .s)
//
//            // the cancelled connections are going away
//            for connection in context.cancel {
//                _ = stateMachine.connectionClosed(connection.id)
//            }
//
//            while let startingConnection = fuzzState.pool.randomStartingConnection() {
//                try fuzzState.pool.failConnectionCreation(startingConnection)
//                let action = stateMachine.failedToCreateNewConnection(
//                    FuzzError.failedToCreateConnection,
//                    connectionID: startingConnection
//                )
//                events.append(.startConnectionFailure(startingConnection))
//                actions.append(action)
//                try fuzzState.run(action, for: .startConnectionFailure(startingConnection))
//            }
//            XCTAssertTrue(fuzzState.isShutdown, "\(fuzzState)")
//            XCTAssertTrue(fuzzState.isCleanedUp, "\(fuzzState)")
        } catch {
            XCTFail("Unexpected error: \(error)")
            print("events: \(events.pretty)")
            print("actions: \(actions)")
        }
    }
}

struct FuzzState {
    var pool: MockConnectionPool
    var waiters: MockWaiters
    var elGenerator: RandomEventLoopGenerator
    private(set) var isShutdown: Bool = false

    var isCleanedUp: Bool {
        self.waiters.isEmpty && self.pool.isEmpty
    }

    init(pool: MockConnectionPool, waiters: MockWaiters, eventLoopGroup: EventLoopGroup, elgThreadCount: Int) {
        self.pool = pool
        self.waiters = waiters
        self.elGenerator = RandomEventLoopGenerator(eventLoopGroup: eventLoopGroup, threadCount: elgThreadCount)
    }

    mutating func translate(_ source: FuzzEventSource) -> FuzzEvent {
        func generateNewRequest() -> FuzzEvent {
            let eventLoop = self.elGenerator.randomEventLoop()
            let required = (0..<10).randomElement()! == 0
            let mockRequest = MockHTTPRequest(eventLoop: eventLoop, requiresEventLoopForChannel: required)
            return .executeRequest(.init(mockRequest))
        }

        switch source {
        case .executeRequest:
            return generateNewRequest()

        case .startConnectionSuccess:
            guard let connectionID = self.pool.randomStartingConnection() else {
                // if we have no starting connection we can fail, how about creating a new request?!
                return generateNewRequest()
            }
            let connection = try! self.pool.succeedConnectionCreationHTTP1(connectionID)
            return .startConnectionSuccess(connection)

        case .startConnectionFailure:
            guard let connectionID = self.pool.randomStartingConnection() else {
                // if we have no starting connection we can fail, how about creating a new request?!
                return generateNewRequest()
            }
            try! self.pool.failConnectionCreation(connectionID)
            return .startConnectionFailure(connectionID)

        case .connectionBackoffTimerDone:
            guard let connectionID = self.pool.randomBackingOffConnection() else {
                return generateNewRequest()
            }

            try! self.pool.connectionBackoffTimerDone(connectionID)
            return .connectionBackoffTimerDone(connectionID)

        case .returnConnection:
            guard let connection = self.pool.randomLeasedConnection() else {
                // if we have no starting connection we can fail, how about creating a new request?!
                return generateNewRequest()
            }
            try! self.pool.finishExecution(connection.id)
            return .returnConnection(connection)

        case .closeConnection:
            guard let connectionID = self.pool.closeRandomActiveConnection() else {
                // if we have no starting connection we can fail, how about creating a new request?!
                return generateNewRequest()
            }
            return .closeConnection(connectionID)

        case .timeoutConnection:
            // we pick all active connections, since there might be races here at play!
            guard let connectionID = self.pool.randomActiveConnection() else {
                // if we have no active connection we can fail, how about creating a new request?!
                return generateNewRequest()
            }
            return .timeoutConnection(connectionID)

        case .timeoutWaiter:
            guard let waiterID = self.waiters.timeoutRandomWaiter() else {
                return generateNewRequest()
            }
            return .timeoutWaiter(waiterID)
        }
    }

    mutating func run(_ action: HTTPConnectionPool.StateMachine.Action, for event: FuzzEvent) throws {
        try self.runConnection(action.connection)
        try self.runRequest(action.request, for: event)
    }

    mutating func runRequest(_ action: HTTPConnectionPool.StateMachine.RequestAction, for event: FuzzEvent) throws {
        switch action {
        case .executeRequest(let request, let connection, cancelWaiter: let waiterID):
            if let waiterID = waiterID {
                _ = try self.waiters.get(waiterID, request: request.__testOnly_wrapped_request())
            }

            try self.pool.execute(request.__testOnly_wrapped_request(), on: connection)

        case .executeRequests(let requests, let connection):
            for (request, waiterID) in requests {
                if let waiterID = waiterID {
                    _ = try self.waiters.get(waiterID, request: request.__testOnly_wrapped_request())
                }
                try self.pool.execute(request.__testOnly_wrapped_request(), on: connection)
            }

        case .none:
            break

        case .failRequest(let request, let error, cancelWaiter: let waiterID):
            XCTAssertEqual(error as? HTTPClientError, .getConnectionFromPoolTimeout)
            if let waiterID = waiterID {
                _ = try self.waiters.fail(waiterID, request: request.__testOnly_wrapped_request())
            }

        case .failRequests(let requests, let error):
            XCTAssertNotNil(error as? HTTPClientError)
            for (request, waiterID) in requests {
                if let waiterID = waiterID {
                    _ = try self.waiters.fail(waiterID, request: request.__testOnly_wrapped_request())
                }
            }

        case .scheduleRequestTimeout(_, let requestID, on: _):
            guard case .executeRequest(let request) = event else {
                return XCTFail("Expected an executeRequest event for action scheduleRequestTimeout")
            }
            try self.waiters.wait(request.__testOnly_wrapped_request(), id: requestID)

        case .cancelRequestTimeout(let requestID):
            try self.waiters.cancel(requestID)
        }
    }

    mutating func runConnection(_ action: HTTPConnectionPool.StateMachine.ConnectionAction) throws {
        switch action {
        case .none:
            break

        case .scheduleTimeoutTimer(let connectionID, _):
            try self.pool.parkConnection(connectionID)

        case .cancelTimeoutTimer(let connectionID):
            try self.pool.activateConnection(connectionID)

        case .closeConnection(let connection, isShutdown: let isShutdown):
            try self.pool.closeConnection(connection)
            if case .yes = isShutdown { self.isShutdown = true }

        case .scheduleBackoffTimer(let connectionID, backoff: _, on: _):
            try self.pool.startConnectionBackoffTimer(connectionID)

        case .createConnection(let connectionID, on: let eventLoop):
            try self.pool.createConnection(connectionID, on: eventLoop)

        case .cleanupConnections(let cleanupContext, isShutdown: let isShutdown):
            try cleanupContext.close.forEach {
                try self.pool.closeConnection($0)
            }
            try cleanupContext.cancel.forEach {
                try self.pool.abortConnection($0.id)
            }
            try cleanupContext.connectBackoff.forEach {
                try self.pool.cancelConnectionBackoffTimer($0)
            }
            if case .yes = isShutdown { self.isShutdown = true }
        }
    }
}

struct RandomEventLoopGenerator {
    private let elg: EventLoopGroup
    private let elgThreadCount: Int
    private var randomGenerator = SystemRandomNumberGenerator()

    init(eventLoopGroup: EventLoopGroup, threadCount: Int) {
        self.elg = eventLoopGroup
        self.elgThreadCount = threadCount
    }

    mutating func randomEventLoop() -> EventLoop {
        let count = (0..<self.elgThreadCount).randomElement(using: &self.randomGenerator)!
        for _ in 0..<count {
            _ = self.elg.next()
        }
        return self.elg.next()
    }
}

enum FuzzEventSource: CaseIterable {
    case executeRequest

    case startConnectionFailure
    case startConnectionSuccess

    case connectionBackoffTimerDone

    case returnConnection
    case closeConnection

    case timeoutConnection
    case timeoutWaiter

    static func random() -> FuzzEventSource {
        Self.allCases.randomElement()!
    }
}

enum FuzzEvent: CustomStringConvertible {
    case executeRequest(HTTPConnectionPool.Request)

    case startConnectionFailure(HTTPConnectionPool.Connection.ID)
    case startConnectionSuccess(HTTPConnectionPool.Connection)

    case connectionBackoffTimerDone(HTTPConnectionPool.Connection.ID)

    case returnConnection(HTTPConnectionPool.Connection)
    case closeConnection(HTTPConnectionPool.Connection.ID)

    case timeoutConnection(HTTPConnectionPool.Connection.ID)
    case timeoutWaiter(HTTPConnectionPool.Request.ID)

    var description: String {
        switch self {
        case .executeRequest(let request):
            return ".executeRequest(\(request))"
        case .startConnectionSuccess(let connection):
            return ".startConnectionSuccess(\(connection))"
        case .startConnectionFailure(let connectionID):
            return ".startConnectionFailure(\(connectionID))"
        case .connectionBackoffTimerDone(let connectionID):
            return ".connectionBackoffTimerDone(\(connectionID))"
        case .returnConnection(let connection):
            return ".returnConnection(\(connection))"
        case .closeConnection(let connectionID):
            return ".closeConnection(\(connectionID))"
        case .timeoutConnection(let connectionID):
            return ".timeoutConnection(\(connectionID))"
        case .timeoutWaiter(let requestID):
            return ".timeoutWaiter(\(requestID))"
        }
    }
}

extension Array where Element == FuzzEvent {
    var pretty: String {
        var result = "[\n    "
        result += self.map { $0.description }.joined(separator: ",\n    ")
        result += "\n]"
        return result
    }
}
