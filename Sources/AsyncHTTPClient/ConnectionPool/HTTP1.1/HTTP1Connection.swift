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
        case active
        case closed
    }

    private var state: State = .active

    let id: HTTPConnectionPool.Connection.ID

    init(channel: Channel,
         connectionID: HTTPConnectionPool.Connection.ID,
         configuration: HTTPClient.Configuration,
         delegate: HTTP1ConnectionDelegate,
         logger: Logger) throws {
        channel.eventLoop.assertInEventLoop()

        // let's add the channel handlers needed for h1
        self.channel = channel
        self.id = connectionID
        self.delegate = delegate

        // all properties are set here. Therefore the connection is fully initialized. If we
        // run into an error, here we need to do the state handling ourselfes.

        do {
            let sync = channel.pipeline.syncOperations
            try sync.addHTTPClientHandlers()

            if case .enabled(let limit) = configuration.decompression {
                let decompressHandler = NIOHTTPResponseDecompressor(limit: limit)
                try sync.addHandler(decompressHandler)
            }

            let channelHandler = HTTP1ClientChannelHandler(
                connection: self,
                eventLoop: channel.eventLoop,
                logger: logger
            )
            try sync.addHandler(channelHandler)

            // with this we create an intended retain cycle...
            self.channel.closeFuture.whenComplete { _ in
                self.state = .closed
                self.delegate.http1ConnectionClosed(self)
            }
        } catch {
            self.state = .closed
            throw error
        }
    }

    deinit {
        guard case .closed = self.state else {
            preconditionFailure("Connection must be closed, before we can deinit it")
        }
    }

    func execute(request: HTTPExecutableRequest) {
        if self.channel.eventLoop.inEventLoop {
            self.execute0(request: request)
        } else {
            self.channel.eventLoop.execute {
                self.execute0(request: request)
            }
        }
    }

    func cancel() {
        self.channel.triggerUserOutboundEvent(HTTPConnectionEvent.cancelRequest, promise: nil)
    }

    func close() -> EventLoopFuture<Void> {
        return self.channel.close()
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
}
