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
import NIOCore
import NIOHTTP2

protocol HTTP2IdleHandlerDelegate {
    func http2SettingsReceived(maxStreams: Int)

    func http2GoAwayReceived()

    func http2StreamClosed(availableStreams: Int)
}

// This is a `ChannelDuplexHandler` since we need to intercept outgoing user events. It is generic
// over its delegate to allow for specialization.
final class HTTP2IdleHandler<Delegate: HTTP2IdleHandlerDelegate>: ChannelDuplexHandler {
    typealias InboundIn = HTTP2Frame
    typealias InboundOut = HTTP2Frame
    typealias OutboundIn = HTTP2Frame
    typealias OutboundOut = HTTP2Frame

    let logger: Logger
    let delegate: Delegate

    private var state: StateMachine

    init(delegate: Delegate, logger: Logger, maximumConnectionUses: Int? = nil) {
        self.state = StateMachine(maximumUses: maximumConnectionUses)
        self.delegate = delegate
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
            break
        }

        context.fireChannelRead(data)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        // We intercept calls between the `NIOHTTP2ChannelHandler` and the `HTTP2StreamMultiplexer`
        // to learn, how many open streams we have.
        switch event {
        case is StreamClosedEvent:
            let action = self.state.streamClosed()
            self.run(action, context: context)

        case is NIOHTTP2StreamCreatedEvent:
            let action = self.state.streamCreated()
            self.run(action, context: context)

        default:
            // We're not interested in other events.
            break
        }

        context.fireUserInboundEventTriggered(event)
    }

    func triggerUserOutboundEvent(context: ChannelHandlerContext, event: Any, promise: EventLoopPromise<Void>?) {
        switch event {
        case HTTPConnectionEvent.shutdownRequested:
            let action = self.state.closeEventReceived()
            self.run(action, context: context)

        default:
            context.triggerUserOutboundEvent(event, promise: promise)
        }
    }

    private func run(_ action: StateMachine.Action, context: ChannelHandlerContext) {
        switch action {
        case .nothing:
            break

        case .notifyConnectionNewMaxStreamsSettings(let maxStreams):
            self.delegate.http2SettingsReceived(maxStreams: maxStreams)

        case .notifyConnectionStreamClosed(let currentlyAvailable):
            self.delegate.http2StreamClosed(availableStreams: currentlyAvailable)

        case .notifyConnectionGoAwayReceived:
            self.delegate.http2GoAwayReceived()

        case .close:
            context.close(mode: .all, promise: nil)
        }
    }
}

extension HTTP2IdleHandler {
    struct StateMachine {
        enum Action {
            case notifyConnectionNewMaxStreamsSettings(Int)
            case notifyConnectionGoAwayReceived(close: Bool)
            case notifyConnectionStreamClosed(currentlyAvailable: Int)
            case nothing
            case close
        }

        enum State {
            case initialized(maximumUses: Int?)
            case connected(remainingUses: Int?)
            case active(openStreams: Int, maxStreams: Int, remainingUses: Int?)
            case closing(openStreams: Int, maxStreams: Int)
            case closed
        }

        var state: State

        init(maximumUses: Int?) {
            self.state = .initialized(maximumUses: maximumUses)
        }

        mutating func channelActive() {
            switch self.state {
            case .initialized(let maximumUses):
                self.state = .connected(remainingUses: maximumUses)

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
            case .initialized:
                preconditionFailure("Invalid state: \(self.state)")

            case .connected(let remainingUses):
                // a settings frame might have multiple entries for `maxConcurrentStreams`. We are
                // only interested in the last value! If no `maxConcurrentStreams` is set, we assume
                // the http/2 default of 100.
                let maxStreams = settings.last(where: { $0.parameter == .maxConcurrentStreams })?.value ?? 100
                self.state = .active(openStreams: 0, maxStreams: maxStreams, remainingUses: remainingUses)
                return .notifyConnectionNewMaxStreamsSettings(maxStreams)

            case .active(let openStreams, let maxStreams, let remainingUses):
                if let newMaxStreams = settings.last(where: { $0.parameter == .maxConcurrentStreams })?.value,
                    newMaxStreams != maxStreams
                {
                    self.state = .active(
                        openStreams: openStreams,
                        maxStreams: newMaxStreams,
                        remainingUses: remainingUses
                    )
                    return .notifyConnectionNewMaxStreamsSettings(newMaxStreams)
                }
                return .nothing

            case .closing:
                return .nothing

            case .closed:
                // We may receive a Settings frame after we have called connection close, because of
                // packages being delivered from the incoming buffer.
                return .nothing
            }
        }

        mutating func goAwayReceived() -> Action {
            switch self.state {
            case .initialized:
                preconditionFailure("Invalid state: \(self.state)")

            case .connected:
                self.state = .closing(openStreams: 0, maxStreams: 0)
                return .notifyConnectionGoAwayReceived(close: true)

            case .active(let openStreams, let maxStreams, _):
                self.state = .closing(openStreams: openStreams, maxStreams: maxStreams)
                return .notifyConnectionGoAwayReceived(close: openStreams == 0)

            case .closing:
                return .notifyConnectionGoAwayReceived(close: false)

            case .closed:
                // We may receive a GoAway frame after we have called connection close, because of
                // packages being delivered from the incoming buffer.
                return .nothing
            }
        }

        mutating func closeEventReceived() -> Action {
            switch self.state {
            case .initialized:
                preconditionFailure("Invalid state: \(self.state)")

            case .connected:
                self.state = .closing(openStreams: 0, maxStreams: 0)
                return .close

            case .active(let openStreams, let maxStreams, _):
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
            switch self.state {
            case .initialized, .connected:
                preconditionFailure("Invalid state: \(self.state)")

            case .active(var openStreams, let maxStreams, let remainingUses):
                openStreams += 1
                let remainingUses = remainingUses.map { $0 - 1 }
                self.state = .active(openStreams: openStreams, maxStreams: maxStreams, remainingUses: remainingUses)

                if remainingUses == 0 {
                    // Treat running out of connection uses as if we received a GOAWAY frame. This
                    // will notify the delegate (i.e. connection pool) that the connection can no
                    // longer be used.
                    return self.goAwayReceived()
                } else {
                    return .nothing
                }

            case .closing(var openStreams, let maxStreams):
                // A stream might be opened, while we are closing because of race conditions. For
                // this reason, we should handle this case.
                openStreams += 1
                self.state = .closing(openStreams: openStreams, maxStreams: maxStreams)
                return .nothing

            case .closed:
                // We may receive a events after we have called connection close, because of
                // internal races. We should just ignore these cases.
                return .nothing
            }
        }

        mutating func streamClosed() -> Action {
            switch self.state {
            case .initialized, .connected:
                preconditionFailure("Invalid state: \(self.state)")

            case .active(var openStreams, let maxStreams, let remainingUses):
                openStreams -= 1
                assert(openStreams >= 0)
                self.state = .active(openStreams: openStreams, maxStreams: maxStreams, remainingUses: remainingUses)
                return .notifyConnectionStreamClosed(currentlyAvailable: maxStreams - openStreams)

            case .closing(var openStreams, let maxStreams):
                openStreams -= 1
                assert(openStreams >= 0)
                if openStreams == 0 {
                    self.state = .closed
                    return .close
                }
                self.state = .closing(openStreams: openStreams, maxStreams: maxStreams)
                return .nothing

            case .closed:
                // We may receive a events after we have called connection close, because of
                // internal races. We should just ignore these cases.
                return .nothing
            }
        }
    }
}
