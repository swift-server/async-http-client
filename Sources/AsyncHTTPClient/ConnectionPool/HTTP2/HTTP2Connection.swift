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
import NIOHTTPCompression

protocol HTTP2ConnectionDelegate {
    func http2Connection(_: HTTP2Connection, newMaxStreamSetting: Int)
    func http2ConnectionStreamClosed(_: HTTP2Connection, availableStreams: Int)
    func http2ConnectionGoAwayReceived(_: HTTP2Connection)
    func http2ConnectionClosed(_: HTTP2Connection)
}

struct HTTP2PushNotSupportedError: Error {}

struct HTTP2ReceivedGoAwayBeforeSettingsError: Error {}

final class HTTP2Connection {
    let channel: Channel
    let multiplexer: HTTP2StreamMultiplexer
    let logger: Logger

    /// the connection pool that created the connection
    let delegate: HTTP2ConnectionDelegate

    enum State {
        case initialized
        case starting(EventLoopPromise<Int>)
        case active(maxStreams: Int)
        case closing
        case closed
    }

    /// A structure to store a http/2 stream channel in a set.
    private struct ChannelBox: Hashable {
        struct ID: Hashable {
            private let id: ObjectIdentifier

            init(_ channel: Channel) {
                self.id = ObjectIdentifier(channel)
            }
        }

        let channel: Channel

        var id: ID {
            ID(self.channel)
        }

        init(_ channel: Channel) {
            self.channel = channel
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.id == rhs.id
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(self.id)
        }
    }

    private var state: State

    /// We use this channel set to remember, which open streams we need to inform that
    /// we want to close the connection. The channels shall than cancel their currently running
    /// request.
    private var openStreams = Set<ChannelBox>()
    let id: HTTPConnectionPool.Connection.ID
    let decompression: HTTPClient.Decompression

    var closeFuture: EventLoopFuture<Void> {
        self.channel.closeFuture
    }

    init(channel: Channel,
         connectionID: HTTPConnectionPool.Connection.ID,
         decompression: HTTPClient.Decompression,
         delegate: HTTP2ConnectionDelegate,
         logger: Logger) {
        self.channel = channel
        self.id = connectionID
        self.decompression = decompression
        self.logger = logger
        self.multiplexer = HTTP2StreamMultiplexer(
            mode: .client,
            channel: channel,
            targetWindowSize: 8 * 1024 * 1024, // 8mb
            outboundBufferSizeHighWatermark: 8196,
            outboundBufferSizeLowWatermark: 4092,
            inboundStreamInitializer: { channel -> EventLoopFuture<Void> in
                channel.eventLoop.makeFailedFuture(HTTP2PushNotSupportedError())
            }
        )
        self.delegate = delegate
        self.state = .initialized
    }

    deinit {
        guard case .closed = self.state else {
            preconditionFailure("Connection must be closed, before we can deinit it. Current state: \(self.state)")
        }
    }

    static func start(
        channel: Channel,
        connectionID: HTTPConnectionPool.Connection.ID,
        delegate: HTTP2ConnectionDelegate,
        decompression: HTTPClient.Decompression,
        logger: Logger
    ) -> EventLoopFuture<(HTTP2Connection, Int)> {
        let connection = HTTP2Connection(
            channel: channel,
            connectionID: connectionID,
            decompression: decompression,
            delegate: delegate,
            logger: logger
        )
        return connection._start0().map { maxStreams in (connection, maxStreams) }
    }

    func executeRequest(_ request: HTTPExecutableRequest) {
        if self.channel.eventLoop.inEventLoop {
            self.executeRequest0(request)
        } else {
            self.channel.eventLoop.execute {
                self.executeRequest0(request)
            }
        }
    }

    /// shuts down the connection by cancelling all running tasks and closing the connection once
    /// all child streams/channels are closed.
    func shutdown() {
        if self.channel.eventLoop.inEventLoop {
            self.shutdown0()
        } else {
            self.channel.eventLoop.execute {
                self.shutdown0()
            }
        }
    }

    func close(promise: EventLoopPromise<Void>?) {
        return self.channel.close(mode: .all, promise: promise)
    }

    func close() -> EventLoopFuture<Void> {
        let promise = self.channel.eventLoop.makePromise(of: Void.self)
        self.close(promise: promise)
        return promise.futureResult
    }

    func _start0() -> EventLoopFuture<Int> {
        self.channel.eventLoop.assertInEventLoop()

        let readyToAcceptConnectionsPromise = self.channel.eventLoop.makePromise(of: Int.self)

        self.state = .starting(readyToAcceptConnectionsPromise)
        self.channel.closeFuture.whenComplete { _ in
            switch self.state {
            case .initialized, .closed:
                preconditionFailure("invalid state \(self.state)")
            case .starting(let readyToAcceptConnectionsPromise):
                self.state = .closed
                readyToAcceptConnectionsPromise.fail(HTTPClientError.remoteConnectionClosed)
            case .active, .closing:
                self.state = .closed
                self.delegate.http2ConnectionClosed(self)
            }
        }

        do {
            // We create and add the http handlers ourselves here, since we need to inject an
            // `HTTP2IdleHandler` between the `NIOHTTP2Handler` and the `HTTP2StreamMultiplexer`.
            // The purpose of the `HTTP2IdleHandler` is to count open streams in the multiplexer.
            // We use the HTTP2IdleHandler's information to notify our delegate, whether more work
            // can be scheduled on this connection.
            let sync = self.channel.pipeline.syncOperations

            let http2Handler = NIOHTTP2Handler(mode: .client, initialSettings: nioDefaultSettings)
            let idleHandler = HTTP2IdleHandler(delegate: self, logger: self.logger)

            try sync.addHandler(http2Handler, position: .last)
            try sync.addHandler(idleHandler, position: .last)
            try sync.addHandler(self.multiplexer, position: .last)
        } catch {
            self.channel.close(mode: .all, promise: nil)
            readyToAcceptConnectionsPromise.fail(error)
        }

        return readyToAcceptConnectionsPromise.futureResult
    }

    private func executeRequest0(_ request: HTTPExecutableRequest) {
        self.channel.eventLoop.assertInEventLoop()

        switch self.state {
        case .initialized, .starting:
            preconditionFailure("Invalid state: \(self.state). Sending requests is not allowed before we are started.")

        case .active:
            let createStreamChannelPromise = self.channel.eventLoop.makePromise(of: Channel.self)
            self.multiplexer.createStreamChannel(promise: createStreamChannelPromise) { channel -> EventLoopFuture<Void> in
                do {
                    // the connection may have been asked to shutdown while we created the child. in
                    // this
                    // channel.
                    guard case .active = self.state else {
                        throw HTTPClientError.cancelled
                    }

                    // We only support http/2 over an https connection – using the Application-Layer
                    // Protocol Negotiation (ALPN). For this reason it is safe to fix this to `.https`.
                    let translate = HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: .https)
                    try channel.pipeline.syncOperations.addHandler(translate)

                    if case .enabled(let limit) = self.decompression {
                        let decompressHandler = NIOHTTPResponseDecompressor(limit: limit)
                        try channel.pipeline.syncOperations.addHandler(decompressHandler)
                    }

                    let handler = HTTP2ClientRequestHandler(eventLoop: channel.eventLoop)
                    try channel.pipeline.syncOperations.addHandler(handler)

                    // We must add the new channel to the list of open channels BEFORE we write the
                    // request to it. In case of an error, we are sure that the channel was added
                    // before.
                    let box = ChannelBox(channel)
                    self.openStreams.insert(box)
                    self.channel.closeFuture.whenComplete { _ in
                        self.openStreams.remove(box)
                    }

                    channel.write(request, promise: nil)
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }

            createStreamChannelPromise.futureResult.whenFailure { error in
                request.fail(error)
            }

        case .closing, .closed:
            // Because of race conditions requests might reach this point, even though the
            // connection is already closing
            return request.fail(HTTPClientError.cancelled)
        }
    }

    private func shutdown0() {
        self.channel.eventLoop.assertInEventLoop()

        switch self.state {
        case .active:
            self.state = .closing

            // inform all open streams, that the currently running request should be cancelled.
            self.openStreams.forEach { box in
                box.channel.triggerUserOutboundEvent(HTTPConnectionEvent.shutdownRequested, promise: nil)
            }

            // inform the idle connection handler, that connection should be closed, once all streams
            // are closed.
            self.channel.triggerUserOutboundEvent(HTTPConnectionEvent.shutdownRequested, promise: nil)

        case .closed, .closing:
            // we are already closing/closed and we need to tolerate this
            break

        case .initialized, .starting:
            preconditionFailure("invalid state \(self.state)")
        }
    }
}

extension HTTP2Connection: HTTP2IdleHandlerDelegate {
    func http2SettingsReceived(maxStreams: Int) {
        self.channel.eventLoop.assertInEventLoop()

        switch self.state {
        case .initialized:
            preconditionFailure("Invalid state: \(self.state)")

        case .starting(let promise):
            self.state = .active(maxStreams: maxStreams)
            promise.succeed(maxStreams)

        case .active:
            self.state = .active(maxStreams: maxStreams)
            self.delegate.http2Connection(self, newMaxStreamSetting: maxStreams)

        case .closing, .closed:
            // ignore. we only wait for all connections to be closed anyway.
            break
        }
    }

    func http2GoAwayReceived() {
        self.channel.eventLoop.assertInEventLoop()

        switch self.state {
        case .initialized:
            preconditionFailure("Invalid state: \(self.state)")

        case .starting(let promise):
            self.state = .closing
            promise.fail(HTTP2ReceivedGoAwayBeforeSettingsError())

        case .active:
            self.state = .closing
            self.delegate.http2ConnectionGoAwayReceived(self)

        case .closing, .closed:
            // we are already closing. Nothing new
            break
        }
    }

    func http2StreamClosed(availableStreams: Int) {
        self.channel.eventLoop.assertInEventLoop()

        self.delegate.http2ConnectionStreamClosed(self, availableStreams: availableStreams)
    }
}
