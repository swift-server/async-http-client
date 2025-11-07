//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the AsyncHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Algorithms
import Foundation
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import Tracing

extension HTTPClient {
    /// A request body.
    public struct Body: Sendable {
        /// A streaming uploader.
        ///
        /// ``StreamWriter`` abstracts
        public struct StreamWriter: Sendable {
            let closure: @Sendable (IOData) -> EventLoopFuture<Void>

            /// Create new ``HTTPClient/Body/StreamWriter``
            ///
            /// - parameters:
            ///     - closure: function that will be called to write actual bytes to the channel.
            @preconcurrency
            public init(closure: @escaping @Sendable (IOData) -> EventLoopFuture<Void>) {
                self.closure = closure
            }

            /// Write data to server.
            ///
            /// - parameters:
            ///     - data: `IOData` to write.
            public func write(_ data: IOData) -> EventLoopFuture<Void> {
                self.closure(data)
            }

            @inlinable
            func writeChunks<Bytes: Collection>(
                of bytes: Bytes,
                maxChunkSize: Int
            ) -> EventLoopFuture<Void> where Bytes.Element == UInt8, Bytes: Sendable {
                // `StreamWriter` has design issues, for example
                // - https://github.com/swift-server/async-http-client/issues/194
                // - https://github.com/swift-server/async-http-client/issues/264
                // - We're not told the EventLoop the task runs on and the user is free to return whatever EL they
                //   want.
                // One important consideration then is that we must lock around the iterator because we could be hopping
                // between threads.
                typealias Iterator = EnumeratedSequence<ChunksOfCountCollection<Bytes>>.Iterator
                typealias Chunk = (offset: Int, element: ChunksOfCountCollection<Bytes>.Element)

                // HACK (again, we're not told the right EventLoop): Let's write 0 bytes to make the user tell us...
                return self.write(.byteBuffer(ByteBuffer())).flatMapWithEventLoop { (_, loop) in
                    func makeIteratorAndFirstChunk(
                        bytes: Bytes
                    ) -> (iterator: Iterator, chunk: Chunk)? {
                        var iterator = bytes.chunks(ofCount: maxChunkSize).enumerated().makeIterator()
                        guard let chunk = iterator.next() else {
                            return nil
                        }

                        return (iterator, chunk)
                    }

                    guard let iteratorAndChunk = makeIteratorAndFirstChunk(bytes: bytes) else {
                        return loop.makeSucceededVoidFuture()
                    }

                    var iterator = iteratorAndChunk.0
                    let chunk = iteratorAndChunk.1

                    // can't use closure here as we recursively call ourselves which closures can't do
                    func writeNextChunk(_ chunk: Chunk, allDone: EventLoopPromise<Void>) {
                        let loop = allDone.futureResult.eventLoop
                        loop.assertInEventLoop()

                        if let (index, element) = iterator.next() {
                            self.write(.byteBuffer(ByteBuffer(bytes: chunk.element))).hop(to: loop).assumeIsolated().map
                            {
                                if (index + 1) % 4 == 0 {
                                    // Let's not stack-overflow if the futures insta-complete which they at least in HTTP/2
                                    // mode.
                                    // Also, we must frequently return to the EventLoop because we may get the pause signal
                                    // from another thread. If we fail to do that promptly, we may balloon our body chunks
                                    // into memory.
                                    allDone.futureResult.eventLoop.assumeIsolated().execute {
                                        writeNextChunk((offset: index, element: element), allDone: allDone)
                                    }
                                } else {
                                    writeNextChunk((offset: index, element: element), allDone: allDone)
                                }
                            }.nonisolated().cascadeFailure(to: allDone)
                        } else {
                            self.write(.byteBuffer(ByteBuffer(bytes: chunk.element))).cascade(to: allDone)
                        }
                    }

                    let allDone = loop.makePromise(of: Void.self)
                    writeNextChunk(chunk, allDone: allDone)
                    return allDone.futureResult
                }
            }
        }

        /// Body size. If nil,`Transfer-Encoding` will automatically be set to `chunked`. Otherwise a `Content-Length`
        /// header is set with the given `length`.
        @available(*, deprecated, renamed: "contentLength")
        public var length: Int? {
            get {
                self.contentLength.flatMap { Int($0) }
            }
            set {
                self.contentLength = newValue.flatMap { Int64($0) }
            }
        }

        /// Body size. If nil,`Transfer-Encoding` will automatically be set to `chunked`. Otherwise a `Content-Length`
        /// header is set with the given `contentLength`.
        public var contentLength: Int64?

        /// Body chunk provider.
        public var stream: @Sendable (StreamWriter) -> EventLoopFuture<Void>

        @usableFromInline typealias StreamCallback = @Sendable (StreamWriter) -> EventLoopFuture<Void>

        @inlinable
        init(contentLength: Int64?, stream: @escaping StreamCallback) {
            self.contentLength = contentLength.flatMap { $0 }
            self.stream = stream
        }

        /// Create and stream body using `ByteBuffer`.
        ///
        /// - parameters:
        ///     - buffer: Body `ByteBuffer` representation.
        public static func byteBuffer(_ buffer: ByteBuffer) -> Body {
            Body(contentLength: Int64(buffer.readableBytes)) { writer in
                writer.write(.byteBuffer(buffer))
            }
        }

        /// Create and stream body using ``StreamWriter``.
        ///
        /// - parameters:
        ///     - length: Body size. If nil, `Transfer-Encoding` will automatically be set to `chunked`. Otherwise a `Content-Length`
        /// header is set with the given `length`.
        ///     - stream: Body chunk provider.
        @_disfavoredOverload
        @preconcurrency
        public static func stream(
            length: Int? = nil,
            _ stream: @Sendable @escaping (StreamWriter) -> EventLoopFuture<Void>
        ) -> Body {
            Body(contentLength: length.flatMap { Int64($0) }, stream: stream)
        }

        /// Create and stream body using ``StreamWriter``.
        ///
        /// - parameters:
        ///     - contentLength: Body size. If nil, `Transfer-Encoding` will automatically be set to `chunked`. Otherwise a `Content-Length`
        /// header is set with the given `contentLength`.
        ///     - stream: Body chunk provider.
        public static func stream(
            contentLength: Int64? = nil,
            _ stream: @Sendable @escaping (StreamWriter) -> EventLoopFuture<Void>
        ) -> Body {
            Body(contentLength: contentLength, stream: stream)
        }

        /// Create and stream body using a collection of bytes.
        ///
        /// - parameters:
        ///     - bytes: Body binary representation.
        @preconcurrency
        @inlinable
        public static func bytes<Bytes>(_ bytes: Bytes) -> Body
        where Bytes: RandomAccessCollection, Bytes: Sendable, Bytes.Element == UInt8 {
            Body(contentLength: Int64(bytes.count)) { writer in
                if bytes.count <= bagOfBytesToByteBufferConversionChunkSize {
                    return writer.write(.byteBuffer(ByteBuffer(bytes: bytes)))
                } else {
                    return writer.writeChunks(of: bytes, maxChunkSize: bagOfBytesToByteBufferConversionChunkSize)
                }
            }
        }

        /// Create and stream body using `String`.
        ///
        /// - parameters:
        ///     - string: Body `String` representation.
        public static func string(_ string: String) -> Body {
            Body(contentLength: Int64(string.utf8.count)) { writer in
                if string.utf8.count <= bagOfBytesToByteBufferConversionChunkSize {
                    return writer.write(.byteBuffer(ByteBuffer(string: string)))
                } else {
                    return writer.writeChunks(of: string.utf8, maxChunkSize: bagOfBytesToByteBufferConversionChunkSize)
                }
            }
        }
    }

    /// Represents an HTTP request.
    public struct Request: Sendable {
        /// Request HTTP method, defaults to `GET`.
        public let method: HTTPMethod
        /// Remote URL.
        public let url: URL

        /// Remote HTTP scheme, resolved from `URL`.
        public var scheme: String {
            self.deconstructedURL.scheme.rawValue
        }

        /// Request custom HTTP Headers, defaults to no headers.
        public var headers: HTTPHeaders
        /// Request body, defaults to no body.
        public var body: Body?
        /// Request-specific TLS configuration, defaults to no request-specific TLS configuration.
        public var tlsConfiguration: TLSConfiguration?

        /// Parsed, validated and deconstructed URL.
        let deconstructedURL: DeconstructedURL

        /// Create HTTP request.
        ///
        /// - parameters:
        ///     - url: Remote `URL`.
        ///     - method: HTTP method.
        ///     - headers: Custom HTTP headers.
        ///     - body: Request body.
        /// - throws:
        ///     - `invalidURL` if URL cannot be parsed.
        ///     - `emptyScheme` if URL does not contain HTTP scheme.
        ///     - `unsupportedScheme` if URL does contains unsupported HTTP scheme.
        ///     - `emptyHost` if URL does not contains a host.
        public init(
            url: String,
            method: HTTPMethod = .GET,
            headers: HTTPHeaders = HTTPHeaders(),
            body: Body? = nil
        ) throws {
            try self.init(url: url, method: method, headers: headers, body: body, tlsConfiguration: nil)
        }

        /// Create HTTP request.
        ///
        /// - parameters:
        ///     - url: Remote `URL`.
        ///     - method: HTTP method.
        ///     - headers: Custom HTTP headers.
        ///     - body: Request body.
        ///     - tlsConfiguration: Request TLS configuration
        /// - throws:
        ///     - `invalidURL` if URL cannot be parsed.
        ///     - `emptyScheme` if URL does not contain HTTP scheme.
        ///     - `unsupportedScheme` if URL does contains unsupported HTTP scheme.
        ///     - `emptyHost` if URL does not contains a host.
        public init(
            url: String,
            method: HTTPMethod = .GET,
            headers: HTTPHeaders = HTTPHeaders(),
            body: Body? = nil,
            tlsConfiguration: TLSConfiguration?
        ) throws {
            guard let url = URL(string: url) else {
                throw HTTPClientError.invalidURL
            }

            try self.init(url: url, method: method, headers: headers, body: body, tlsConfiguration: tlsConfiguration)
        }

        /// Create an HTTP `Request`.
        ///
        /// - parameters:
        ///     - url: Remote `URL`.
        ///     - method: HTTP method.
        ///     - headers: Custom HTTP headers.
        ///     - body: Request body.
        /// - throws:
        ///     - `emptyScheme` if URL does not contain HTTP scheme.
        ///     - `unsupportedScheme` if URL does contains unsupported HTTP scheme.
        ///     - `emptyHost` if URL does not contains a host.
        ///     - `missingSocketPath` if URL does not contains a socketPath as an encoded host.
        public init(url: URL, method: HTTPMethod = .GET, headers: HTTPHeaders = HTTPHeaders(), body: Body? = nil) throws
        {
            try self.init(url: url, method: method, headers: headers, body: body, tlsConfiguration: nil)
        }

        /// Create an HTTP `Request`.
        ///
        /// - parameters:
        ///     - url: Remote `URL`.
        ///     - method: HTTP method.
        ///     - headers: Custom HTTP headers.
        ///     - body: Request body.
        ///     - tlsConfiguration: Request TLS configuration
        /// - throws:
        ///     - `emptyScheme` if URL does not contain HTTP scheme.
        ///     - `unsupportedScheme` if URL does contains unsupported HTTP scheme.
        ///     - `emptyHost` if URL does not contains a host.
        ///     - `missingSocketPath` if URL does not contains a socketPath as an encoded host.
        public init(
            url: URL,
            method: HTTPMethod = .GET,
            headers: HTTPHeaders = HTTPHeaders(),
            body: Body? = nil,
            tlsConfiguration: TLSConfiguration?
        ) throws {
            self.deconstructedURL = try DeconstructedURL(url: url)

            self.url = url
            self.method = method
            self.headers = headers
            self.body = body
            self.tlsConfiguration = tlsConfiguration
        }

        /// Remote host, resolved from `URL`.
        public var host: String {
            self.deconstructedURL.connectionTarget.host ?? ""
        }

        /// Resolved port.
        public var port: Int {
            self.deconstructedURL.connectionTarget.port ?? self.deconstructedURL.scheme.defaultPort
        }

        /// Whether request will be executed using secure socket.
        public var useTLS: Bool { self.deconstructedURL.scheme.usesTLS }

        func createRequestHead() throws -> (HTTPRequestHead, RequestFramingMetadata) {
            var head = HTTPRequestHead(
                version: .http1_1,
                method: self.method,
                uri: self.deconstructedURL.uri,
                headers: self.headers
            )

            head.headers.addHostIfNeeded(for: self.deconstructedURL)

            let metadata = try head.headers.validateAndSetTransportFraming(
                method: self.method,
                bodyLength: .init(self.body)
            )

            return (head, metadata)
        }

        /// Set basic auth for a request.
        ///
        /// - parameters:
        ///     - username: the username to authenticate with
        ///     - password: authentication password associated with the username
        public mutating func setBasicAuth(username: String, password: String) {
            self.headers.setBasicAuth(username: username, password: password)
        }
    }

    /// Represents an HTTP response.
    public struct Response: Sendable {
        /// Remote host of the request.
        public var host: String
        /// Response HTTP status.
        public var status: HTTPResponseStatus
        /// Response HTTP version.
        public var version: HTTPVersion
        /// Reponse HTTP headers.
        public var headers: HTTPHeaders
        /// Response body.
        public var body: ByteBuffer?
        /// The history of all requests and responses in redirect order.
        public var history: [RequestResponse]

        /// The target URL (after redirects) of the response.
        public var url: URL? {
            self.history.last?.request.url
        }

        /// Create HTTP `Response`.
        ///
        /// - parameters:
        ///     - host: Remote host of the request.
        ///     - status: Response HTTP status.
        ///     - headers: Reponse HTTP headers.
        ///     - body: Response body.
        @available(*, deprecated, renamed: "init(host:status:version:headers:body:)")
        public init(host: String, status: HTTPResponseStatus, headers: HTTPHeaders, body: ByteBuffer?) {
            self.host = host
            self.status = status
            self.version = HTTPVersion(major: 1, minor: 1)
            self.headers = headers
            self.body = body
            self.history = []
        }

        /// Create HTTP `Response`.
        ///
        /// - parameters:
        ///     - host: Remote host of the request.
        ///     - status: Response HTTP status.
        ///     - version: Response HTTP version.
        ///     - headers: Reponse HTTP headers.
        ///     - body: Response body.
        public init(
            host: String,
            status: HTTPResponseStatus,
            version: HTTPVersion,
            headers: HTTPHeaders,
            body: ByteBuffer?
        ) {
            self.host = host
            self.status = status
            self.version = version
            self.headers = headers
            self.body = body
            self.history = []
        }

        /// Create HTTP `Response`.
        ///
        /// - parameters:
        ///     - host: Remote host of the request.
        ///     - status: Response HTTP status.
        ///     - version: Response HTTP version.
        ///     - headers: Reponse HTTP headers.
        ///     - body: Response body.
        ///     - history: History of all requests and responses in redirect order.
        public init(
            host: String,
            status: HTTPResponseStatus,
            version: HTTPVersion,
            headers: HTTPHeaders,
            body: ByteBuffer?,
            history: [RequestResponse]
        ) {
            self.host = host
            self.status = status
            self.version = version
            self.headers = headers
            self.body = body
            self.history = history
        }
    }

    /// HTTP authentication.
    public struct Authorization: Hashable, Sendable {
        private enum Scheme: Hashable {
            case Basic(String)
            case Bearer(String)
        }

        private let scheme: Scheme

        private init(scheme: Scheme) {
            self.scheme = scheme
        }

        /// HTTP basic auth.
        public static func basic(username: String, password: String) -> HTTPClient.Authorization {
            .basic(credentials: Base64.encode(bytes: "\(username):\(password)".utf8))
        }

        /// HTTP basic auth.
        ///
        /// This version uses the raw string directly.
        public static func basic(credentials: String) -> HTTPClient.Authorization {
            .init(scheme: .Basic(credentials))
        }

        /// HTTP bearer auth
        public static func bearer(tokens: String) -> HTTPClient.Authorization {
            .init(scheme: .Bearer(tokens))
        }

        /// The header string for this auth field.
        public var headerValue: String {
            switch self.scheme {
            case .Basic(let credentials):
                return "Basic \(credentials)"
            case .Bearer(let tokens):
                return "Bearer \(tokens)"
            }
        }
    }

    public struct RequestResponse: Sendable {
        public var request: Request
        public var responseHead: HTTPResponseHead

        public init(request: Request, responseHead: HTTPResponseHead) {
            self.request = request
            self.responseHead = responseHead
        }
    }
}

/// The default ``HTTPClientResponseDelegate``.
///
/// This ``HTTPClientResponseDelegate`` buffers a complete HTTP response in memory. It does not stream the response body in.
/// The resulting ``Response`` type is ``HTTPClient/Response``.
public final class ResponseAccumulator: HTTPClientResponseDelegate {
    public typealias Response = HTTPClient.Response

    enum State {
        case idle
        case head(HTTPResponseHead)
        case body(HTTPResponseHead, ByteBuffer)
        case end
        case error(Error)
    }

    public struct ResponseTooBigError: Error, CustomStringConvertible {
        public var maxBodySize: Int
        public init(maxBodySize: Int) {
            self.maxBodySize = maxBodySize
        }

        public var description: String {
            "ResponseTooBigError: received response body exceeds maximum accepted size of \(self.maxBodySize) bytes"
        }
    }

    private struct MutableState: Sendable {
        var history = [HTTPClient.RequestResponse]()
        var state = State.idle
    }

    private let state: NIOLockedValueBox<MutableState>
    let requestMethod: HTTPMethod
    let requestHost: String

    static let maxByteBufferSize = Int(UInt32.max)

    /// Maximum size in bytes of the HTTP response body that ``ResponseAccumulator`` will accept
    /// until it will abort the request and throw an ``ResponseTooBigError``.
    ///
    /// Default is 2^32.
    /// - precondition: not allowed to exceed 2^32 because `ByteBuffer` can not store more bytes
    public let maxBodySize: Int

    public convenience init(request: HTTPClient.Request) {
        self.init(request: request, maxBodySize: Self.maxByteBufferSize)
    }

    /// - Parameters:
    ///   - request: The corresponding request of the response this delegate will be accumulating.
    ///   - maxBodySize: Maximum size in bytes of the HTTP response body that ``ResponseAccumulator`` will accept
    ///   until it will abort the request and throw an ``ResponseTooBigError``.
    ///   Default is 2^32.
    /// - precondition: maxBodySize is not allowed to exceed 2^32 because `ByteBuffer` can not store more bytes
    /// - warning: You can use ``ResponseAccumulator`` for just one request.
    /// If you start another request, you need to initiate another ``ResponseAccumulator``.
    public init(request: HTTPClient.Request, maxBodySize: Int) {
        precondition(maxBodySize >= 0, "maxBodyLength is not allowed to be negative")
        precondition(
            maxBodySize <= Self.maxByteBufferSize,
            "maxBodyLength is not allowed to exceed 2^32 because ByteBuffer can not store more bytes"
        )
        self.requestMethod = request.method
        self.requestHost = request.host
        self.maxBodySize = maxBodySize
        self.state = NIOLockedValueBox(MutableState())
    }

    public func didVisitURL(
        task: HTTPClient.Task<HTTPClient.Response>,
        _ request: HTTPClient.Request,
        _ head: HTTPResponseHead
    ) {
        self.state.withLockedValue {
            $0.history.append(.init(request: request, responseHead: head))
        }
    }

    public func didReceiveHead(task: HTTPClient.Task<Response>, _ head: HTTPResponseHead) -> EventLoopFuture<Void> {
        let responseTooBig: Bool

        if self.requestMethod != .HEAD,
            let contentLength = head.headers.first(name: "Content-Length"),
            let announcedBodySize = Int(contentLength),
            announcedBodySize > self.maxBodySize
        {
            responseTooBig = true
        } else {
            responseTooBig = false
        }

        return self.state.withLockedValue {
            switch $0.state {
            case .idle:
                if responseTooBig {
                    let error = ResponseTooBigError(maxBodySize: self.maxBodySize)
                    $0.state = .error(error)
                    return task.eventLoop.makeFailedFuture(error)
                }

                $0.state = .head(head)
            case .head:
                preconditionFailure("head already set")
            case .body:
                preconditionFailure("no head received before body")
            case .end:
                preconditionFailure("request already processed")
            case .error:
                break
            }
            return task.eventLoop.makeSucceededFuture(())
        }
    }

    public func didReceiveBodyPart(task: HTTPClient.Task<Response>, _ part: ByteBuffer) -> EventLoopFuture<Void> {
        self.state.withLockedValue {
            switch $0.state {
            case .idle:
                preconditionFailure("no head received before body")
            case .head(let head):
                guard part.readableBytes <= self.maxBodySize else {
                    let error = ResponseTooBigError(maxBodySize: self.maxBodySize)
                    $0.state = .error(error)
                    return task.eventLoop.makeFailedFuture(error)
                }
                $0.state = .body(head, part)
            case .body(let head, var body):
                let newBufferSize = body.writerIndex + part.readableBytes
                guard newBufferSize <= self.maxBodySize else {
                    let error = ResponseTooBigError(maxBodySize: self.maxBodySize)
                    $0.state = .error(error)
                    return task.eventLoop.makeFailedFuture(error)
                }

                // The compiler can't prove that `self.state` is dead here (and it kinda isn't, there's
                // a cross-module call in the way) so we need to drop the original reference to `body` in
                // `self.state` or we'll get a CoW. To fix that we temporarily set the state to `.end` (which
                // has no associated data). We'll fix it at the bottom of this block.
                $0.state = .end
                var part = part
                body.writeBuffer(&part)
                $0.state = .body(head, body)
            case .end:
                preconditionFailure("request already processed")
            case .error:
                break
            }
            return task.eventLoop.makeSucceededFuture(())
        }
    }

    public func didReceiveError(task: HTTPClient.Task<Response>, _ error: Error) {
        self.state.withLockedValue {
            $0.state = .error(error)
        }
    }

    public func didFinishRequest(task: HTTPClient.Task<Response>) throws -> Response {
        try self.state.withLockedValue {
            switch $0.state {
            case .idle:
                preconditionFailure("no head received before end")
            case .head(let head):
                return Response(
                    host: self.requestHost,
                    status: head.status,
                    version: head.version,
                    headers: head.headers,
                    body: nil,
                    history: $0.history
                )
            case .body(let head, let body):
                return Response(
                    host: self.requestHost,
                    status: head.status,
                    version: head.version,
                    headers: head.headers,
                    body: body,
                    history: $0.history
                )
            case .end:
                preconditionFailure("request already processed")
            case .error(let error):
                throw error
            }
        }
    }
}

/// ``HTTPClientResponseDelegate`` allows an implementation to receive notifications about request processing and to control how response parts are processed.
///
/// You can implement this protocol if you need fine-grained control over an HTTP request/response, for example, if you want to inspect the response
/// headers before deciding whether to accept a response body, or if you want to stream your request body. Pass an instance of your conforming
/// class to the ``HTTPClient/execute(request:delegate:eventLoop:deadline:)`` method and this package will call each delegate method appropriately as the request takes place.
///
/// ### Backpressure
///
/// A ``HTTPClientResponseDelegate`` can be used to exert backpressure on the server response. This is achieved by way of the futures returned from
/// ``HTTPClientResponseDelegate/didReceiveHead(task:_:)-9r4xd`` and ``HTTPClientResponseDelegate/didReceiveBodyPart(task:_:)-4fd4v``.
/// The following functions are part of the "backpressure system" in the delegate:
///
/// - ``HTTPClientResponseDelegate/didReceiveHead(task:_:)-9r4xd``
/// - ``HTTPClientResponseDelegate/didReceiveBodyPart(task:_:)-4fd4v``
/// - ``HTTPClientResponseDelegate/didFinishRequest(task:)``
/// - ``HTTPClientResponseDelegate/didReceiveError(task:_:)-fhsg``
///
/// The first three methods are strictly _exclusive_, with that exclusivity managed by the futures returned by ``HTTPClientResponseDelegate/didReceiveHead(task:_:)-9r4xd`` and
/// ``HTTPClientResponseDelegate/didReceiveBodyPart(task:_:)-4fd4v``. What this means is that until the returned future is completed, none of these three methods will be called
/// again. This allows delegates to rate limit the server to a capacity it can manage. ``HTTPClientResponseDelegate/didFinishRequest(task:)`` does not return a future,
/// as we are expecting no more data from the server at this time.
///
/// ``HTTPClientResponseDelegate/didReceiveError(task:_:)-fhsg`` is somewhat special: it signals the end of this regime. ``HTTPClientResponseDelegate/didReceiveError(task:_:)-fhsg``
/// is not exclusive: it may be called at any time, even if a returned future is not yet completed. ``HTTPClientResponseDelegate/didReceiveError(task:_:)-fhsg`` is terminal, meaning
/// that once it has been called none of these four methods will be called again. This can be used as a signal to abandon all outstanding work.
///
///  - note: This delegate is strongly held by the `HTTPTaskHandler`
///          for the duration of the ``HTTPClient/Request`` processing and will be
///          released together with the `HTTPTaskHandler` when channel is closed.
///          Users of the library are not required to keep a reference to the
///          object that implements this protocol, but may do so if needed.
@preconcurrency
public protocol HTTPClientResponseDelegate: AnyObject, Sendable {
    associatedtype Response: Sendable

    /// Called when the request head is sent. Will be called once.
    ///
    /// - parameters:
    ///     - task: Current request context.
    ///     - head: Request head.
    func didSendRequestHead(task: HTTPClient.Task<Response>, _ head: HTTPRequestHead)

    /// Called when a part of the request body is sent. Could be called zero or more times.
    ///
    /// - parameters:
    ///     - task: Current request context.
    ///     - part: Request body part.
    func didSendRequestPart(task: HTTPClient.Task<Response>, _ part: IOData)

    /// Called when the request is fully sent. Will be called once.
    ///
    /// - parameters:
    ///     - task: Current request context.
    func didSendRequest(task: HTTPClient.Task<Response>)

    /// Called each time a response head is received (including redirects), and always called before ``HTTPClientResponseDelegate/didReceiveHead(task:_:)-9r4xd``.
    /// You can use this method to keep an entire history of the request/response chain.
    ///
    /// - parameters:
    ///     - task: Current request context.
    ///     - request: The request that was sent.
    ///     - head: Received response head.
    func didVisitURL(task: HTTPClient.Task<Response>, _ request: HTTPClient.Request, _ head: HTTPResponseHead)

    /// Called when the final response head is received (after redirects).
    /// You must return an `EventLoopFuture<Void>` that you complete when you have finished processing the body part.
    /// You can create an already succeeded future by calling `task.eventLoop.makeSucceededFuture(())`.
    ///
    /// - parameters:
    ///     - task: Current request context.
    ///     - head: Received reposonse head.
    /// - returns: `EventLoopFuture` that will be used for backpressure.
    func didReceiveHead(task: HTTPClient.Task<Response>, _ head: HTTPResponseHead) -> EventLoopFuture<Void>

    /// Called when part of a response body is received. Could be called zero or more times.
    /// You must return an `EventLoopFuture<Void>` that you complete when you have finished processing the body part.
    /// You can create an already succeeded future by calling `task.eventLoop.makeSucceededFuture(())`.
    ///
    /// This function will not be called until the future returned by ``HTTPClientResponseDelegate/didReceiveHead(task:_:)-9r4xd`` has completed.
    ///
    /// This function will not be called for subsequent body parts until the previous future returned by a
    /// call to this function completes.
    ///
    /// - parameters:
    ///     - task: Current request context.
    ///     - buffer: Received body `Part`.
    /// - returns: `EventLoopFuture` that will be used for backpressure.
    func didReceiveBodyPart(task: HTTPClient.Task<Response>, _ buffer: ByteBuffer) -> EventLoopFuture<Void>

    /// Called when error was thrown during request execution. Will be called zero or one time only. Request processing will be stopped after that.
    ///
    /// This function may be called at any time: it does not respect the backpressure exerted by ``HTTPClientResponseDelegate/didReceiveHead(task:_:)-9r4xd``
    /// and ``HTTPClientResponseDelegate/didReceiveBodyPart(task:_:)-4fd4v``.
    /// All outstanding work may be cancelled when this is received. Once called, no further calls will be made to
    /// ``HTTPClientResponseDelegate/didReceiveHead(task:_:)-9r4xd``, ``HTTPClientResponseDelegate/didReceiveBodyPart(task:_:)-4fd4v``,
    /// or ``HTTPClientResponseDelegate/didFinishRequest(task:)``.
    ///
    /// - parameters:
    ///     - task: Current request context.
    ///     - error: Error that occured during response processing.
    func didReceiveError(task: HTTPClient.Task<Response>, _ error: Error)

    /// Called when the complete HTTP request is finished. You must return an instance of your ``Response`` associated type. Will be called once, except if an error occurred.
    ///
    /// This function will not be called until all futures returned by ``HTTPClientResponseDelegate/didReceiveHead(task:_:)-9r4xd`` and ``HTTPClientResponseDelegate/didReceiveBodyPart(task:_:)-4fd4v``
    /// have completed. Once called, no further calls will be made to ``HTTPClientResponseDelegate/didReceiveHead(task:_:)-9r4xd``, ``HTTPClientResponseDelegate/didReceiveBodyPart(task:_:)-4fd4v``,
    /// or ``HTTPClientResponseDelegate/didReceiveError(task:_:)-fhsg``.
    ///
    /// - parameters:
    ///     - task: Current request context.
    /// - returns: Result of processing.
    func didFinishRequest(task: HTTPClient.Task<Response>) throws -> Response
}

extension HTTPClientResponseDelegate {
    /// Default implementation of ``HTTPClientResponseDelegate/didSendRequest(task:)-9od5p``.
    ///
    /// By default, this does nothing.
    public func didSendRequestHead(task: HTTPClient.Task<Response>, _ head: HTTPRequestHead) {}

    /// Default implementation of ``HTTPClientResponseDelegate/didSendRequestPart(task:_:)-4qxap``.
    ///
    /// By default, this does nothing.
    public func didSendRequestPart(task: HTTPClient.Task<Response>, _ part: IOData) {}

    /// Default implementation of ``HTTPClientResponseDelegate/didSendRequest(task:)-3vqgm``.
    ///
    /// By default, this does nothing.
    public func didSendRequest(task: HTTPClient.Task<Response>) {}

    /// Default implementation of ``HTTPClientResponseDelegate/didVisitURL(task:_:_:)-2el9y``.
    ///
    /// By default, this does nothing.
    public func didVisitURL(task: HTTPClient.Task<Response>, _: HTTPClient.Request, _: HTTPResponseHead) {}

    /// Default implementation of ``HTTPClientResponseDelegate/didReceiveHead(task:_:)-9r4xd``.
    ///
    /// By default, this does nothing.
    public func didReceiveHead(task: HTTPClient.Task<Response>, _: HTTPResponseHead) -> EventLoopFuture<Void> {
        task.eventLoop.makeSucceededVoidFuture()
    }

    /// Default implementation of ``HTTPClientResponseDelegate/didReceiveBodyPart(task:_:)-4fd4v``.
    ///
    /// By default, this does nothing.
    public func didReceiveBodyPart(task: HTTPClient.Task<Response>, _: ByteBuffer) -> EventLoopFuture<Void> {
        task.eventLoop.makeSucceededVoidFuture()
    }

    /// Default implementation of ``HTTPClientResponseDelegate/didReceiveError(task:_:)-fhsg``.
    ///
    /// By default, this does nothing.
    public func didReceiveError(task: HTTPClient.Task<Response>, _: Error) {}
}

extension URL {
    var percentEncodedPath: String {
        if self.path.isEmpty {
            return "/"
        }
        return URLComponents(url: self, resolvingAgainstBaseURL: true)?.percentEncodedPath ?? self.path
    }

    var uri: String {
        var uri = self.percentEncodedPath

        if let query = self.query {
            uri += "?" + query
        }

        return uri
    }

    func hasTheSameOrigin(as other: URL) -> Bool {
        self.host == other.host && self.scheme == other.scheme && self.port == other.port
    }

    /// Initializes a newly created HTTP URL connecting to a unix domain socket path. The socket path is encoded as the URL's host, replacing percent encoding invalid path characters, and will use the "http+unix" scheme.
    /// - Parameters:
    ///   - socketPath: The path to the unix domain socket to connect to.
    ///   - uri: The URI path and query that will be sent to the server.
    public init?(httpURLWithSocketPath socketPath: String, uri: String = "/") {
        guard let host = socketPath.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) else { return nil }
        var urlString: String
        if uri.hasPrefix("/") {
            urlString = "http+unix://\(host)\(uri)"
        } else {
            urlString = "http+unix://\(host)/\(uri)"
        }
        self.init(string: urlString)
    }

    /// Initializes a newly created HTTPS URL connecting to a unix domain socket path over TLS. The socket path is encoded as the URL's host, replacing percent encoding invalid path characters, and will use the "https+unix" scheme.
    /// - Parameters:
    ///   - socketPath: The path to the unix domain socket to connect to.
    ///   - uri: The URI path and query that will be sent to the server.
    public init?(httpsURLWithSocketPath socketPath: String, uri: String = "/") {
        guard let host = socketPath.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) else { return nil }
        var urlString: String
        if uri.hasPrefix("/") {
            urlString = "https+unix://\(host)\(uri)"
        } else {
            urlString = "https+unix://\(host)/\(uri)"
        }
        self.init(string: urlString)
    }
}

protocol HTTPClientTaskDelegate: Sendable {
    func fail(_ error: Error)
}

extension HTTPClient {
    /// Response execution context.
    ///
    /// Will be created by the library and could be used for obtaining
    /// `EventLoopFuture<Response>` of the execution or cancellation of the execution.
    public final class Task<Response>: Sendable {
        /// The `EventLoop` the delegate will be executed on.
        public let eventLoop: EventLoop
        /// The `Logger` used by the `Task` for logging.
        public let logger: Logger  // We are okay to store the logger here because a Task is for only one request.

        @available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
        public var tracer: (any Tracer)? {
            tracing.tracer
        }
        let tracing: TracingConfiguration

        let promise: EventLoopPromise<Response>

        struct State: Sendable {
            var isCancelled: Bool
            var taskDelegate: HTTPClientTaskDelegate?
        }

        private let state: NIOLockedValueBox<State>

        var isCancelled: Bool {
            self.state.withLockedValue { $0.isCancelled }
        }

        var taskDelegate: HTTPClientTaskDelegate? {
            get {
                self.state.withLockedValue { $0.taskDelegate }
            }
            set {
                self.state.withLockedValue { $0.taskDelegate = newValue }
            }
        }

        private let makeOrGetFileIOThreadPool: @Sendable () -> NIOThreadPool

        /// The shared thread pool of a ``HTTPClient`` used for file IO. It is lazily created on first access.
        internal var fileIOThreadPool: NIOThreadPool {
            self.makeOrGetFileIOThreadPool()
        }

        init(
            eventLoop: EventLoop,
            logger: Logger,
            tracing: TracingConfiguration,
            makeOrGetFileIOThreadPool: @escaping @Sendable () -> NIOThreadPool
        ) {
            self.eventLoop = eventLoop
            self.promise = eventLoop.makePromise()
            self.logger = logger
            self.tracing = tracing
            self.makeOrGetFileIOThreadPool = makeOrGetFileIOThreadPool
            self.state = NIOLockedValueBox(State(isCancelled: false, taskDelegate: nil))
        }

        static func failedTask(
            eventLoop: EventLoop,
            error: Error,
            logger: Logger,
            tracing: TracingConfiguration,
            makeOrGetFileIOThreadPool: @escaping @Sendable () -> NIOThreadPool
        ) -> Task<Response> {
            let task = self.init(
                eventLoop: eventLoop,
                logger: logger,
                tracing: tracing,
                makeOrGetFileIOThreadPool: makeOrGetFileIOThreadPool
            )
            task.promise.fail(error)
            return task
        }

        /// `EventLoopFuture` for the response returned by this request.
        public var futureResult: EventLoopFuture<Response> {
            self.promise.futureResult
        }

        /// Waits for execution of this request to complete.
        ///
        /// - returns: The value of  ``futureResult`` when it completes.
        /// - throws: The error value of ``futureResult`` if it errors.
        @available(*, noasync, message: "wait() can block indefinitely, prefer get()", renamed: "get()")
        @preconcurrency
        public func wait() throws -> Response where Response: Sendable {
            try self.promise.futureResult.wait()
        }

        /// Provides the result of this request.
        ///
        /// - warning: This method may violates Structured Concurrency because doesn't respect cancellation.
        ///
        /// - returns: The value of ``futureResult`` when it completes.
        /// - throws: The error value of ``futureResult`` if it errors.
        @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
        @preconcurrency
        public func get() async throws -> Response where Response: Sendable {
            try await self.promise.futureResult.get()
        }

        /// Initiate cancellation of a HTTP request.
        ///
        /// This method will return immeidately and doesn't wait for the cancellation to complete.
        public func cancel() {
            self.fail(reason: HTTPClientError.cancelled)
        }

        /// Initiate cancellation of a HTTP request with an `error`.
        ///
        /// This method will return immeidately and doesn't wait for the cancellation to complete.
        ///
        /// - Parameter error: the error that is used to fail the promise
        public func fail(reason error: Error) {
            let taskDelegate = self.state.withLockedValue { state in
                state.isCancelled = true
                return state.taskDelegate
            }

            taskDelegate?.fail(error)
        }

        /// Called internally only, used to fail a task from within the state machine functionality.
        func failInternal(
            with error: Error
        ) {
            self.promise.fail(error)
        }
    }
}

internal struct TaskCancelEvent {}

// MARK: - RedirectHandler

internal struct RedirectHandler<ResponseType: Sendable> {
    let request: HTTPClient.Request
    let redirectState: RedirectState
    let execute: (HTTPClient.Request, RedirectState) -> HTTPClient.Task<ResponseType>

    func redirectTarget(status: HTTPResponseStatus, responseHeaders: HTTPHeaders) -> URL? {
        responseHeaders.extractRedirectTarget(
            status: status,
            originalURL: self.request.url,
            originalScheme: self.request.deconstructedURL.scheme
        )
    }

    func redirect(
        status: HTTPResponseStatus,
        to redirectURL: URL,
        promise: EventLoopPromise<ResponseType>
    ) -> HTTPClient.Task<ResponseType>? {
        do {
            var redirectState = self.redirectState
            try redirectState.redirect(to: redirectURL.absoluteString)

            let (method, headers, body) = transformRequestForRedirect(
                from: request.url,
                method: self.request.method,
                headers: self.request.headers,
                body: self.request.body,
                to: redirectURL,
                status: status
            )

            let newRequest = try HTTPClient.Request(
                url: redirectURL,
                method: method,
                headers: headers,
                body: body
            )

            let newTask = self.execute(newRequest, redirectState)

            newTask.futureResult.whenComplete { result in
                promise.futureResult.eventLoop.execute {
                    promise.completeWith(result)
                }
            }

            return newTask
        } catch {
            promise.fail(error)
            return nil
        }
    }
}

extension RequestBodyLength {
    init(_ body: HTTPClient.Body?) {
        guard let body = body else {
            self = .known(0)
            return
        }
        guard let length = body.contentLength else {
            self = .unknown
            return
        }
        self = .known(length)
    }
}
