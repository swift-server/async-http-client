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
import NIOConcurrencyHelpers
import NIOHTTP1

/// A handle to the request queuer.
///
/// Use this handle to cancel the request, while it is waiting for a free connection, to execute the request.
/// This protocol is implemented by the `HTTPConnectionPool`.
protocol HTTP1RequestQueuer {
    func cancelRequest(task: HTTPRequestTask)
}

/// A handle to the request executor.
///
/// This protocol is implemented by the `HTTP1ClientChannelHandler`.
protocol HTTP1RequestExecutor {
    
    /// Writes a body part into the channel pipeline
    func writeRequestBodyPart(_: IOData, task: HTTPRequestTask)

    /// Signals that the request body stream has finished
    func finishRequestBodyStream(task: HTTPRequestTask)

    /// Signals that more bytes from response body stream can be consumed.
    ///
    /// The request executor will call `receiveResponseBodyPart(_ buffer: ByteBuffer)` with more data after
    /// this call.
    func demandResponseBodyStream(task: HTTPRequestTask)

    /// Signals that the request has been cancelled.
    func cancelRequest(task: HTTPRequestTask)
}

/// An abstraction over a request.
protocol HTTPRequestTask: AnyObject {
    var request: HTTPClient.Request { get }
    var logger: Logger { get }

    /// The delegates EventLoop
    var eventLoop: EventLoop { get }

    var connectionDeadline: NIODeadline { get }
    var idleReadTimeout: TimeAmount? { get }

    var eventLoopPreference: HTTPClient.EventLoopPreference { get }

    /// Informs the task, that it was queued for execution
    ///
    /// This happens if all available connections are currently in use
    func requestWasQueued(_: HTTP1RequestQueuer)

    /// Informs the task about the connection it will be executed on
    ///
    /// This is only here to allow existing tests to pass. We should rework this ASAP to get rid of this functionality
    func willBeExecutedOnConnection(_: HTTPConnectionPool.Connection)

    /// Will be called by the ChannelHandler to indicate that the request is going to be send.
    ///
    /// This will be called on the Channel's EventLoop. Do **not block** during your execution!
    ///
    /// - Returns: A bool indicating if the request should really be started. Return false if the request has already been cancelled.
    ///            If the request is cancelled after this method call `executor.cancel()` to stop request execution.
    func willExecuteRequest(_: HTTP1RequestExecutor) -> Bool

    /// Will be called by the ChannelHandler to indicate that the request head has been sent.
    func requestHeadSent(_: HTTPRequestHead)

    /// Start request streaming
    func startRequestBodyStream()

    /// Pause request streaming
    func pauseRequestBodyStream()

    /// Pause request streaming
    func resumeRequestBodyStream()

    func receiveResponseHead(_ head: HTTPResponseHead)
    func receiveResponseBodyPart(_ buffer: ByteBuffer)
    func receiveResponseEnd()

    func fail(_ error: Error)
}

