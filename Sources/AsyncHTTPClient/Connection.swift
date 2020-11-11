//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2019-2020 Apple Inc. and the AsyncHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation
import Logging
import NIO
import NIOConcurrencyHelpers
import NIOHTTP1
import NIOHTTPCompression
import NIOTLS
import NIOTransportServices

/// A `Connection` represents a `Channel` in the context of the connection pool
///
/// In the `ConnectionPool`, each `Channel` belongs to a given `HTTP1ConnectionProvider`
/// and has a certain "lease state" (see the `inUse` property).
/// The role of `Connection` is to model this by storing a `Channel` alongside its associated properties
/// so that they can be passed around together and correct provider can be identified when connection is released.
class Connection {
    /// The provider this `Connection` belongs to.
    ///
    /// This enables calling methods like `release()` directly on a `Connection` instead of
    /// calling `provider.release(connection)`. This gives a more object oriented feel to the API
    /// and can avoid having to keep explicit references to the pool at call site.
    private let provider: HTTP1ConnectionProvider

    /// The `Channel` of this `Connection`
    ///
    /// - Warning: Requests that lease connections from the `ConnectionPool` are responsible
    /// for removing the specific handlers they added to the `Channel` pipeline before releasing it to the pool.
    let channel: Channel

    init(channel: Channel, provider: HTTP1ConnectionProvider) {
        self.channel = channel
        self.provider = provider
    }
}

extension Connection {
    /// Release this `Connection` to its associated `HTTP1ConnectionProvider`.
    ///
    /// - Warning: This only releases the connection and doesn't take care of cleaning handlers in the `Channel` pipeline.
    func release(closing: Bool, logger: Logger) {
        self.channel.eventLoop.assertInEventLoop()
        self.provider.release(connection: self, closing: closing, logger: logger)
    }

    /// Called when channel exceeds idle time in pool.
    func timeout(logger: Logger) {
        self.channel.eventLoop.assertInEventLoop()
        self.provider.timeout(connection: self, logger: logger)
    }

    /// Called when channel goes inactive while in the pool.
    func remoteClosed(logger: Logger) {
        self.channel.eventLoop.assertInEventLoop()
        self.provider.remoteClosed(connection: self, logger: logger)
    }

    /// Called from `HTTP1ConnectionProvider.close` when client is shutting down.
    func close() -> EventLoopFuture<Void> {
        return self.channel.close()
    }
}

/// Methods of Connection which are used in ConnectionsState extracted as protocol
/// to facilitate test of ConnectionsState.
protocol PoolManageableConnection: AnyObject {
    func cancel() -> EventLoopFuture<Void>
    var eventLoop: EventLoop { get }
    var isActiveEstimation: Bool { get }
}

/// Implementation of methods used by ConnectionsState and its tests to manage Connection
extension Connection: PoolManageableConnection {
    /// Convenience property indicating whether the underlying `Channel` is active or not.
    var isActiveEstimation: Bool {
        return self.channel.isActive
    }

    var eventLoop: EventLoop {
        return self.channel.eventLoop
    }

    func cancel() -> EventLoopFuture<Void> {
        return self.channel.triggerUserOutboundEvent(TaskCancelEvent())
    }
}

extension Connection {
    /// Sets idle timeout handler and channel inactivity listener.
    func setIdleTimeout(timeout: TimeAmount?, logger: Logger) {
        _ = self.channel.pipeline.addHandler(IdleStateHandler(writeTimeout: timeout), position: .first).flatMap { _ in
            self.channel.pipeline.addHandler(IdlePoolConnectionHandler(connection: self, logger: logger))
        }
    }

    /// Removes idle timeout handler and channel inactivity listener
    func cancelIdleTimeout() -> EventLoopFuture<Void> {
        return self.removeHandler(IdleStateHandler.self).flatMap { _ in
            self.removeHandler(IdlePoolConnectionHandler.self)
        }
    }
}

class IdlePoolConnectionHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = NIOAny

    let connection: Connection
    var eventSent: Bool
    let logger: Logger

    init(connection: Connection, logger: Logger) {
        self.connection = connection
        self.eventSent = false
        self.logger = logger
    }

    // this is needed to detect when remote end closes connection while connection is in the pool idling
    func channelInactive(context: ChannelHandlerContext) {
        if !self.eventSent {
            self.eventSent = true
            self.connection.remoteClosed(logger: self.logger)
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let idleEvent = event as? IdleStateHandler.IdleStateEvent, idleEvent == .write {
            if !self.eventSent {
                self.eventSent = true
                self.connection.timeout(logger: self.logger)
            }
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }
}

extension Connection: CustomStringConvertible {
    var description: String {
        return "\(self.channel)"
    }
}

struct ConnectionKey<ConnectionType>: Hashable where ConnectionType: PoolManageableConnection {
    let connection: ConnectionType

    init(_ connection: ConnectionType) {
        self.connection = connection
    }

    static func == (lhs: ConnectionKey<ConnectionType>, rhs: ConnectionKey<ConnectionType>) -> Bool {
        return ObjectIdentifier(lhs.connection) == ObjectIdentifier(rhs.connection)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self.connection))
    }

    func cancel() -> EventLoopFuture<Void> {
        return self.connection.cancel()
    }
}
