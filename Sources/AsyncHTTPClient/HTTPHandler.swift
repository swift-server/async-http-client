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

import Foundation
import Logging
import NIO
import NIOConcurrencyHelpers
import NIOFoundationCompat
import NIOHTTP1
import NIOHTTPCompression
import NIOSSL

extension HTTPClient {
    /// Represent request body.
    public struct Body {
        /// Chunk provider.
        public struct StreamWriter {
            let closure: (IOData) -> EventLoopFuture<Void>

            /// Create new StreamWriter
            ///
            /// - parameters:
            ///     - closure: function that will be called to write actual bytes to the channel.
            public init(closure: @escaping (IOData) -> EventLoopFuture<Void>) {
                self.closure = closure
            }

            /// Write data to server.
            ///
            /// - parameters:
            ///     - data: `IOData` to write.
            public func write(_ data: IOData) -> EventLoopFuture<Void> {
                return self.closure(data)
            }
        }

        /// Body size. Request validation will be failed with `HTTPClientErrors.contentLengthMissing` if nil,
        /// unless `Trasfer-Encoding: chunked` header is set.
        public var length: Int?
        /// Body chunk provider.
        public var stream: (StreamWriter) -> EventLoopFuture<Void>

        /// Create and stream body using `ByteBuffer`.
        ///
        /// - parameters:
        ///     - buffer: Body `ByteBuffer` representation.
        public static func byteBuffer(_ buffer: ByteBuffer) -> Body {
            return Body(length: buffer.readableBytes) { writer in
                writer.write(.byteBuffer(buffer))
            }
        }

        /// Create and stream body using `StreamWriter`.
        ///
        /// - parameters:
        ///     - length: Body size. Request validation will be failed with `HTTPClientErrors.contentLengthMissing` if nil,
        ///               unless `Transfer-Encoding: chunked` header is set.
        ///     - stream: Body chunk provider.
        public static func stream(length: Int? = nil, _ stream: @escaping (StreamWriter) -> EventLoopFuture<Void>) -> Body {
            return Body(length: length, stream: stream)
        }

        /// Create and stream body using `Data`.
        ///
        /// - parameters:
        ///     - data: Body `Data` representation.
        public static func data(_ data: Data) -> Body {
            return Body(length: data.count) { writer in
                writer.write(.byteBuffer(ByteBuffer(bytes: data)))
            }
        }

        /// Create and stream body using `String`.
        ///
        /// - parameters:
        ///     - string: Body `String` representation.
        public static func string(_ string: String) -> Body {
            return Body(length: string.utf8.count) { writer in
                writer.write(.byteBuffer(ByteBuffer(string: string)))
            }
        }
    }

    /// Represent HTTP request.
    public struct Request {
        /// Represent kind of Request
        enum Kind: Equatable {
            enum UnixScheme: Equatable {
                case baseURL
                case http_unix
                case https_unix
            }

            /// Remote host request.
            case host
            /// UNIX Domain Socket HTTP request.
            case unixSocket(_ scheme: UnixScheme)

            private static var hostRestrictedSchemes: Set = ["http", "https"]
            private static var allSupportedSchemes: Set = ["http", "https", "unix", "http+unix", "https+unix"]

            init(forScheme scheme: String) throws {
                switch scheme {
                case "http", "https": self = .host
                case "unix": self = .unixSocket(.baseURL)
                case "http+unix": self = .unixSocket(.http_unix)
                case "https+unix": self = .unixSocket(.https_unix)
                default:
                    throw HTTPClientError.unsupportedScheme(scheme)
                }
            }

            func hostFromURL(_ url: URL) throws -> String {
                switch self {
                case .host:
                    guard let host = url.host else {
                        throw HTTPClientError.emptyHost
                    }
                    return host
                case .unixSocket:
                    return ""
                }
            }

            func socketPathFromURL(_ url: URL) throws -> String {
                switch self {
                case .unixSocket(.baseURL):
                    return url.baseURL?.path ?? url.path
                case .unixSocket:
                    guard let socketPath = url.host else {
                        throw HTTPClientError.missingSocketPath
                    }
                    return socketPath
                case .host:
                    return ""
                }
            }

            func uriFromURL(_ url: URL) -> String {
                switch self {
                case .host:
                    return url.uri
                case .unixSocket(.baseURL):
                    return url.baseURL != nil ? url.uri : "/"
                case .unixSocket:
                    return url.uri
                }
            }

            func supportsRedirects(to scheme: String?) -> Bool {
                guard let scheme = scheme?.lowercased() else { return false }

                switch self {
                case .host:
                    return Kind.hostRestrictedSchemes.contains(scheme)
                case .unixSocket:
                    return Kind.allSupportedSchemes.contains(scheme)
                }
            }
        }

        /// Request HTTP method, defaults to `GET`.
        public let method: HTTPMethod
        /// Remote URL.
        public let url: URL
        /// Remote HTTP scheme, resolved from `URL`.
        public let scheme: String
        /// Remote host, resolved from `URL`.
        public let host: String
        /// Socket path, resolved from `URL`.
        let socketPath: String
        /// URI composed of the path and query, resolved from `URL`.
        let uri: String
        /// Request custom HTTP Headers, defaults to no headers.
        public var headers: HTTPHeaders
        /// Request body, defaults to no body.
        public var body: Body?

        struct RedirectState {
            var count: Int
            var visited: Set<URL>?
        }

        var redirectState: RedirectState?
        let kind: Kind

        /// Create HTTP request.
        ///
        /// - parameters:
        ///     - url: Remote `URL`.
        ///     - version: HTTP version.
        ///     - method: HTTP method.
        ///     - headers: Custom HTTP headers.
        ///     - body: Request body.
        /// - throws:
        ///     - `invalidURL` if URL cannot be parsed.
        ///     - `emptyScheme` if URL does not contain HTTP scheme.
        ///     - `unsupportedScheme` if URL does contains unsupported HTTP scheme.
        ///     - `emptyHost` if URL does not contains a host.
        public init(url: String, method: HTTPMethod = .GET, headers: HTTPHeaders = HTTPHeaders(), body: Body? = nil) throws {
            guard let url = URL(string: url) else {
                throw HTTPClientError.invalidURL
            }

            try self.init(url: url, method: method, headers: headers, body: body)
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
        public init(url: URL, method: HTTPMethod = .GET, headers: HTTPHeaders = HTTPHeaders(), body: Body? = nil) throws {
            guard let scheme = url.scheme?.lowercased() else {
                throw HTTPClientError.emptyScheme
            }

            self.kind = try Kind(forScheme: scheme)
            self.host = try self.kind.hostFromURL(url)
            self.socketPath = try self.kind.socketPathFromURL(url)
            self.uri = self.kind.uriFromURL(url)

            self.redirectState = nil
            self.url = url
            self.method = method
            self.scheme = scheme
            self.headers = headers
            self.body = body
        }

        /// Whether request will be executed using secure socket.
        public var useTLS: Bool {
            return self.scheme == "https" || self.scheme == "https+unix"
        }

        /// Resolved port.
        public var port: Int {
            return self.url.port ?? (self.useTLS ? 443 : 80)
        }
    }

    /// Represent HTTP response.
    public struct Response {
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
        }

        /// Create HTTP `Response`.
        ///
        /// - parameters:
        ///     - host: Remote host of the request.
        ///     - status: Response HTTP status.
        ///     - version: Response HTTP version.
        ///     - headers: Reponse HTTP headers.
        ///     - body: Response body.
        public init(host: String, status: HTTPResponseStatus, version: HTTPVersion, headers: HTTPHeaders, body: ByteBuffer?) {
            self.host = host
            self.status = status
            self.version = version
            self.headers = headers
            self.body = body
        }
    }

    /// HTTP authentication
    public struct Authorization {
        private enum Scheme {
            case Basic(String)
            case Bearer(String)
        }

        private let scheme: Scheme

        private init(scheme: Scheme) {
            self.scheme = scheme
        }

        public static func basic(username: String, password: String) -> HTTPClient.Authorization {
            return .basic(credentials: Data("\(username):\(password)".utf8).base64EncodedString())
        }

        public static func basic(credentials: String) -> HTTPClient.Authorization {
            return .init(scheme: .Basic(credentials))
        }

        public static func bearer(tokens: String) -> HTTPClient.Authorization {
            return .init(scheme: .Bearer(tokens))
        }

        public var headerValue: String {
            switch self.scheme {
            case .Basic(let credentials):
                return "Basic \(credentials)"
            case .Bearer(let tokens):
                return "Bearer \(tokens)"
            }
        }
    }
}

public class ResponseAccumulator: HTTPClientResponseDelegate {
    public typealias Response = HTTPClient.Response

    enum State {
        case idle
        case head(HTTPResponseHead)
        case body(HTTPResponseHead, ByteBuffer)
        case end
        case error(Error)
    }

    var state = State.idle
    let request: HTTPClient.Request

    public init(request: HTTPClient.Request) {
        self.request = request
    }

    public func didReceiveHead(task: HTTPClient.Task<Response>, _ head: HTTPResponseHead) -> EventLoopFuture<Void> {
        switch self.state {
        case .idle:
            self.state = .head(head)
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

    public func didReceiveBodyPart(task: HTTPClient.Task<Response>, _ part: ByteBuffer) -> EventLoopFuture<Void> {
        switch self.state {
        case .idle:
            preconditionFailure("no head received before body")
        case .head(let head):
            self.state = .body(head, part)
        case .body(let head, var body):
            // The compiler can't prove that `self.state` is dead here (and it kinda isn't, there's
            // a cross-module call in the way) so we need to drop the original reference to `body` in
            // `self.state` or we'll get a CoW. To fix that we temporarily set the state to `.end` (which
            // has no associated data). We'll fix it at the bottom of this block.
            self.state = .end
            var part = part
            body.writeBuffer(&part)
            self.state = .body(head, body)
        case .end:
            preconditionFailure("request already processed")
        case .error:
            break
        }
        return task.eventLoop.makeSucceededFuture(())
    }

    public func didReceiveError(task: HTTPClient.Task<Response>, _ error: Error) {
        self.state = .error(error)
    }

    public func didFinishRequest(task: HTTPClient.Task<Response>) throws -> Response {
        switch self.state {
        case .idle:
            preconditionFailure("no head received before end")
        case .head(let head):
            return Response(host: self.request.host, status: head.status, version: head.version, headers: head.headers, body: nil)
        case .body(let head, let body):
            return Response(host: self.request.host, status: head.status, version: head.version, headers: head.headers, body: body)
        case .end:
            preconditionFailure("request already processed")
        case .error(let error):
            throw error
        }
    }
}

/// `HTTPClientResponseDelegate` allows an implementation to receive notifications about request processing and to control how response parts are processed.
/// You can implement this protocol if you need fine-grained control over an HTTP request/response, for example, if you want to inspect the response
/// headers before deciding whether to accept a response body, or if you want to stream your request body. Pass an instance of your conforming
/// class to the `HTTPClient.execute()` method and this package will call each delegate method appropriately as the request takes place./
///
/// ### Backpressure
///
/// A `HTTPClientResponseDelegate` can be used to exert backpressure on the server response. This is achieved by way of the futures returned from
/// `didReceiveHead` and `didReceiveBodyPart`. The following functions are part of the "backpressure system" in the delegate:
///
/// - `didReceiveHead`
/// - `didReceiveBodyPart`
/// - `didFinishRequest`
/// - `didReceiveError`
///
/// The first three methods are strictly _exclusive_, with that exclusivity managed by the futures returned by `didReceiveHead` and
/// `didReceiveBodyPart`. What this means is that until the returned future is completed, none of these three methods will be called
/// again. This allows delegates to rate limit the server to a capacity it can manage. `didFinishRequest` does not return a future,
/// as we are expecting no more data from the server at this time.
///
/// `didReceiveError` is somewhat special: it signals the end of this regime. `didRecieveError` is not exclusive: it may be called at
/// any time, even if a returned future is not yet completed. `didReceiveError` is terminal, meaning that once it has been called none
/// of these four methods will be called again. This can be used as a signal to abandon all outstanding work.
///
///  - note: This delegate is strongly held by the `HTTPTaskHandler`
///          for the duration of the `Request` processing and will be
///          released together with the `HTTPTaskHandler` when channel is closed.
///          Users of the library are not required to keep a reference to the
///          object that implements this protocol, but may do so if needed.
public protocol HTTPClientResponseDelegate: AnyObject {
    associatedtype Response

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
    ///     - part: Request body `Part`.
    func didSendRequestPart(task: HTTPClient.Task<Response>, _ part: IOData)

    /// Called when the request is fully sent. Will be called once.
    ///
    /// - parameters:
    ///     - task: Current request context.
    func didSendRequest(task: HTTPClient.Task<Response>)

    /// Called when response head is received. Will be called once.
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
    /// This function will not be called until the future returned by `didReceiveHead` has completed.
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
    /// This function may be called at any time: it does not respect the backpressure exerted by `didReceiveHead` and `didReceiveBodyPart`.
    /// All outstanding work may be cancelled when this is received. Once called, no further calls will be made to `didReceiveHead`, `didReceiveBodyPart`,
    /// or `didFinishRequest`.
    ///
    /// - parameters:
    ///     - task: Current request context.
    ///     - error: Error that occured during response processing.
    func didReceiveError(task: HTTPClient.Task<Response>, _ error: Error)

    /// Called when the complete HTTP request is finished. You must return an instance of your `Response` associated type. Will be called once, except if an error occurred.
    ///
    /// This function will not be called until all futures returned by `didReceiveHead` and `didReceiveBodyPart` have completed. Once called,
    /// no further calls will be made to `didReceiveHead`, `didReceiveBodyPart`, or `didReceiveError`.
    ///
    /// - parameters:
    ///     - task: Current request context.
    /// - returns: Result of processing.
    func didFinishRequest(task: HTTPClient.Task<Response>) throws -> Response
}

extension HTTPClientResponseDelegate {
    public func didSendRequestHead(task: HTTPClient.Task<Response>, _ head: HTTPRequestHead) {}

    public func didSendRequestPart(task: HTTPClient.Task<Response>, _ part: IOData) {}

    public func didSendRequest(task: HTTPClient.Task<Response>) {}

    public func didReceiveHead(task: HTTPClient.Task<Response>, _: HTTPResponseHead) -> EventLoopFuture<Void> {
        return task.eventLoop.makeSucceededFuture(())
    }

    public func didReceiveBodyPart(task: HTTPClient.Task<Response>, _: ByteBuffer) -> EventLoopFuture<Void> {
        return task.eventLoop.makeSucceededFuture(())
    }

    public func didReceiveError(task: HTTPClient.Task<Response>, _: Error) {}
}

extension URL {
    var percentEncodedPath: String {
        if self.path.isEmpty {
            return "/"
        }
        return URLComponents(url: self, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? self.path
    }

    var uri: String {
        var uri = self.percentEncodedPath

        if let query = self.query {
            uri += "?" + query
        }

        return uri
    }

    func hasTheSameOrigin(as other: URL) -> Bool {
        return self.host == other.host && self.scheme == other.scheme && self.port == other.port
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

extension HTTPClient {
    /// Response execution context. Will be created by the library and could be used for obtaining
    /// `EventLoopFuture<Response>` of the execution or cancellation of the execution.
    public final class Task<Response> {
        /// The `EventLoop` the delegate will be executed on.
        public let eventLoop: EventLoop

        let promise: EventLoopPromise<Response>
        var completion: EventLoopFuture<Void>
        var connection: Connection?
        var cancelled: Bool
        let lock: Lock
        let logger: Logger // We are okay to store the logger here because a Task is for only one request.

        init(eventLoop: EventLoop, logger: Logger) {
            self.eventLoop = eventLoop
            self.promise = eventLoop.makePromise()
            self.completion = self.promise.futureResult.map { _ in }
            self.cancelled = false
            self.lock = Lock()
            self.logger = logger
        }

        static func failedTask(eventLoop: EventLoop, error: Error, logger: Logger) -> Task<Response> {
            let task = self.init(eventLoop: eventLoop, logger: logger)
            task.promise.fail(error)
            return task
        }

        /// `EventLoopFuture` for the response returned by this request.
        public var futureResult: EventLoopFuture<Response> {
            return self.promise.futureResult
        }

        /// Waits for execution of this request to complete.
        ///
        /// - returns: The value of the `EventLoopFuture` when it completes.
        /// - throws: The error value of the `EventLoopFuture` if it errors.
        public func wait() throws -> Response {
            return try self.promise.futureResult.wait()
        }

        /// Cancels the request execution.
        public func cancel() {
            let channel: Channel? = self.lock.withLock {
                if !self.cancelled {
                    self.cancelled = true
                    return self.connection?.channel
                } else {
                    return nil
                }
            }
            channel?.triggerUserOutboundEvent(TaskCancelEvent(), promise: nil)
        }

        @discardableResult
        func setConnection(_ connection: Connection) -> Connection {
            return self.lock.withLock {
                self.connection = connection
                if self.cancelled {
                    connection.channel.triggerUserOutboundEvent(TaskCancelEvent(), promise: nil)
                }
                return connection
            }
        }

        func succeed<Delegate: HTTPClientResponseDelegate>(promise: EventLoopPromise<Response>?,
                                                           with value: Response,
                                                           delegateType: Delegate.Type,
                                                           closing: Bool) {
            self.releaseAssociatedConnection(delegateType: delegateType,
                                             closing: closing).whenSuccess {
                promise?.succeed(value)
            }
        }

        func fail<Delegate: HTTPClientResponseDelegate>(with error: Error,
                                                        delegateType: Delegate.Type) {
            if let connection = self.connection {
                self.releaseAssociatedConnection(delegateType: delegateType, closing: true)
                    .whenSuccess {
                        self.promise.fail(error)
                        connection.channel.close(promise: nil)
                    }
            } else {
                // this is used in tests where we don't want to bootstrap the whole connection pool
                self.promise.fail(error)
            }
        }

        func releaseAssociatedConnection<Delegate: HTTPClientResponseDelegate>(delegateType: Delegate.Type,
                                                                               closing: Bool) -> EventLoopFuture<Void> {
            if let connection = self.connection {
                // remove read timeout handler
                return connection.removeHandler(IdleStateHandler.self).flatMap {
                    connection.removeHandler(TaskHandler<Delegate>.self)
                }.map {
                    connection.release(closing: closing, logger: self.logger)
                }.flatMapError { error in
                    fatalError("Couldn't remove taskHandler: \(error)")
                }
            } else {
                // TODO: This seems only reached in some internal unit test
                // Maybe there could be a better handling in the future to make
                // it an error outside of testing contexts
                return self.eventLoop.makeSucceededFuture(())
            }
        }
    }
}

internal struct TaskCancelEvent {}

// MARK: - TaskHandler

internal class TaskHandler<Delegate: HTTPClientResponseDelegate>: RemovableChannelHandler {
    enum State {
        case idle
        case sendingBodyWaitingResponseHead
        case sendingBodyResponseHeadReceived
        case bodySentWaitingResponseHead
        case bodySentResponseHeadReceived
        case redirected(HTTPResponseHead, URL)
        case bufferedEnd
        case endOrError
    }

    let task: HTTPClient.Task<Delegate.Response>
    let delegate: Delegate
    let redirectHandler: RedirectHandler<Delegate.Response>?
    let ignoreUncleanSSLShutdown: Bool
    let logger: Logger // We are okay to store the logger here because a TaskHandler is just for one request.

    var state: State = .idle
    var responseReadBuffer: ResponseReadBuffer = ResponseReadBuffer()
    var expectedBodyLength: Int?
    var actualBodyLength: Int = 0
    var pendingRead = false
    var outstandingDelegateRead = false
    var closing = false {
        didSet {
            assert(self.closing || !oldValue,
                   "BUG in AsyncHTTPClient: TaskHandler.closing went from true (no conn reuse) to true (do reuse).")
        }
    }

    let kind: HTTPClient.Request.Kind

    init(task: HTTPClient.Task<Delegate.Response>,
         kind: HTTPClient.Request.Kind,
         delegate: Delegate,
         redirectHandler: RedirectHandler<Delegate.Response>?,
         ignoreUncleanSSLShutdown: Bool,
         logger: Logger) {
        self.task = task
        self.delegate = delegate
        self.redirectHandler = redirectHandler
        self.ignoreUncleanSSLShutdown = ignoreUncleanSSLShutdown
        self.kind = kind
        self.logger = logger
    }
}

// MARK: Delegate Callouts

extension TaskHandler {
    func failTaskAndNotifyDelegate<Err: Error>(error: Err,
                                               _ body: @escaping (HTTPClient.Task<Delegate.Response>, Err) -> Void) {
        func doIt() {
            body(self.task, error)
            self.task.fail(with: error, delegateType: Delegate.self)
        }

        if self.task.eventLoop.inEventLoop {
            doIt()
        } else {
            self.task.eventLoop.execute {
                doIt()
            }
        }
    }

    func callOutToDelegateFireAndForget(_ body: @escaping (HTTPClient.Task<Delegate.Response>) -> Void) {
        self.callOutToDelegateFireAndForget(value: ()) { (task, _: ()) in body(task) }
    }

    func callOutToDelegateFireAndForget<Value>(value: Value,
                                               _ body: @escaping (HTTPClient.Task<Delegate.Response>, Value) -> Void) {
        if self.task.eventLoop.inEventLoop {
            body(self.task, value)
        } else {
            self.task.eventLoop.execute {
                body(self.task, value)
            }
        }
    }

    func callOutToDelegate<Value>(value: Value,
                                  channelEventLoop: EventLoop,
                                  _ body: @escaping (HTTPClient.Task<Delegate.Response>, Value) -> EventLoopFuture<Void>) -> EventLoopFuture<Void> {
        if self.task.eventLoop.inEventLoop {
            return body(self.task, value).hop(to: channelEventLoop)
        } else {
            return self.task.eventLoop.submit {
                body(self.task, value)
            }.flatMap { $0 }.hop(to: channelEventLoop)
        }
    }

    func callOutToDelegate<Response>(promise: EventLoopPromise<Response>? = nil,
                                     _ body: @escaping (HTTPClient.Task<Delegate.Response>) throws -> Response) where Response == Delegate.Response {
        func doIt() {
            do {
                let result = try body(self.task)

                self.task.succeed(promise: promise,
                                  with: result,
                                  delegateType: Delegate.self,
                                  closing: self.closing)
            } catch {
                self.task.fail(with: error, delegateType: Delegate.self)
            }
        }

        if self.task.eventLoop.inEventLoop {
            doIt()
        } else {
            self.task.eventLoop.submit {
                doIt()
            }.cascadeFailure(to: promise)
        }
    }

    func callOutToDelegate<Response>(channelEventLoop: EventLoop,
                                     _ body: @escaping (HTTPClient.Task<Delegate.Response>) throws -> Response) -> EventLoopFuture<Response> where Response == Delegate.Response {
        let promise = channelEventLoop.makePromise(of: Response.self)
        self.callOutToDelegate(promise: promise, body)
        return promise.futureResult
    }
}

// MARK: ChannelHandler implementation

extension TaskHandler: ChannelDuplexHandler {
    typealias OutboundIn = HTTPClient.Request
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        self.state = .sendingBodyWaitingResponseHead

        let request = self.unwrapOutboundIn(data)

        var head = HTTPRequestHead(version: HTTPVersion(major: 1, minor: 1),
                                   method: request.method,
                                   uri: request.uri)
        var headers = request.headers

        if !request.headers.contains(name: "host") {
            let port = request.port
            var host = request.host
            if !(port == 80 && request.scheme == "http"), !(port == 443 && request.scheme == "https") {
                host += ":\(port)"
            }
            headers.add(name: "host", value: host)
        }

        do {
            try headers.validate(method: request.method, body: request.body)
        } catch {
            self.errorCaught(context: context, error: error)
            promise?.fail(error)
            return
        }

        head.headers = headers

        if head.headers[canonicalForm: "connection"].map({ $0.lowercased() }).contains("close") {
            self.closing = true
        }
        // This assert can go away when (if ever!) the above `if` correctly handles other HTTP versions. For example
        // in HTTP/1.0, we need to treat the absence of a 'connection: keep-alive' as a close too.
        assert(head.version == HTTPVersion(major: 1, minor: 1),
               "Sending a request in HTTP version \(head.version) which is unsupported by the above `if`")

        let contentLengths = head.headers[canonicalForm: "content-length"]
        assert(contentLengths.count <= 1)

        self.expectedBodyLength = contentLengths.first.flatMap { Int($0) }

        context.write(wrapOutboundOut(.head(head))).map {
            self.callOutToDelegateFireAndForget(value: head, self.delegate.didSendRequestHead)
        }.flatMap {
            self.writeBody(request: request, context: context)
        }.flatMap {
            context.eventLoop.assertInEventLoop()
            switch self.state {
            case .idle:
                // since this code path is called from `write` and write sets state to sendingBody
                preconditionFailure("should not happen")
            case .sendingBodyWaitingResponseHead:
                self.state = .bodySentWaitingResponseHead
            case .sendingBodyResponseHeadReceived:
                self.state = .bodySentResponseHeadReceived
            case .bodySentWaitingResponseHead, .bodySentResponseHeadReceived:
                preconditionFailure("should not happen, state is \(self.state)")
            case .redirected:
                break
            case .bufferedEnd, .endOrError:
                // If the state is .endOrError, it means that request was failed and there is nothing to do here:
                // we cannot write .end since channel is most likely closed, and we should not fail the future,
                // since the task would already be failed, no need to fail the writer too.
                // If the state is .bufferedEnd the issue is the same, we just haven't fully delivered the response to
                // the user yet.
                return context.eventLoop.makeSucceededFuture(())
            }

            if let expectedBodyLength = self.expectedBodyLength, expectedBodyLength != self.actualBodyLength {
                let error = HTTPClientError.bodyLengthMismatch
                return context.eventLoop.makeFailedFuture(error)
            }
            return context.writeAndFlush(self.wrapOutboundOut(.end(nil)))
        }.map {
            context.eventLoop.assertInEventLoop()

            if case .endOrError = self.state {
                return
            }

            self.callOutToDelegateFireAndForget(self.delegate.didSendRequest)
        }.flatMapErrorThrowing { error in
            context.eventLoop.assertInEventLoop()
            self.errorCaught(context: context, error: error)
            throw error
        }.cascade(to: promise)
    }

    private func writeBody(request: HTTPClient.Request, context: ChannelHandlerContext) -> EventLoopFuture<Void> {
        guard let body = request.body else {
            return context.eventLoop.makeSucceededFuture(())
        }

        let channel = context.channel

        func doIt() -> EventLoopFuture<Void> {
            return body.stream(HTTPClient.Body.StreamWriter { part in
                let promise = self.task.eventLoop.makePromise(of: Void.self)
                // All writes have to be switched to the channel EL if channel and task ELs differ
                if channel.eventLoop.inEventLoop {
                    self.writeBodyPart(context: context, part: part, promise: promise)
                } else {
                    channel.eventLoop.execute {
                        self.writeBodyPart(context: context, part: part, promise: promise)
                    }
                }

                return promise.futureResult.map {
                    self.callOutToDelegateFireAndForget(value: part, self.delegate.didSendRequestPart)
                }
            })
        }

        // Callout to the user to start body streaming should be on task EL
        if self.task.eventLoop.inEventLoop {
            return doIt()
        } else {
            return self.task.eventLoop.flatSubmit {
                doIt()
            }
        }
    }

    private func writeBodyPart(context: ChannelHandlerContext, part: IOData, promise: EventLoopPromise<Void>) {
        switch self.state {
        case .idle:
            // this function is called on the codepath starting with write, so it cannot be in state .idle
            preconditionFailure("should not happen")
        case .sendingBodyWaitingResponseHead, .sendingBodyResponseHeadReceived, .redirected:
            if let limit = self.expectedBodyLength, self.actualBodyLength + part.readableBytes > limit {
                let error = HTTPClientError.bodyLengthMismatch
                self.errorCaught(context: context, error: error)
                promise.fail(error)
                return
            }
            self.actualBodyLength += part.readableBytes
            context.writeAndFlush(self.wrapOutboundOut(.body(part)), promise: promise)
        case .bodySentWaitingResponseHead, .bodySentResponseHeadReceived, .bufferedEnd, .endOrError:
            let error = HTTPClientError.writeAfterRequestSent
            self.errorCaught(context: context, error: error)
            promise.fail(error)
        }
    }

    public func read(context: ChannelHandlerContext) {
        if self.outstandingDelegateRead {
            self.pendingRead = true
        } else {
            self.pendingRead = false
            context.read()
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let response = self.unwrapInboundIn(data)
        switch response {
        case .head(let head):
            switch self.state {
            case .idle:
                // should be prevented by NIO HTTP1 pipeline, see testHTTPResponseHeadBeforeRequestHead
                preconditionFailure("should not happen")
            case .sendingBodyWaitingResponseHead:
                self.state = .sendingBodyResponseHeadReceived
            case .bodySentWaitingResponseHead:
                self.state = .bodySentResponseHeadReceived
            case .sendingBodyResponseHeadReceived, .bodySentResponseHeadReceived, .redirected:
                // should be prevented by NIO HTTP1 pipeline, aee testHTTPResponseDoubleHead
                preconditionFailure("should not happen")
            case .bufferedEnd, .endOrError:
                return
            }

            if !head.isKeepAlive {
                self.closing = true
            }

            if let redirectURL = self.redirectHandler?.redirectTarget(status: head.status, headers: head.headers) {
                self.state = .redirected(head, redirectURL)
            } else {
                self.handleReadForDelegate(response, context: context)
            }
        case .body:
            switch self.state {
            case .redirected, .bufferedEnd, .endOrError:
                break
            default:
                self.handleReadForDelegate(response, context: context)
            }
        case .end:
            switch self.state {
            case .bufferedEnd, .endOrError:
                break
            case .redirected(let head, let redirectURL):
                self.state = .endOrError
                self.task.releaseAssociatedConnection(delegateType: Delegate.self, closing: self.closing).whenSuccess {
                    self.redirectHandler?.redirect(status: head.status, to: redirectURL, promise: self.task.promise)
                }
            default:
                self.state = .bufferedEnd
                self.handleReadForDelegate(response, context: context)
            }
        }
    }

    private func handleReadForDelegate(_ read: HTTPClientResponsePart, context: ChannelHandlerContext) {
        if self.outstandingDelegateRead {
            self.responseReadBuffer.appendPart(read)
            return
        }

        // No outstanding delegate read, so we can deliver this directly.
        self.deliverReadToDelegate(read, context: context)
    }

    private func deliverReadToDelegate(_ read: HTTPClientResponsePart, context: ChannelHandlerContext) {
        precondition(!self.outstandingDelegateRead)
        self.outstandingDelegateRead = true

        if case .endOrError = self.state {
            // No further read delivery should occur, we already delivered an error.
            return
        }

        switch read {
        case .head(let head):
            self.callOutToDelegate(value: head, channelEventLoop: context.eventLoop, self.delegate.didReceiveHead)
                .whenComplete { result in
                    self.handleBackpressureResult(context: context, result: result)
                }
        case .body(let body):
            self.callOutToDelegate(value: body, channelEventLoop: context.eventLoop, self.delegate.didReceiveBodyPart)
                .whenComplete { result in
                    self.handleBackpressureResult(context: context, result: result)
                }
        case .end:
            self.state = .endOrError
            self.outstandingDelegateRead = false

            if self.pendingRead {
                // We must read here, as we will be removed from the channel shortly.
                self.pendingRead = false
                context.read()
            }

            self.callOutToDelegate(promise: self.task.promise, self.delegate.didFinishRequest)
        }
    }

    private func handleBackpressureResult(context: ChannelHandlerContext, result: Result<Void, Error>) {
        context.eventLoop.assertInEventLoop()
        self.outstandingDelegateRead = false

        switch result {
        case .success:
            if let nextRead = self.responseReadBuffer.nextRead() {
                // We can deliver this directly.
                self.deliverReadToDelegate(nextRead, context: context)
            } else if self.pendingRead {
                self.pendingRead = false
                context.read()
            }
        case .failure(let error):
            self.errorCaught(context: context, error: error)
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if (event as? IdleStateHandler.IdleStateEvent) == .read {
            self.errorCaught(context: context, error: HTTPClientError.readTimeout)
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    func triggerUserOutboundEvent(context: ChannelHandlerContext, event: Any, promise: EventLoopPromise<Void>?) {
        if (event as? TaskCancelEvent) != nil {
            self.errorCaught(context: context, error: HTTPClientError.cancelled)
            promise?.succeed(())
        } else {
            context.triggerUserOutboundEvent(event, promise: promise)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        switch self.state {
        case .idle, .sendingBodyWaitingResponseHead, .sendingBodyResponseHeadReceived, .bodySentWaitingResponseHead, .bodySentResponseHeadReceived, .redirected:
            self.errorCaught(context: context, error: HTTPClientError.remoteConnectionClosed)
        case .bufferedEnd, .endOrError:
            break
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        switch error {
        case NIOSSLError.uncleanShutdown:
            switch self.state {
            case .bufferedEnd, .endOrError:
                /// Some HTTP Servers can 'forget' to respond with CloseNotify when client is closing connection,
                /// this could lead to incomplete SSL shutdown. But since request is already processed, we can ignore this error.
                break
            case .sendingBodyResponseHeadReceived where self.ignoreUncleanSSLShutdown,
                 .bodySentResponseHeadReceived where self.ignoreUncleanSSLShutdown:
                /// We can also ignore this error like `.end`.
                break
            default:
                self.state = .endOrError
                self.failTaskAndNotifyDelegate(error: error, self.delegate.didReceiveError)
            }
        default:
            switch self.state {
            case .idle, .sendingBodyWaitingResponseHead, .sendingBodyResponseHeadReceived, .bodySentWaitingResponseHead, .bodySentResponseHeadReceived, .redirected, .bufferedEnd:
                self.state = .endOrError
                self.failTaskAndNotifyDelegate(error: error, self.delegate.didReceiveError)
            case .endOrError:
                // error was already handled
                break
            }
        }
    }

    func handlerAdded(context: ChannelHandlerContext) {
        guard context.channel.isActive else {
            self.errorCaught(context: context, error: HTTPClientError.remoteConnectionClosed)
            return
        }
    }
}

// MARK: - RedirectHandler

internal struct RedirectHandler<ResponseType> {
    let request: HTTPClient.Request
    let execute: (HTTPClient.Request) -> HTTPClient.Task<ResponseType>

    func redirectTarget(status: HTTPResponseStatus, headers: HTTPHeaders) -> URL? {
        switch status {
        case .movedPermanently, .found, .seeOther, .notModified, .useProxy, .temporaryRedirect, .permanentRedirect:
            break
        default:
            return nil
        }

        guard let location = headers.first(name: "Location") else {
            return nil
        }

        guard let url = URL(string: location, relativeTo: request.url) else {
            return nil
        }

        guard self.request.kind.supportsRedirects(to: url.scheme) else {
            return nil
        }

        if url.isFileURL {
            return nil
        }

        return url.absoluteURL
    }

    func redirect(status: HTTPResponseStatus, to redirectURL: URL, promise: EventLoopPromise<ResponseType>) {
        var nextState: HTTPClient.Request.RedirectState?
        if var state = request.redirectState {
            guard state.count > 0 else {
                return promise.fail(HTTPClientError.redirectLimitReached)
            }

            state.count -= 1

            if var visited = state.visited {
                guard !visited.contains(redirectURL) else {
                    return promise.fail(HTTPClientError.redirectCycleDetected)
                }

                visited.insert(redirectURL)
                state.visited = visited
            }

            nextState = state
        }

        let originalRequest = self.request

        var convertToGet = false
        if status == .seeOther, self.request.method != .HEAD {
            convertToGet = true
        } else if status == .movedPermanently || status == .found, self.request.method == .POST {
            convertToGet = true
        }

        var method = originalRequest.method
        var headers = originalRequest.headers
        var body = originalRequest.body

        if convertToGet {
            method = .GET
            body = nil
            headers.remove(name: "Content-Length")
            headers.remove(name: "Content-Type")
        }

        if !originalRequest.url.hasTheSameOrigin(as: redirectURL) {
            headers.remove(name: "Origin")
            headers.remove(name: "Cookie")
            headers.remove(name: "Authorization")
            headers.remove(name: "Proxy-Authorization")
        }

        do {
            var newRequest = try HTTPClient.Request(url: redirectURL, method: method, headers: headers, body: body)
            newRequest.redirectState = nextState
            self.execute(newRequest).futureResult.whenComplete { result in
                promise.futureResult.eventLoop.execute {
                    promise.completeWith(result)
                }
            }
        } catch {
            promise.fail(error)
        }
    }
}
