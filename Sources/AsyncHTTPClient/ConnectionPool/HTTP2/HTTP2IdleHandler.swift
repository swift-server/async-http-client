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

internal final class HTTP2IdleHandler: ChannelDuplexHandler {
    typealias InboundIn = HTTP2Frame
    typealias InboundOut = HTTP2Frame
    typealias OutboundIn = HTTP2Frame
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
            self.state.channelActive()
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        self.state.channelActive()
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        self.state.channelInactive()
        context.fireChannelInactive()
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
        case HTTPConnectionEvent.closeConnection:
            let action = self.state.closeEventReceived()
            self.run(action, context: context)

        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    private func run(_ action: StateMachine.Action, context: ChannelHandlerContext) {
        switch action {
        case .nothing:
            break

        case .notifyConnectionNewSettings(let settings):
            self.connection.http2SettingsReceived(settings)

        case .notifyConnectionStreamClosed(let currentlyAvailable):
            self.connection.http2StreamClosed(availableStreams: currentlyAvailable)

        case .notifyConnectionGoAwayReceived:
            self.connection.http2GoAwayReceived()

        case .close:
            context.close(mode: .all, promise: nil)
        }
    }
}

extension HTTP2IdleHandler {
    struct StateMachine {
        enum Action {
            case notifyConnectionNewSettings(HTTP2Settings)
            case notifyConnectionGoAwayReceived(close: Bool)
            case notifyConnectionStreamClosed(currentlyAvailable: Int)
            case nothing
            case close
        }

        enum State {
            case initialized
            case connected
            case active(openStreams: Int, maxStreams: Int)
            case closing(openStreams: Int, maxStreams: Int)
            case closed
        }

        var state: State = .initialized

        mutating func channelActive() {
            switch self.state {
            case .initialized:
                self.state = .connected

            case .connected, .active, .closing, .closed:
                break
            }
        }

        mutating func channelInactive() {
            switch self.state {
            case .initialized, .connected, .active, .closing, .closed:
                self.state = .closed
            }
        }

        mutating func settingsReceived(_ settings: HTTP2Settings) -> Action {
            switch self.state {
            case .initialized, .closed:
                preconditionFailure("Invalid state: \(self.state)")

            case .connected:
                let maxStreams = settings.last(where: { $0.parameter == .maxConcurrentStreams })?.value ?? 100
                self.state = .active(openStreams: 0, maxStreams: maxStreams)
                return .notifyConnectionNewSettings(settings)

            case .active(openStreams: let openStreams, maxStreams: let maxStreams):
                if let newMaxStreams = settings.last(where: { $0.parameter == .maxConcurrentStreams })?.value, newMaxStreams != maxStreams {
                    self.state = .active(openStreams: openStreams, maxStreams: newMaxStreams)
                    return .notifyConnectionNewSettings(settings)
                }
                return .nothing

            case .closing:
                return .nothing
            }
        }

        mutating func goAwayReceived() -> Action {
            switch self.state {
            case .initialized, .closed:
                preconditionFailure("Invalid state")
            case .connected:
                self.state = .closing(openStreams: 0, maxStreams: 0)
                return .notifyConnectionGoAwayReceived(close: true)

            case .active(let openStreams, let maxStreams):
                self.state = .closing(openStreams: openStreams, maxStreams: maxStreams)
                return .notifyConnectionGoAwayReceived(close: openStreams == 0)

            case .closing:
                return .notifyConnectionGoAwayReceived(close: false)
            }
        }

        mutating func closeEventReceived() -> Action {
            switch self.state {
            case .initialized:
                preconditionFailure("")

            case .connected:
                self.state = .closing(openStreams: 0, maxStreams: 0)
                return .close

            case .active(let openStreams, let maxStreams):
                if openStreams == 0 {
                    self.state = .closed
                    return .close
                }

                self.state = .closing(openStreams: openStreams, maxStreams: maxStreams)
                return .nothing

            case .closed, .closing:
                return .nothing
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
                // TODO: What happens, if we received a go away?!??!
            }

            openStreams -= 1
            assert(openStreams >= 0)

            self.state = .active(openStreams: openStreams, maxStreams: maxStreams)
            return .notifyConnectionStreamClosed(currentlyAvailable: maxStreams - openStreams)
        }
    }
}
