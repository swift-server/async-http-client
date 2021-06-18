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
