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
import NIOHTTP1
import NIOHTTPCompression

protocol HTTP1ConnectionDelegate {
    func http1ConnectionReleased(_: HTTP1Connection)
    func http1ConnectionClosed(_: HTTP1Connection)
}

final class HTTP1Connection {
    let channel: Channel

    /// the connection's delegate, that will be informed about connection close and connection release
    /// (ready to run next request).
    let delegate: HTTP1ConnectionDelegate

    enum State {
        case initialized
        case active
        case closed
    }

    private var state: State = .initialized

    let id: HTTPConnectionPool.Connection.ID

    init(channel: Channel,
         connectionID: HTTPConnectionPool.Connection.ID,
         delegate: HTTP1ConnectionDelegate) {
        self.channel = channel
        self.id = connectionID
        self.delegate = delegate
    }

    deinit {
        guard case .closed = self.state else {
            preconditionFailure("Connection must be closed, before we can deinit it")
        }
    }

    static func start(
        channel: Channel,
        connectionID: HTTPConnectionPool.Connection.ID,
        delegate: HTTP1ConnectionDelegate,
        decompression: HTTPClient.Decompression,
        logger: Logger
    ) throws -> HTTP1Connection {
        let connection = HTTP1Connection(channel: channel, connectionID: connectionID, delegate: delegate)
        try connection.start(decompression: decompression, logger: logger)
        return connection
    }

    func executeRequest(_ request: HTTPExecutableRequest) {
        if self.channel.eventLoop.inEventLoop {
            self.execute0(request: request)
        } else {
            self.channel.eventLoop.execute {
                self.execute0(request: request)
            }
        }
    }

    func shutdown() {
        self.channel.triggerUserOutboundEvent(HTTPConnectionEvent.shutdownRequested, promise: nil)
    }

    func close(promise: EventLoopPromise<Void>?) {
        return self.channel.close(mode: .all, promise: promise)
    }

    func close() -> EventLoopFuture<Void> {
        let promise = self.channel.eventLoop.makePromise(of: Void.self)
        self.close(promise: promise)
        return promise.futureResult
    }

    func taskCompleted() {
        self.delegate.http1ConnectionReleased(self)
    }

    private func execute0(request: HTTPExecutableRequest) {
        guard self.channel.isActive else {
            return request.fail(ChannelError.ioOnClosedChannel)
        }

        self.channel.write(request, promise: nil)
    }

    private func start(decompression: HTTPClient.Decompression, logger: Logger) throws {
        self.channel.eventLoop.assertInEventLoop()

        guard case .initialized = self.state else {
            preconditionFailure("Connection must be initialized, to start it")
        }

        self.state = .active
        self.channel.closeFuture.whenComplete { _ in
            self.state = .closed
            self.delegate.http1ConnectionClosed(self)
        }

        do {
            let sync = self.channel.pipeline.syncOperations

            // We can not use `sync.addHTTPClientHandlers()`, as we want to explicitly set the
            // `.informationalResponseStrategy` for the decoder.
            let requestEncoder = HTTPRequestEncoder()
            let responseDecoder = HTTPResponseDecoder(
                leftOverBytesStrategy: .dropBytes,
                informationalResponseStrategy: .forward
            )
            try sync.addHandler(requestEncoder)
            try sync.addHandler(ByteToMessageHandler(responseDecoder))

            if case .enabled(let limit) = decompression {
                let decompressHandler = NIOHTTPResponseDecompressor(limit: limit)
                try sync.addHandler(decompressHandler)
            }

            let channelHandler = HTTP1ClientChannelHandler(
                eventLoop: channel.eventLoop,
                backgroundLogger: logger,
                connectionIdLoggerMetadata: "\(self.id)"
            )
            channelHandler.onConnectionIdle = {
                self.taskCompleted()
            }

            try sync.addHandler(channelHandler)
        } catch {
            self.channel.close(mode: .all, promise: nil)
            throw error
        }
    }
}
