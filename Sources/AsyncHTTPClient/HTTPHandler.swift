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
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOSSL

enum SupportedScheme: String {
    case http
    case https
    case unix
    case httpUnix = "http+unix"
    case httpsUnix = "https+unix"
}

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

        /// Body size. if nil,`Transfer-Encoding` will automatically be set to `chunked`. Otherwise a `Content-Length`
        /// header is set with the given `length`.
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
        ///     - length: Body size. If nil, `Transfer-Encoding` will automatically be set to `chunked`. Otherwise a `Content-Length`
        /// header is set with the given `length`.
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

        static func deconstructURL(
            _ url: URL
        ) throws -> (kind: Kind, scheme: String, connectionTarget: ConnectionTarget, uri: String) {
            guard let scheme = url.scheme?.lowercased() else {
                throw HTTPClientError.emptyScheme
            }
            switch scheme {
            case "http", "https":
                guard let host = url.host, !host.isEmpty else {
                    throw HTTPClientError.emptyHost
                }
                let defaultPort = self.useTLS(scheme) ? 443 : 80
                let hostTarget = ConnectionTarget(remoteHost: host, port: url.port ?? defaultPort)
                return (.host, scheme, hostTarget, url.uri)
            case "http+unix", "https+unix":
                guard let socketPath = url.host, !socketPath.isEmpty else {
                    throw HTTPClientError.missingSocketPath
                }
                let socketTarget = ConnectionTarget.unixSocket(path: socketPath)
                let kind = self.useTLS(scheme) ? Kind.UnixScheme.https_unix : .http_unix
                return (.unixSocket(kind), scheme, socketTarget, url.uri)
            case "unix":
                let socketPath = url.baseURL?.path ?? url.path
                let uri = url.baseURL != nil ? url.uri : "/"
                guard !socketPath.isEmpty else {
                    throw HTTPClientError.missingSocketPath
                }
                let socketTarget = ConnectionTarget.unixSocket(path: socketPath)
                return (.unixSocket(.baseURL), scheme, socketTarget, uri)
            default:
                throw HTTPClientError.unsupportedScheme(url.scheme!)
            }
        }

        /// Request HTTP method, defaults to `GET`.
        public let method: HTTPMethod
        /// Remote URL.
        public let url: URL
        
        internal let endpoint: Endpoint
        /// Remote HTTP scheme, resolved from `URL`.
        public var scheme: String {
            endpoint.scheme.rawValue
        }
        /// Remote host, resolved from `URL`.
        public var host: String { endpoint.host }
        /// Resolved port.
        public var port: Int { endpoint.port }

        /// Request custom HTTP Headers, defaults to no headers.
        public var headers: HTTPHeaders
        /// Request body, defaults to no body.
        public var body: Body?
        /// Request-specific TLS configuration, defaults to no request-specific TLS configuration.
        public var tlsConfiguration: TLSConfiguration?

        struct RedirectState {
            var count: Int
            var visited: Set<URL>?
        }

        var redirectState: RedirectState?

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
            try self.init(url: url, method: method, headers: headers, body: body, tlsConfiguration: nil)
        }

        /// Create HTTP request.
        ///
        /// - parameters:
        ///     - url: Remote `URL`.
        ///     - version: HTTP version.
        ///     - method: HTTP method.
        ///     - headers: Custom HTTP headers.
        ///     - body: Request body.
        ///     - tlsConfiguration: Request TLS configuration
        /// - throws:
        ///     - `invalidURL` if URL cannot be parsed.
        ///     - `emptyScheme` if URL does not contain HTTP scheme.
        ///     - `unsupportedScheme` if URL does contains unsupported HTTP scheme.
        ///     - `emptyHost` if URL does not contains a host.
        public init(url: String, method: HTTPMethod = .GET, headers: HTTPHeaders = HTTPHeaders(), body: Body? = nil, tlsConfiguration: TLSConfiguration?) throws {
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
        public init(url: URL, method: HTTPMethod = .GET, headers: HTTPHeaders = HTTPHeaders(), body: Body? = nil) throws {
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
        public init(url: URL, method: HTTPMethod = .GET, headers: HTTPHeaders = HTTPHeaders(), body: Body? = nil, tlsConfiguration: TLSConfiguration?) throws {
            self.endpoint = try Endpoint(url: url)
        
            self.redirectState = nil
            self.url = url
            self.method = method
            self.headers = headers
            self.body = body
            self.tlsConfiguration = tlsConfiguration
        }

        /// Whether request will be executed using secure socket.
        public var useTLS: Bool { self.endpoint.scheme.useTLS }

        /// Remote host, resolved from `URL`.
        public var host: String {
            switch self.connectionTarget {
            case .ipAddress(let serialization, _): return serialization
            case .domain(let name, _): return name
            case .unixSocket: return ""
            }
        }

        /// Resolved port.
        public var port: Int {
            switch self.connectionTarget {
            case .ipAddress(_, let address): return address.port!
            case .domain(_, let port): return port
            case .unixSocket: return Request.useTLS(self.scheme) ? 443 : 80
            }
        }

        func createRequestHead() throws -> (HTTPRequestHead, RequestFramingMetadata) {
            var head = HTTPRequestHead(
                version: .http1_1,
                method: self.method,
                uri: self.endpoint.uri,
                headers: self.headers
            )

            if !head.headers.contains(name: "host") {
                let port = self.endpoint.port
                var host = self.endpoint.host
                if !(port == 80 && self.endpoint.scheme == .http), !(port == 443 && self.endpoint.scheme == .https) {
                    host += ":\(port)"
                }
                head.headers.add(name: "host", value: host)
            }

            let metadata = try head.headers.validateAndSetTransportFraming(method: self.method, bodyLength: .init(self.body))

            return (head, metadata)
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
    public struct Authorization: Hashable {
        private enum Scheme: Hashable {
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
            return Response(host: self.request.endpoint.host, status: head.status, version: head.version, headers: head.headers, body: nil)
        case .body(let head, let body):
            return Response(host: self.request.endpoint.host, status: head.status, version: head.version, headers: head.headers, body: body)
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

protocol HTTPClientTaskDelegate {
    func cancel()
}

extension HTTPClient {
    /// Response execution context. Will be created by the library and could be used for obtaining
    /// `EventLoopFuture<Response>` of the execution or cancellation of the execution.
    public final class Task<Response> {
        /// The `EventLoop` the delegate will be executed on.
        public let eventLoop: EventLoop

        let promise: EventLoopPromise<Response>
        let logger: Logger // We are okay to store the logger here because a Task is for only one request.

        var isCancelled: Bool {
            self.lock.withLock { self._isCancelled }
        }

        var taskDelegate: HTTPClientTaskDelegate? {
            get {
                self.lock.withLock { self._taskDelegate }
            }
            set {
                self.lock.withLock { self._taskDelegate = newValue }
            }
        }

        private var _isCancelled: Bool = false
        private var _taskDelegate: HTTPClientTaskDelegate?
        private let lock = Lock()

        init(eventLoop: EventLoop, logger: Logger) {
            self.eventLoop = eventLoop
            self.promise = eventLoop.makePromise()
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
            let taskDelegate = self.lock.withLock { () -> HTTPClientTaskDelegate? in
                self._isCancelled = true
                return self._taskDelegate
            }

            taskDelegate?.cancel()
        }

        func succeed<Delegate: HTTPClientResponseDelegate>(promise: EventLoopPromise<Response>?,
                                                           with value: Response,
                                                           delegateType: Delegate.Type,
                                                           closing: Bool) {
            promise?.succeed(value)
        }

        func fail<Delegate: HTTPClientResponseDelegate>(with error: Error,
                                                        delegateType: Delegate.Type) {
            self.promise.fail(error)
        }
    }
}

internal struct TaskCancelEvent {}

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

        guard self.request.endpoint.scheme.supportsRedirects(to: url.scheme) else {
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

extension Endpoint.Scheme {
    func supportsRedirects(to destinationScheme: String?) -> Bool {
        guard
            let destinationSchemeString = destinationScheme?.lowercased(),
            let destinationScheme = SupportedScheme(rawValue: destinationSchemeString)
        else {
            return false
        }
        return supportsRedirects(to: destinationScheme)
    }
    
    func supportsRedirects(to destinationScheme: SupportedScheme) -> Bool {
        switch self {
        case .http, .https:
            switch destinationScheme {
            case .http, .https:
                return true
            case .unix, .httpUnix, .httpsUnix:
                return false
            }
        case .unix, .httpUnix, .httpsUnix:
            return true
        }
    }
}

extension RequestBodyLength {
    init(_ body: HTTPClient.Body?) {
        guard let body = body else {
            self = .fixed(length: 0)
            return
        }
        guard let length = body.length else {
            self = .dynamic
            return
        }
        self = .fixed(length: length)
    }
}
