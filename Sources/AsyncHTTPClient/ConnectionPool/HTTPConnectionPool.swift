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

enum HTTPConnectionPool {
    struct Connection: Hashable {
        typealias ID = Int

        private enum Reference {
            case http1_1(HTTP1Connection)
            case http2(HTTP2Connection)
            case __testOnly_connection(ID, EventLoop)
        }

        private let _ref: Reference

        fileprivate static func http1_1(_ conn: HTTP1Connection) -> Self {
            Connection(_ref: .http1_1(conn))
        }

        fileprivate static func http2(_ conn: HTTP2Connection) -> Self {
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
        fileprivate func close() -> EventLoopFuture<Void> {
            switch self._ref {
            case .http1_1(let connection):
                return connection.close()
            case .http2(let connection):
                return connection.close()
            case .__testOnly_connection(_, let eventLoop):
                return eventLoop.makeSucceededFuture(())
            }
        }

        static func == (lhs: HTTPConnectionPool.Connection, rhs: HTTPConnectionPool.Connection) -> Bool {
            switch (lhs._ref, rhs._ref) {
            case (.http1_1(let lhsConn), .http1_1(let rhsConn)):
                return lhsConn.id == rhsConn.id
            case (.http2(let lhsConn), .http2(let rhsConn)):
                return lhsConn.id == rhsConn.id
            case (.__testOnly_connection(let lhsID, let lhsEventLoop), .__testOnly_connection(let rhsID, let rhsEventLoop)):
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
        return EventLoopID(.__testOnly_fakeID(id))
    }
}

extension EventLoop {
    var id: EventLoopID { EventLoopID(self) }
}
