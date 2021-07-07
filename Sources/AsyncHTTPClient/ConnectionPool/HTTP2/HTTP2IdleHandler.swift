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
import NIO
import NIOHTTP2

internal final class HTTP2IdleHandler: ChannelInboundHandler {
    typealias InboundIn = HTTP2Frame
    typealias OutboundOut = HTTP2Frame

    let logger: Logger
    let connection: HTTP2Connection

    var state: StateMachine = .init()

    init(connection: HTTP2Connection, logger: Logger) {
        self.connection = connection
        self.logger = logger
    }

    func handlerAdded(context: ChannelHandlerContext) {
        if context.channel.isActive {
            self.state.connected()
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        self.state.connected()
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = self.unwrapInboundIn(data)

        switch frame.payload {
        case .goAway:
            let action = self.state.goAwayReceived()
            self.run(action, context: context)
        case .settings(.settings(let settings)):
            let action = self.state.settingsReceived(settings)
            self.run(action, context: context)
        default:
            // We're not interested in other events.
            ()
        }

        context.fireChannelRead(data)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is NIOHTTP2StreamCreatedEvent:
            let action = self.state.streamCreated()
            self.run(action, context: context)
            context.fireUserInboundEventTriggered(event)
        case is NIOHTTP2.StreamClosedEvent:
            let action = self.state.streamClosed()
            self.run(action, context: context)
            context.fireUserInboundEventTriggered(event)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func run(_ action: StateMachine.Action, context: ChannelHandlerContext) {
        switch action {
        case .nothing:
            break
        case .notifyConnectionNewSettings(let settings):
            self.connection.http2SettingsReceived(settings)
        case .notifyConnectionStreamClosed(let currentlyAvailable):
            self.connection.http2StreamClosed(availableStreams: currentlyAvailable)
        case .notifyConnectionGoAwayReceived:
            self.connection.http2GoAwayReceived()
        }
    }
}

extension HTTP2IdleHandler {
    struct StateMachine {
        enum Action {
            case notifyConnectionNewSettings(HTTP2Settings)
            case notifyConnectionGoAwayReceived
            case notifyConnectionStreamClosed(currentlyAvailable: Int)
            case nothing
        }

        enum State {
            case initialized
            case connected
            case active(openStreams: Int, maxStreams: Int)
            case goAwayReceived(openStreams: Int, maxStreams: Int)
            case closed
        }

        var state: State = .initialized

        mutating func connected() {
            guard case .initialized = self.state else {
                preconditionFailure("Invalid state")
            }

            self.state = .connected
        }

        mutating func settingsReceived(_ settings: HTTP2Settings) -> Action {
            guard case .connected = self.state else {
                preconditionFailure("Invalid state")
            }

            let maxStream = settings.first(where: { $0.parameter == .maxConcurrentStreams })?.value ?? 100

            self.state = .active(openStreams: 0, maxStreams: maxStream)
            return .notifyConnectionNewSettings(settings)
        }

        mutating func goAwayReceived() -> Action {
            switch self.state {
            case .initialized:
                preconditionFailure("Invalid state")
            case .connected:
                self.state = .goAwayReceived(openStreams: 0, maxStreams: 0)
                return .notifyConnectionGoAwayReceived
            case .active(let openStreams, let maxStreams):
                self.state = .goAwayReceived(openStreams: openStreams, maxStreams: maxStreams)
                return .notifyConnectionGoAwayReceived
            case .goAwayReceived:
                preconditionFailure("Invalid state")
            case .closed:
                preconditionFailure("Invalid state")
            }
        }

        mutating func streamCreated() -> Action {
            guard case .active(var openStreams, let maxStreams) = self.state else {
                preconditionFailure("Invalid state")
            }

            openStreams += 1
            assert(openStreams <= maxStreams)

            self.state = .active(openStreams: openStreams, maxStreams: maxStreams)
            return .nothing
        }

        mutating func streamClosed() -> Action {
            guard case .active(var openStreams, let maxStreams) = self.state else {
                preconditionFailure("Invalid state")
            }

            openStreams -= 1
            assert(openStreams >= 0)

            self.state = .active(openStreams: openStreams, maxStreams: maxStreams)
            return .notifyConnectionStreamClosed(currentlyAvailable: maxStreams - openStreams)
        }
    }
}
