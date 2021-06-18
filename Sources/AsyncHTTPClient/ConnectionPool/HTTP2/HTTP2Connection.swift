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
@_implementationOnly import NIOHTTP2

protocol HTTP2ConnectionDelegate {
    func http2ConnectionStreamClosed(_: HTTP2Connection, availableStreams: Int)
    func http2ConnectionClosed(_: HTTP2Connection)
}

class HTTP2Connection {
    let channel: Channel
    let multiplexer: HTTP2StreamMultiplexer
    let logger: Logger

    /// the connection pool that created the connection
    let delegate: HTTP2ConnectionDelegate

    enum State {
        case starting(EventLoopPromise<Void>)
        case active(HTTP2Settings)
        case closed
    }

    var readyToAcceptConnectionsFuture: EventLoopFuture<Void>

    var settings: HTTP2Settings? {
        self.channel.eventLoop.assertInEventLoop()
        switch self.state {
        case .starting:
            return nil
        case .active(let settings):
            return settings
        case .closed:
            return nil
        }
    }

    private var state: State
    let id: HTTPConnectionPool.Connection.ID

    init(channel: Channel,
         connectionID: HTTPConnectionPool.Connection.ID,
         delegate: HTTP2ConnectionDelegate,
         logger: Logger) throws {
        precondition(channel.isActive)
        channel.eventLoop.preconditionInEventLoop()

        let readyToAcceptConnectionsPromise = channel.eventLoop.makePromise(of: Void.self)

        self.channel = channel
        self.id = connectionID
        self.logger = logger
        self.multiplexer = HTTP2StreamMultiplexer(
            mode: .client,
            channel: channel,
            targetWindowSize: 65535,
            outboundBufferSizeHighWatermark: 8196,
            outboundBufferSizeLowWatermark: 4092,
            inboundStreamInitializer: { (channel) -> EventLoopFuture<Void> in
                struct HTTP2PushNotsupportedError: Error {}
                return channel.eventLoop.makeFailedFuture(HTTP2PushNotsupportedError())
            }
        )
        self.delegate = delegate
        self.state = .starting(readyToAcceptConnectionsPromise)
        self.readyToAcceptConnectionsFuture = readyToAcceptConnectionsPromise.futureResult

        // 1. Modify channel pipeline and add http2 handlers
        let sync = channel.pipeline.syncOperations

        let http2Handler = NIOHTTP2Handler(mode: .client, initialSettings: nioDefaultSettings)
        let idleHandler = HTTP2IdleHandler(connection: self, logger: self.logger)

        try sync.addHandler(http2Handler, position: .last)
        try sync.addHandler(idleHandler, position: .last)
        try sync.addHandler(self.multiplexer, position: .last)

        // 2. set properties

        // with this we create an intended retain cycle...
        channel.closeFuture.whenComplete { _ in
            self.state = .closed
            self.delegate.http2ConnectionClosed(self)
        }
    }

    func execute(request: HTTPRequestTask) {
        let createStreamChannelPromise = self.channel.eventLoop.makePromise(of: Channel.self)

        self.multiplexer.createStreamChannel(promise: createStreamChannelPromise) { channel -> EventLoopFuture<Void> in
            do {
                let translate = HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: .https)
                let handler = HTTP2ClientRequestHandler(logger: self.logger)

                try channel.pipeline.syncOperations.addHandler(translate)
                try channel.pipeline.syncOperations.addHandler(handler)
                channel.write(request, promise: nil)
                return channel.eventLoop.makeSucceededFuture(Void())
            } catch {
                return channel.eventLoop.makeFailedFuture(error)
            }
        }

        createStreamChannelPromise.futureResult.whenFailure { error in
            request.fail(error)
        }
    }

    func close() -> EventLoopFuture<Void> {
        self.channel.close()
    }

    func http2SettingsReceived(_ settings: HTTP2Settings) {
        self.channel.eventLoop.assertInEventLoop()

        switch self.state {
        case .starting(let promise):
            self.state = .active(settings)
            promise.succeed(())
        case .active:
            self.state = .active(settings)
        case .closed:
            preconditionFailure("Invalid state")
        }
    }

    func http2GoAwayReceived() {}

    func http2StreamClosed(availableStreams: Int) {
        self.delegate.http2ConnectionStreamClosed(self, availableStreams: availableStreams)
    }
}
