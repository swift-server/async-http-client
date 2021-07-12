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

protocol HTTP2ConnectionDelegate {
    func http2ConnectionStreamClosed(_: HTTP2Connection, availableStreams: Int)
    func http2ConnectionGoAwayReceived(_: HTTP2Connection)
    func http2ConnectionClosed(_: HTTP2Connection)
}

struct HTTP2PushNotSupportedError: Error {}

struct HTTP2ReceivedGoAwayBeforeSettingsError: Error {}

class HTTP2Connection {
    let channel: Channel
    let multiplexer: HTTP2StreamMultiplexer
    let logger: Logger

    /// the connection pool that created the connection
    let delegate: HTTP2ConnectionDelegate

    enum State {
        case initialized
        case starting(EventLoopPromise<Void>)
        case active(HTTP2Settings)
        case closing
        case closed
    }

    var settings: HTTP2Settings? {
        self.channel.eventLoop.assertInEventLoop()
        switch self.state {
        case .initialized, .starting, .closing, .closed:
            return nil
        case .active(let settings):
            return settings
        }
    }

    private var state: State
    let id: HTTPConnectionPool.Connection.ID

    init(channel: Channel,
         connectionID: HTTPConnectionPool.Connection.ID,
         delegate: HTTP2ConnectionDelegate,
         logger: Logger) {
        precondition(channel.isActive)
        channel.eventLoop.preconditionInEventLoop()

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
                
                return channel.eventLoop.makeFailedFuture(HTTP2PushNotSupportedError())
            }
        )
        self.delegate = delegate
        self.state = .initialized
    }
    
    deinit {
        guard case .closed = self.state else {
            preconditionFailure("")
        }
    }
    
    static func start(
        channel: Channel,
        connectionID: HTTPConnectionPool.Connection.ID,
        delegate: HTTP2ConnectionDelegate,
        configuration: HTTPClient.Configuration,
        logger: Logger
    ) -> EventLoopFuture<HTTP2Connection> {
        let connection = HTTP2Connection(channel: channel, connectionID: connectionID, delegate: delegate, logger: logger)
        return connection.start().map{ _ in connection }
    }

    func execute(request: HTTPExecutableRequest) {
        let createStreamChannelPromise = self.channel.eventLoop.makePromise(of: Channel.self)

        self.multiplexer.createStreamChannel(promise: createStreamChannelPromise) { channel -> EventLoopFuture<Void> in
            do {
                let translate = HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: .https)
                let handler = HTTP2ClientRequestHandler(eventLoop: channel.eventLoop)

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
        case .initialized, .closed:
            preconditionFailure("Invalid state: \(self.state)")
        case .starting(let promise):
            self.state = .active(settings)
            promise.succeed(())
        case .active:
            self.state = .active(settings)
        case .closing:
            // ignore. we only wait for all connections to be closed anyway.
            break
        }
    }

    func http2GoAwayReceived() {
        self.channel.eventLoop.assertInEventLoop()

        switch self.state {
        case .initialized, .closed:
            preconditionFailure("Invalid state: \(self.state)")
            
        case .starting(let promise):
            self.state = .closing
            promise.fail(HTTP2ReceivedGoAwayBeforeSettingsError())
            
        case .active:
            self.state = .closing
            self.delegate.http2ConnectionGoAwayReceived(self)
            
        case .closing:
            // we are already closing. Nothing new
            break
        }
    }

    func http2StreamClosed(availableStreams: Int) {
        self.delegate.http2ConnectionStreamClosed(self, availableStreams: availableStreams)
    }
    
    private func start() -> EventLoopFuture<Void> {
        
        let readyToAcceptConnectionsPromise = channel.eventLoop.makePromise(of: Void.self)
        
        self.state = .starting(readyToAcceptConnectionsPromise)
        self.channel.closeFuture.whenComplete { _ in
            self.state = .closed
            self.delegate.http2ConnectionClosed(self)
        }
        
        do {
            let sync = channel.pipeline.syncOperations

            let http2Handler = NIOHTTP2Handler(mode: .client, initialSettings: nioDefaultSettings)
            let idleHandler = HTTP2IdleHandler(connection: self, logger: self.logger)

            try sync.addHandler(http2Handler, position: .last)
            try sync.addHandler(idleHandler, position: .last)
            try sync.addHandler(self.multiplexer, position: .last)
        } catch {
            self.channel.close(mode: .all, promise: nil)
            readyToAcceptConnectionsPromise.fail(error)
        }
        
        return readyToAcceptConnectionsPromise.futureResult
    }
}
