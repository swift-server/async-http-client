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
import NIOSSL

/// # Protocol Overview
///
/// To support different public request APIs we abstract the actual request implementations behind
/// protocols. During the lifetime of a request, a request must conform to different protocols
/// depending on which state it is in.
///
/// Generally there are two main states in a request's lifetime:
///
///   1. **The request is scheduled to be run.**
///     In this state the HTTP client tries to acquire a connection for the request, and the request
///     may need to wait for a connection
///   2. **The request is executing.**
///     In this state the request was written to a NIO channel. A NIO channel handler (abstracted
///     by the `HTTPRequestExecutor` protocol) writes the request's bytes onto the wire and
///     dispatches the http response bytes back to the response.
///
///
/// ## Request is scheduled
///
/// When the `HTTPClient` shall send an HTTP request, it will use its `HTTPConnectionPool.Manager` to
/// determine the `HTTPConnectionPool` to run the request on. After a `HTTPConnectionPool` has been
/// found for the request, the request will be executed on this connection pool. Since the HTTP
/// request implements the `HTTPSchedulableRequest` protocol, the HTTP connection pool can communicate
/// with the request. The `HTTPConnectionPool` implements the `HTTPRequestScheduler` protocol.
///
///   1. The `HTTPConnectionPool` tries to find an idle connection for the request based on its
///     `eventLoopPreference`.
///
///   2. If an idle connection is available to the request, the request will be passed to the
///     connection right away. In this case the `HTTPConnectionPool` will only use the
///     `HTTPSchedulableRequest`'s `eventLoopPreference` property. No other methods will be called.
///
///   3. If no idle connection is available to the request, the request will be queued for execution:
///       - The `HTTPConnectionPool` will inform the request that it is queued for execution by
///         calling: `requestWasQueued(_: HTTPRequestScheduler)`. The request must store a reference
///         to the `HTTPRequestScheduler`. The request must call `cancelRequest(self)` on the
///         scheduler, if the request was cancelled, while waiting for execution.
///       - The `HTTPConnectionPool` will create a connection deadline based on the
///         `HTTPSchedulableRequest`'s `connectionDeadline` property. If a connection to execute the
///         request on, was not found before this deadline the request will be failed.
///       - The HTTPConnectionPool will call `fail(_: Error)` on the `HTTPSchedulableRequest` to
///         inform the request about having overrun the `connectionDeadline`.
///
///
/// ## Request is executing
///
/// After the `HTTPConnectionPool` has identified a connection for the request to be run on, it will
/// execute the request on this connection. (Implementation detail: This happens by writing the
/// `HTTPExecutableRequest` to a `NIO.Channel`. We expect the last handler in the `ChannelPipeline`
/// to have an `OutboundIn` type of `HTTPExecutableRequest`. Further we expect that the handler
/// also conforms to the protocol `HTTPRequestExecutor` to allow communication of the request with
/// the executor/`ChannelHandler`).
///
/// The request execution will work as follows:
///
///   1. The request executor will call `willExecuteRequest(_: HTTPRequestExecutor)` on the
///     request. The request is expected to keep a reference to the `HTTPRequestExecutor` that was
///     passed to the request for further communication.
///   2. The request sending is started by the executor accessing the `HTTPExecutableRequest`'s
///     property `requestHead: HTTPRequestHead`. Based on the `requestHead` the executor can
///     determine if the request has a body (Is a "content-length" or "transfer-encoding"
///     header present?).
///   3. The executor will write the request's header into the Channel. If no body is present, the
///     executor will also write a request end into the Channel. After this the executor will call
///     `requestHeadSent(_: HTTPRequestHead)`
///   4. If the request has a body the request executor will, ask the request for body data, by
///     calling `startRequestBodyStream()`. The request is expected to call
///     `writeRequestBodyPart(_: IOData, task: HTTPExecutableRequest)` on the executor with body
///     data.
///       - The executor can signal backpressure to the request by calling
///         `pauseRequestBodyStream()`. In this case the request is expected to stop calling
///         `writeRequestBodyPart(_: IOData, task: HTTPExecutableRequest)`. However because of race
///         conditions the executor is prepared to process more data, even though it asked the
///         request to pause.
///       - Once the executor is able to send more data, it will notify the request by calling
///         `resumeRequestBodyStream()` on the request.
///       - The request shall call `finishRequestBodyStream()` on the executor to signal that the
///         request body was sent.
///   5. Once the executor receives a http response from the Channel, it will forward the http
///     response head to the `HTTPExecutableRequest` by calling `receiveResponseHead` on it.
///       - The executor will forward all the response body parts it receives in a single read to
///         the `HTTPExecutableRequest` without any buffering by calling
///         `receiveResponseBodyPart(_ buffer: ByteBuffer)` right away. It is the task's job to
///         buffer the responses for user consumption.
///       - Once the executor has finished a read, it will not schedule another read, until the
///         request calls `demandResponseBodyStream(task: HTTPExecutableRequest)` on the executor.
///       - Once the executor has received the response's end, it will forward this message by
///         calling `receiveResponseEnd()` on the `HTTPExecutableRequest`.
///   6. If a channel error occurs during the execution of the request, or if the channel becomes
///     inactive the executor will notify the request by calling `fail(_ error: Error)` on it.
///   7. If the request is cancelled, while it is executing on the executor, it must call
///     `cancelRequest(task: HTTPExecutableRequest)` on the executor.
///
///
/// ## Further notes
///
///   - These protocols makes no guarantees about thread safety at all. It is implementations job to
///    ensure thread safety.
///  - However all calls to the `HTTPRequestScheduler` and `HTTPRequestExecutor` require that the
///    invoking request is passed along. This helps the scheduler and executor in race conditions.
///    Example:
///      - The executor may have received an error in thread A that it passes along to the request.
///        After having passed on the error, the executor considers the request done and releases
///        the request's reference.
///      - The request may issue a call to `writeRequestBodyPart(_: IOData, task: HTTPExecutableRequest)`
///        on thread B in the same moment the request error above occurred. For this reason it may
///        happen that the executor receives, the invocation of `writeRequestBodyPart` after it has
///        failed the request.
///    Passing along the requests reference helps the executor and scheduler verify its internal
///    state.

/// A handle to the request scheduler.
///
/// Use this handle to cancel the request, while it is waiting for a free connection, to execute the request.
/// This protocol is only intended to be implemented by the `HTTPConnectionPool`.
protocol HTTPRequestScheduler: Sendable {
    /// Informs the task queuer that a request has been cancelled.
    func cancelRequest(_: HTTPSchedulableRequest)
}

/// An abstraction over a request that we want to send. A request may need to communicate with its request
/// queuer and executor. The client's methods will be called synchronously on an `EventLoop` by the
/// executor. For this reason it is very important that the implementation of these functions never blocks.
protocol HTTPSchedulableRequest: HTTPExecutableRequest {
    /// The tasks connection pool key
    ///
    /// Based on this key the correct connection pool will be chosen for the request
    var poolKey: ConnectionPool.Key { get }

    /// An optional custom `TLSConfiguration`.
    ///
    /// If you want to override the default `TLSConfiguration` ensure that this property is non nil
    var tlsConfiguration: TLSConfiguration? { get }

    /// The task's logger
    var logger: Logger { get }

    /// A connection to run this task on needs to be found before this deadline!
    var connectionDeadline: NIODeadline { get }

    /// The user has expressed an intent for this request to be executed on this EventLoop. If a
    /// connection is available on another one, just use the one handy.
    var preferredEventLoop: EventLoop { get }

    /// The user required the request to be executed on a connection that is handled by this EventLoop.
    var requiredEventLoop: EventLoop? { get }

    /// Informs the task, that it was queued for execution
    ///
    /// This happens if all available connections are currently in use
    func requestWasQueued(_: HTTPRequestScheduler)

    /// Fails the queued request, with an error.
    func fail(_ error: Error)
}

/// A handle to the request executor.
///
/// This protocol is implemented by the `HTTP1ClientChannelHandler`.
protocol HTTPRequestExecutor: Sendable {
    /// Writes a body part into the channel pipeline
    ///
    /// This method may be **called on any thread**. The executor needs to ensure thread safety.
    func writeRequestBodyPart(_: IOData, request: HTTPExecutableRequest, promise: EventLoopPromise<Void>?)

    /// Signals that the request body stream has finished
    ///
    /// This method may be **called on any thread**. The executor needs to ensure thread safety.
    func finishRequestBodyStream(_ task: HTTPExecutableRequest, promise: EventLoopPromise<Void>?)

    /// Signals that more bytes from response body stream can be consumed.
    ///
    /// The request executor will call `receiveResponseBodyPart(_ buffer: ByteBuffer)` with more data after
    /// this call.
    ///
    /// This method may be **called on any thread**. The executor needs to ensure thread safety.
    func demandResponseBodyStream(_ task: HTTPExecutableRequest)

    /// Signals that the request has been cancelled.
    ///
    /// This method may be **called on any thread**. The executor needs to ensure thread safety.
    func cancelRequest(_ task: HTTPExecutableRequest)
}

protocol HTTPExecutableRequest: AnyObject, Sendable {
    /// The request's logger
    var logger: Logger { get }

    /// The request's head.
    ///
    /// The HTTP request head, that shall be sent. The HTTPRequestExecutor **will not** run any validation
    /// check on the request head. All necessary metadata about the request head the executor expects in
    /// the ``requestFramingMetadata``.
    var requestHead: HTTPRequestHead { get }

    /// The request's framing metadata.
    ///
    /// The request framing metadata that is derived from the ``requestHead``. Based on the content of the
    /// request framing metadata the executor will call ``startRequestBodyStream`` after
    /// ``requestHeadSent``.
    var requestFramingMetadata: RequestFramingMetadata { get }

    /// Request specific configurations
    var requestOptions: RequestOptions { get }

    /// Will be called by the ChannelHandler to indicate that the request is going to be sent.
    ///
    /// This will be called on the Channel's EventLoop. Do **not block** during your execution! If the
    /// request is cancelled after the `willExecuteRequest` method was called. The executing
    /// request must call `executor.cancel()` to stop request execution.
    func willExecuteRequest(_: HTTPRequestExecutor)

    /// Will be called by the ChannelHandler to indicate that the request head has been sent.
    ///
    /// This will be called on the Channel's EventLoop. Do **not block** during your execution!
    func requestHeadSent()

    /// Start or resume request body streaming
    ///
    /// This will be called on the Channel's EventLoop. Do **not block** during your execution!
    func resumeRequestBodyStream()

    /// Pause request streaming
    ///
    /// This will be called on the Channel's EventLoop. Do **not block** during your execution!
    func pauseRequestBodyStream()

    /// Receive a response head.
    ///
    /// Please note that `receiveResponseHead` and `receiveResponseBodyPart` may
    /// be called in quick succession. It is the task's job to buffer those events for the user. Once all
    /// buffered data has been consumed the task must call `executor.demandResponseBodyStream`
    /// to ask for more data.
    func receiveResponseHead(_ head: HTTPResponseHead)

    /// Receive response body stream parts.
    ///
    /// Please note that `receiveResponseHead` and `receiveResponseBodyPart` may
    /// be called in quick succession. It is the task's job to buffer those events for the user. Once all
    /// buffered data has been consumed the task must call `executor.demandResponseBodyStream`
    /// to ask for more data.
    func receiveResponseBodyParts(_ buffer: CircularBuffer<ByteBuffer>)

    /// Finishes the server response.
    ///
    /// - Parameters:
    ///   - buffer: The remaining response body parts, that were received before the response end
    ///   - trailers: The response trailers if any where received. Nil means no trailers were received.
    func receiveResponseEnd(_ buffer: CircularBuffer<ByteBuffer>?, trailers: HTTPHeaders?)

    /// Fails the executing request, with an error.
    func fail(_ error: Error)
}
