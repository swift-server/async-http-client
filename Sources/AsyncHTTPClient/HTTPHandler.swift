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
import NIO
import NIOConcurrencyHelpers
import NIOHTTP1
import NIOSSL

extension HTTPClient {
    /// Represent request body.
    public struct Body {
        /// Chunk provider.
        public struct StreamWriter {
            let closure: (IOData) -> EventLoopFuture<Void>

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
        ///               unless `Trasfer-Encoding: chunked` header is set.
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
                var buffer = ByteBufferAllocator().buffer(capacity: data.count)
                buffer.writeBytes(data)
                return writer.write(.byteBuffer(buffer))
            }
        }

        /// Create and stream body using `String`.
        ///
        /// - parameters:
        ///     - string: Body `String` representation.
        public static func string(_ string: String) -> Body {
            return Body(length: string.utf8.count) { writer in
                var buffer = ByteBufferAllocator().buffer(capacity: string.utf8.count)
                buffer.writeString(string)
                return writer.write(.byteBuffer(buffer))
            }
        }
    }

    /// Represent HTTP request.
    public struct Request {
        /// Request HTTP method, defaults to `GET`.
        public let method: HTTPMethod
        /// Remote URL.
        public let url: URL
        /// Remote HTTP scheme, resolved from `URL`.
        public let scheme: String
        /// Remote host, resolved from `URL`.
        public let host: String
        /// Request custom HTTP Headers, defaults to no headers.
        public var headers: HTTPHeaders
        /// Request body, defaults to no body.
        public var body: Body?

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
            guard let url = URL(string: url) else {
                throw HTTPClientError.invalidURL
            }

            try self.init(url: url, method: method, headers: headers, body: body)
        }

        /// Create an HTTP `Request`.
        ///
        /// - parameters:
        ///     - url: Remote `URL`.
        ///     - version: HTTP version.
        ///     - method: HTTP method.
        ///     - headers: Custom HTTP headers.
        ///     - body: Request body.
        /// - throws:
        ///     - `emptyScheme` if URL does not contain HTTP scheme.
        ///     - `unsupportedScheme` if URL does contains unsupported HTTP scheme.
        ///     - `emptyHost` if URL does not contains a host.
        public init(url: URL, method: HTTPMethod = .GET, headers: HTTPHeaders = HTTPHeaders(), body: Body? = nil) throws {
            guard let scheme = url.scheme?.lowercased() else {
                throw HTTPClientError.emptyScheme
            }

            guard Request.isSchemeSupported(scheme: scheme) else {
                throw HTTPClientError.unsupportedScheme(scheme)
            }

            guard let host = url.host else {
                throw HTTPClientError.emptyHost
            }

            self.method = method
            self.url = url
            self.scheme = scheme
            self.host = host
            self.headers = headers
            self.body = body

            self.redirectState = nil
        }

        /// Whether request will be executed using secure socket.
        public var useTLS: Bool {
            return self.scheme == "https"
        }

        /// Resolved port.
        public var port: Int {
            return self.url.port ?? (self.useTLS ? 443 : 80)
        }

        static func isSchemeSupported(scheme: String) -> Bool {
            return scheme == "http" || scheme == "https"
        }
    }

    /// Represent HTTP response.
    public struct Response {
        /// Remote host of the request.
        public var host: String
        /// Response HTTP status.
        public var status: HTTPResponseStatus
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
        public init(host: String, status: HTTPResponseStatus, headers: HTTPHeaders, body: ByteBuffer?) {
            self.host = host
            self.status = status
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

internal class ResponseAccumulator: HTTPClientResponseDelegate {
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

    init(request: HTTPClient.Request) {
        self.request = request
    }

    func didReceiveHead(task: HTTPClient.Task<Response>, _ head: HTTPResponseHead) -> EventLoopFuture<Void> {
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

    func didReceiveBodyPart(task: HTTPClient.Task<Response>, _ part: ByteBuffer) -> EventLoopFuture<Void> {
        switch self.state {
        case .idle:
            preconditionFailure("no head received before body")
        case .head(let head):
            self.state = .body(head, part)
        case .body(let head, var body):
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

    func didReceiveError(task: HTTPClient.Task<Response>, _ error: Error) {
        self.state = .error(error)
    }

    func didFinishRequest(task: HTTPClient.Task<Response>) throws -> Response {
        switch self.state {
        case .idle:
            preconditionFailure("no head received before end")
        case .head(let head):
            return Response(host: self.request.host, status: head.status, headers: head.headers, body: nil)
        case .body(let head, let body):
            return Response(host: self.request.host, status: head.status, headers: head.headers, body: body)
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
/// class to the `HTTPClient.execute()` method and this package will call each delegate method appropriately as the request takes place.
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
    /// - parameters:
    ///     - task: Current request context.
    ///     - buffer: Received body `Part`.
    /// - returns: `EventLoopFuture` that will be used for backpressure.
    func didReceiveBodyPart(task: HTTPClient.Task<Response>, _ buffer: ByteBuffer) -> EventLoopFuture<Void>

    /// Called when error was thrown during request execution. Will be called zero or one time only. Request processing will be stopped after that.
    ///
    /// - parameters:
    ///     - task: Current request context.
    ///     - error: Error that occured during response processing.
    func didReceiveError(task: HTTPClient.Task<Response>, _ error: Error)

    /// Called when the complete HTTP request is finished. You must return an instance of your `Response` associated type. Will be called once, except if an error occurred.
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
        return self.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? self.path
    }

    var pathHasTrailingSlash: Bool {
        if #available(OSX 10.11, iOS 9.0, tvOS 9.0, watchOS 2.0, *) {
            return self.hasDirectoryPath
        } else {
            // Most platforms should use `self.hasDirectoryPath`, but on older darwin platforms
            // we have this approximation instead.
            let url = self.absoluteString

            var pathEndIndex = url.index(before: url.endIndex)
            if let queryIndex = url.firstIndex(of: "?") {
                pathEndIndex = url.index(before: queryIndex)
            } else if let fragmentIndex = url.suffix(from: url.firstIndex(of: "@") ?? url.startIndex).lastIndex(of: "#") {
                pathEndIndex = url.index(before: fragmentIndex)
            }

            return url[pathEndIndex] == "/"
        }
    }

    var uri: String {
        var uri = self.percentEncodedPath
        if self.pathHasTrailingSlash, uri != "/" {
            uri += "/"
        }

        if let query = self.query {
            uri += "?" + query
        }

        return uri
    }

    func hasTheSameOrigin(as other: URL) -> Bool {
        return self.host == other.host && self.scheme == other.scheme && self.port == other.port
    }
}

extension HTTPClient {
    /// Response execution context. Will be created by the library and could be used for obtaining
    /// `EventLoopFuture<Response>` of the execution or cancellation of the execution.
    public final class Task<Response> {
        /// The `EventLoop` the delegate will be executed on.
        public let eventLoop: EventLoop

        let promise: EventLoopPromise<Response>
        var channel: Channel?
        private var cancelled: Bool
        private let lock: Lock

        init(eventLoop: EventLoop) {
            self.eventLoop = eventLoop
            self.promise = eventLoop.makePromise()
            self.cancelled = false
            self.lock = Lock()
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
                if !cancelled {
                    cancelled = true
                    return self.channel
                }
                return nil
            }
            channel?.triggerUserOutboundEvent(TaskCancelEvent(), promise: nil)
        }

        @discardableResult
        func setChannel(_ channel: Channel) -> Channel {
            return self.lock.withLock {
                self.channel = channel
                return channel
            }
        }
    }
}

internal struct TaskCancelEvent {}

// MARK: - TaskHandler

internal class TaskHandler<Delegate: HTTPClientResponseDelegate> {
    enum State {
        case idle
        case sent
        case head
        case redirected(HTTPResponseHead, URL)
        case body
        case end
    }

    let task: HTTPClient.Task<Delegate.Response>
    let delegate: Delegate
    let redirectHandler: RedirectHandler<Delegate.Response>?
    let ignoreUncleanSSLShutdown: Bool

    var state: State = .idle
    var pendingRead = false
    var mayRead = true

    init(task: HTTPClient.Task<Delegate.Response>, delegate: Delegate, redirectHandler: RedirectHandler<Delegate.Response>?, ignoreUncleanSSLShutdown: Bool) {
        self.task = task
        self.delegate = delegate
        self.redirectHandler = redirectHandler
        self.ignoreUncleanSSLShutdown = ignoreUncleanSSLShutdown
    }
}

// MARK: Delegate Callouts

extension TaskHandler {
    func failTaskAndNotifyDelegate<Err: Error>(error: Err,
                                               _ body: @escaping (HTTPClient.Task<Delegate.Response>, Err) -> Void) {
        func doIt() {
            body(self.task, error)
            self.task.promise.fail(error)
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
                                     _ body: @escaping (HTTPClient.Task<Delegate.Response>) throws -> Response) {
        func doIt() {
            do {
                let result = try body(self.task)
                promise?.succeed(result)
            } catch {
                promise?.fail(error)
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
                                     _ body: @escaping (HTTPClient.Task<Delegate.Response>) throws -> Response) -> EventLoopFuture<Response> {
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
        self.state = .idle
        let request = unwrapOutboundIn(data)

        var head = HTTPRequestHead(version: HTTPVersion(major: 1, minor: 1), method: request.method, uri: request.url.uri)
        var headers = request.headers

        if !request.headers.contains(name: "Host") {
            headers.add(name: "Host", value: request.host)
        }

        headers.add(name: "Connection", value: "close")

        do {
            try headers.validate(body: request.body)
        } catch {
            promise?.fail(error)
            context.fireErrorCaught(error)
            self.state = .end
            return
        }

        head.headers = headers

        context.write(wrapOutboundOut(.head(head))).map {
            self.callOutToDelegateFireAndForget(value: head, self.delegate.didSendRequestHead)
        }.flatMap {
            self.writeBody(request: request, context: context)
        }.flatMap {
            context.eventLoop.assertInEventLoop()
            return context.writeAndFlush(self.wrapOutboundOut(.end(nil)))
        }.map {
            context.eventLoop.assertInEventLoop()
            self.state = .sent
            self.callOutToDelegateFireAndForget(self.delegate.didSendRequest)

            let channel = context.channel
            self.task.futureResult.whenComplete { _ in
                channel.close(promise: nil)
            }
        }.flatMapErrorThrowing { error in
            context.eventLoop.assertInEventLoop()
            self.state = .end
            self.failTaskAndNotifyDelegate(error: error, self.delegate.didReceiveError)
            context.close(promise: nil)
            throw error
        }.cascade(to: promise)
    }

    private func writeBody(request: HTTPClient.Request, context: ChannelHandlerContext) -> EventLoopFuture<Void> {
        guard let body = request.body else {
            return context.eventLoop.makeSucceededFuture(())
        }

        return body.stream(HTTPClient.Body.StreamWriter { part in
            context.eventLoop.assertInEventLoop()
            return context.writeAndFlush(self.wrapOutboundOut(.body(part))).map {
                self.callOutToDelegateFireAndForget(value: part, self.delegate.didSendRequestPart)
            }
        })
    }

    public func read(context: ChannelHandlerContext) {
        if self.mayRead {
            self.pendingRead = false
            context.read()
        } else {
            self.pendingRead = true
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let response = self.unwrapInboundIn(data)
        switch response {
        case .head(let head):
            if let redirectURL = redirectHandler?.redirectTarget(status: head.status, headers: head.headers) {
                self.state = .redirected(head, redirectURL)
            } else {
                self.state = .head
                self.mayRead = false
                self.callOutToDelegate(value: head, channelEventLoop: context.eventLoop, self.delegate.didReceiveHead)
                    .whenComplete { result in
                        self.handleBackpressureResult(context: context, result: result)
                    }
            }
        case .body(let body):
            switch self.state {
            case .redirected:
                break
            default:
                self.state = .body
                self.mayRead = false
                self.callOutToDelegate(value: body, channelEventLoop: context.eventLoop, self.delegate.didReceiveBodyPart)
                    .whenComplete { result in
                        self.handleBackpressureResult(context: context, result: result)
                    }
            }
        case .end:
            switch self.state {
            case .redirected(let head, let redirectURL):
                self.state = .end
                self.redirectHandler?.redirect(status: head.status, to: redirectURL, promise: self.task.promise)
                context.close(promise: nil)
            default:
                self.state = .end
                self.callOutToDelegate(promise: self.task.promise, self.delegate.didFinishRequest)
            }
        }
    }

    private func handleBackpressureResult(context: ChannelHandlerContext, result: Result<Void, Error>) {
        context.eventLoop.assertInEventLoop()
        switch result {
        case .success:
            self.mayRead = true
            if self.pendingRead {
                context.read()
            }
        case .failure(let error):
            self.state = .end
            self.failTaskAndNotifyDelegate(error: error, self.delegate.didReceiveError)
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if (event as? IdleStateHandler.IdleStateEvent) == .read {
            self.state = .end
            let error = HTTPClientError.readTimeout
            self.failTaskAndNotifyDelegate(error: error, self.delegate.didReceiveError)
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    func triggerUserOutboundEvent(context: ChannelHandlerContext, event: Any, promise: EventLoopPromise<Void>?) {
        if (event as? TaskCancelEvent) != nil {
            self.state = .end
            let error = HTTPClientError.cancelled
            self.failTaskAndNotifyDelegate(error: error, self.delegate.didReceiveError)
            promise?.succeed(())
        } else {
            context.triggerUserOutboundEvent(event, promise: promise)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        switch self.state {
        case .end:
            break
        default:
            self.state = .end
            let error = HTTPClientError.remoteConnectionClosed
            self.failTaskAndNotifyDelegate(error: error, self.delegate.didReceiveError)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        switch error {
        case NIOSSLError.uncleanShutdown:
            switch self.state {
            case .end:
                /// Some HTTP Servers can 'forget' to respond with CloseNotify when client is closing connection,
                /// this could lead to incomplete SSL shutdown. But since request is already processed, we can ignore this error.
                break
            case .head where self.ignoreUncleanSSLShutdown,
                 .body where self.ignoreUncleanSSLShutdown:
                /// We can also ignore this error like `.end`.
                break
            default:
                self.state = .end
                self.failTaskAndNotifyDelegate(error: error, self.delegate.didReceiveError)
            }
        default:
            self.state = .end
            self.failTaskAndNotifyDelegate(error: error, self.delegate.didReceiveError)
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

        guard let location = headers.first(where: { $0.name == "Location" }) else {
            return nil
        }

        guard let url = URL(string: location.value, relativeTo: request.url) else {
            return nil
        }

        guard HTTPClient.Request.isSchemeSupported(scheme: self.request.scheme) else {
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
            return self.execute(newRequest).futureResult.cascade(to: promise)
        } catch {
            return promise.fail(error)
        }
    }
}
