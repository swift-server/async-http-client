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
    struct Connection: Equatable {
        typealias ID = Int

        private enum Reference {
//            case http1_1(HTTP1Connection)

            case __testOnly_connection(ID, EventLoop)
        }

        private let _ref: Reference

//        fileprivate static func http1_1(_ conn: HTTP1Connection) -> Self {
//            Connection(_ref: .http1_1(conn))
//        }

        static func __testOnly_connection(id: ID, eventLoop: EventLoop) -> Self {
            Connection(_ref: .__testOnly_connection(id, eventLoop))
        }

        var id: ID {
            switch self._ref {
//            case .http1_1(let connection):
//                return connection.id
            case .__testOnly_connection(let id, _):
                return id
            }
        }

        var eventLoop: EventLoop {
            switch self._ref {
//            case .http1_1(let connection):
//                return connection.channel.eventLoop
            case .__testOnly_connection(_, let eventLoop):
                return eventLoop
            }
        }

        @discardableResult
        fileprivate func close() -> EventLoopFuture<Void> {
            switch self._ref {
//            case .http1_1(let connection):
//                return connection.close()

            case .__testOnly_connection(_, let eventLoop):
                return eventLoop.makeSucceededFuture(())
            }
        }

        fileprivate func execute(request: HTTPExecutingRequest) {
            switch self._ref {
//            case .http1_1(let connection):
//                return connection.execute(request: request)
            case .__testOnly_connection:
                break
            }
        }

        fileprivate func cancel() {
            switch self._ref {
//            case .http1_1(let connection):
//                return connection.cancel()
            case .__testOnly_connection:
                break
            }
        }

        static func == (lhs: HTTPConnectionPool.Connection, rhs: HTTPConnectionPool.Connection) -> Bool {
            switch (lhs._ref, rhs._ref) {
//            case (.http1_1(let lhsConn), .http1_1(let rhsConn)):
//                return lhsConn === rhsConn
            case (.__testOnly_connection(let lhsID, let lhsEventLoop), .__testOnly_connection(let rhsID, let rhsEventLoop)):
                return lhsID == rhsID && lhsEventLoop === rhsEventLoop
//            default:
//                return false
            }
        }
    }
}
