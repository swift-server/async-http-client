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

import Atomics
import Dispatch
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded

@testable import AsyncHTTPClient

/// An `EventLoopGroup` of `EmbeddedEventLoop`s.
final class EmbeddedEventLoopGroup: EventLoopGroup {
    private let loops: [EmbeddedEventLoop]
    private let index = ManagedAtomic(0)

    internal init(loops: Int) {
        self.loops = (0..<loops).map { _ in EmbeddedEventLoop() }
    }

    internal func next() -> EventLoop {
        let index: Int = self.index.loadThenWrappingIncrement(ordering: .relaxed)
        return self.loops[index % self.loops.count]
    }

    internal func makeIterator() -> EventLoopIterator {
        EventLoopIterator(self.loops)
    }

    internal func shutdownGracefully(queue: DispatchQueue, _ callback: @escaping (Error?) -> Void) {
        var shutdownError: Error?

        for loop in self.loops {
            loop.shutdownGracefully(queue: queue) { error in
                if let error = error {
                    shutdownError = error
                }
            }
        }

        queue.sync {
            callback(shutdownError)
        }
    }
}

extension HTTPConnectionPool.Request: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }
}

extension HTTPConnectionPool.HTTP1Connections.ConnectionUse: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.eventLoop(let lhsEventLoop), .eventLoop(let rhsEventLoop)):
            return lhsEventLoop === rhsEventLoop
        case (.generalPurpose, .generalPurpose):
            return true
        default:
            return false
        }
    }
}

extension HTTPConnectionPool.StateMachine.ConnectionAction: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.createConnection(let lhsConnID, on: let lhsEL), .createConnection(let rhsConnID, on: let rhsEL)):
            return lhsConnID == rhsConnID && lhsEL === rhsEL
        case (
            .scheduleBackoffTimer(let lhsConnID, let lhsBackoff, on: let lhsEL),
            .scheduleBackoffTimer(let rhsConnID, let rhsBackoff, on: let rhsEL)
        ):
            return lhsConnID == rhsConnID && lhsBackoff == rhsBackoff && lhsEL === rhsEL
        case (.scheduleTimeoutTimer(let lhsConnID, on: let lhsEL), .scheduleTimeoutTimer(let rhsConnID, on: let rhsEL)):
            return lhsConnID == rhsConnID && lhsEL === rhsEL
        case (.cancelTimeoutTimer(let lhsConnID), .cancelTimeoutTimer(let rhsConnID)):
            return lhsConnID == rhsConnID
        case (
            .closeConnection(let lhsConn, isShutdown: let lhsShut),
            .closeConnection(let rhsConn, isShutdown: let rhsShut)
        ):
            return lhsConn == rhsConn && lhsShut == rhsShut
        case (
            .cleanupConnections(let lhsContext, isShutdown: let lhsShut),
            .cleanupConnections(let rhsContext, isShutdown: let rhsShut)
        ):
            return lhsContext == rhsContext && lhsShut == rhsShut
        case (
            .migration(
                let lhsCreateConnections,
                let lhsCloseConnections,
                let lhsScheduleTimeout
            ),
            .migration(
                let rhsCreateConnections,
                let rhsCloseConnections,
                let rhsScheduleTimeout
            )
        ):
            return lhsCreateConnections.elementsEqual(
                rhsCreateConnections,
                by: {
                    $0.0 == $1.0 && $0.1 === $1.1
                }
            ) && lhsCloseConnections == rhsCloseConnections && lhsScheduleTimeout?.0 == rhsScheduleTimeout?.0
                && lhsScheduleTimeout?.1 === rhsScheduleTimeout?.1
        case (.none, .none):
            return true
        default:
            return false
        }
    }
}

extension HTTPConnectionPool.StateMachine.RequestAction: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (
            .executeRequest(let lhsReq, let lhsConn, let lhsReqID),
            .executeRequest(let rhsReq, let rhsConn, let rhsReqID)
        ):
            return lhsReq == rhsReq && lhsConn == rhsConn && lhsReqID == rhsReqID
        case (
            .executeRequestsAndCancelTimeouts(let lhsReqs, let lhsConn),
            .executeRequestsAndCancelTimeouts(let rhsReqs, let rhsConn)
        ):
            return lhsReqs.elementsEqual(rhsReqs, by: { $0 == $1 }) && lhsConn == rhsConn
        case (
            .failRequest(let lhsReq, _, cancelTimeout: let lhsReqID),
            .failRequest(let rhsReq, _, cancelTimeout: let rhsReqID)
        ):
            return lhsReq == rhsReq && lhsReqID == rhsReqID
        case (.failRequestsAndCancelTimeouts(let lhsReqs, _), .failRequestsAndCancelTimeouts(let rhsReqs, _)):
            return lhsReqs.elementsEqual(rhsReqs, by: { $0 == $1 })
        case (
            .scheduleRequestTimeout(for: let lhsReq, on: let lhsEL),
            .scheduleRequestTimeout(for: let rhsReq, on: let rhsEL)
        ):
            return lhsReq == rhsReq && lhsEL === rhsEL
        case (.none, .none):
            return true
        default:
            return false
        }
    }
}

extension HTTPConnectionPool.StateMachine.Action: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.connection == rhs.connection && lhs.request == rhs.request
    }
}

extension HTTPConnectionPool.HTTP2StateMachine.EstablishedConnectionAction: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.scheduleTimeoutTimer(let lhsConnID, on: let lhsEL), .scheduleTimeoutTimer(let rhsConnID, on: let rhsEL)):
            return lhsConnID == rhsConnID && lhsEL === rhsEL
        case (
            .closeConnection(let lhsConn, isShutdown: let lhsShut),
            .closeConnection(let rhsConn, isShutdown: let rhsShut)
        ):
            return lhsConn == rhsConn && lhsShut == rhsShut
        case (.none, .none):
            return true
        default:
            return false
        }
    }
}

extension HTTPConnectionPool.HTTP2StateMachine.EstablishedAction: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.connection == rhs.connection && lhs.request == rhs.request
    }
}
