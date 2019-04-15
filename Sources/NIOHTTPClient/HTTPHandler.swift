//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIOHTTPClient open source project
//
// Copyright (c) 2018-2019 Swift Server Working Group and the SwiftNIOHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIOHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOHTTP1
import NIOSSL

public extension HTTPClient {
    enum Body: Equatable {
        case byteBuffer(ByteBuffer)
        case data(Data)
        case string(String)

        var length: Int {
            switch self {
            case .byteBuffer(let buffer):
                return buffer.readableBytes
            case .data(let data):
                return data.count
            case .string(let string):
                return string.utf8.count
            }
        }
    }

    struct Request: Equatable {
        public var version: HTTPVersion
        public var method: HTTPMethod
        public var url: URL
        public var scheme: String
        public var host: String
        public var headers: HTTPHeaders
        public var body: Body?

        public init(url: String, version: HTTPVersion = HTTPVersion(major: 1, minor: 1), method: HTTPMethod = .GET, headers: HTTPHeaders = HTTPHeaders(), body: Body? = nil) throws {
            guard let url = URL(string: url) else {
                throw HTTPClientError.invalidURL
            }

            try self.init(url: url, version: version, method: method, headers: headers, body: body)
        }

        public init(url: URL, version: HTTPVersion, method: HTTPMethod = .GET, headers: HTTPHeaders = HTTPHeaders(), body: Body? = nil) throws {
            guard let scheme = url.scheme else {
                throw HTTPClientError.emptyScheme
            }

            guard Request.isSchemeSupported(scheme: scheme) else {
                throw HTTPClientError.unsupportedScheme(scheme)
            }

            guard let host = url.host else {
                throw HTTPClientError.emptyHost
            }

            self.version = version
            self.method = method
            self.url = url
            self.scheme = scheme
            self.host = host
            self.headers = headers
            self.body = body
        }

        public var useTLS: Bool {
            return self.url.scheme == "https"
        }

        public var port: Int {
            return self.url.port ?? (self.useTLS ? 443 : 80)
        }

        static func isSchemeSupported(scheme: String?) -> Bool {
            return scheme == "http" || scheme == "https"
        }
    }

    struct Response: Equatable {
        public var host: String
        public var status: HTTPResponseStatus
        public var headers: HTTPHeaders
        public var body: ByteBuffer?
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

    func didTransmitRequestBody(task: HTTPClient.Task<Response>) {}

    func didReceiveHead(task: HTTPClient.Task<Response>, _ head: HTTPResponseHead) {
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
    }

    func didReceivePart(task: HTTPClient.Task<Response>, _ part: ByteBuffer) {
        switch self.state {
        case .idle:
            preconditionFailure("no head received before body")
        case .head(let head):
            self.state = .body(head, part)
        case .body(let head, var body):
            var part = part
            body.writeBuffer(&part)
            state = .body(head, body)
        case .end:
            preconditionFailure("request already processed")
        case .error:
            break
        }
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

/// This delegate is strongly held by the HTTPTaskHandler
/// for the duration of the HTTPRequest processing and will be
/// released together with the HTTPTaskHandler when channel is closed
public protocol HTTPClientResponseDelegate: class {
    associatedtype Response

    func didTransmitRequestBody(task: HTTPClient.Task<Response>)

    func didReceiveHead(task: HTTPClient.Task<Response>, _ head: HTTPResponseHead)

    func didReceivePart(task: HTTPClient.Task<Response>, _ buffer: ByteBuffer)

    func didReceiveError(task: HTTPClient.Task<Response>, _ error: Error)

    func didFinishRequest(task: HTTPClient.Task<Response>) throws -> Response
}

extension HTTPClientResponseDelegate {
    func didTransmitRequestBody(task: HTTPClient.Task<Response>) {}

    func didReceiveHead(task: HTTPClient.Task<Response>, _: HTTPResponseHead) {}

    func didReceivePart(task: HTTPClient.Task<Response>, _: ByteBuffer) {}

    func didReceiveError(task: HTTPClient.Task<Response>, _: Error) {}
}

internal extension URL {
    var uri: String {
        return path.isEmpty ? "/" : path + (query.map { "?" + $0 } ?? "")
    }

    func hasTheSameOrigin(as other: URL) -> Bool {
        return host == other.host && scheme == other.scheme && port == other.port
    }
}

public extension HTTPClient {
    final class Task<Response> {
        let future: EventLoopFuture<Response>

        private var channel: Channel?
        private var cancelled: Bool
        private let lock: Lock

        init(future: EventLoopFuture<Response>) {
            self.future = future
            self.cancelled = false
            self.lock = Lock()
        }

        func setChannel(_ channel: Channel) -> Channel {
            return self.lock.withLock {
                self.channel = channel
                return channel
            }
        }

        public func wait() throws -> Response {
            return try self.future.wait()
        }

        public func cancel() {
            self.lock.withLock {
                if !cancelled {
                    cancelled = true
                    channel?.pipeline.fireUserInboundEventTriggered(TaskCancelEvent())
                }
            }
        }

        public func cascade(promise: EventLoopPromise<Response>) {
            self.future.cascade(to: promise)
        }
    }
}

internal struct TaskCancelEvent {}

internal class TaskHandler<T: HTTPClientResponseDelegate>: ChannelInboundHandler, ChannelOutboundHandler {
    typealias OutboundIn = HTTPClient.Request
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart

    enum State {
        case idle
        case sent
        case head
        case redirected(HTTPResponseHead, URL)
        case body
        case end
    }

    let task: HTTPClient.Task<T.Response>
    let delegate: T
    let promise: EventLoopPromise<T.Response>
    let redirectHandler: RedirectHandler<T.Response>?

    var state: State = .idle

    init(task: HTTPClient.Task<T.Response>, delegate: T, promise: EventLoopPromise<T.Response>, redirectHandler: RedirectHandler<T.Response>?) {
        self.task = task
        self.delegate = delegate
        self.promise = promise
        self.redirectHandler = redirectHandler
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        self.state = .idle
        let request = unwrapOutboundIn(data)

        var head = HTTPRequestHead(version: request.version, method: request.method, uri: request.url.uri)
        var headers = request.headers

        if request.version.major == 1, request.version.minor == 1, !request.headers.contains(name: "Host") {
            headers.add(name: "Host", value: request.host)
        }

        do {
            try headers.validate(body: request.body)
        } catch {
            context.fireErrorCaught(error)
            self.state = .end
            return
        }

        head.headers = headers

        context.write(wrapOutboundOut(.head(head)), promise: nil)

        if let body = request.body {
            let part: HTTPClientRequestPart
            switch body {
            case .byteBuffer(let buffer):
                part = HTTPClientRequestPart.body(.byteBuffer(buffer))
            case .data(let data):
                var buffer = context.channel.allocator.buffer(capacity: data.count)
                buffer.writeBytes(data)
                part = HTTPClientRequestPart.body(.byteBuffer(buffer))
            case .string(let string):
                var buffer = context.channel.allocator.buffer(capacity: string.utf8.count)
                buffer.writeString(string)
                part = HTTPClientRequestPart.body(.byteBuffer(buffer))
            }

            context.write(wrapOutboundOut(part), promise: nil)
        }

        context.write(wrapOutboundOut(.end(nil)), promise: promise)
        context.flush()

        self.state = .sent
        self.delegate.didTransmitRequestBody(task: self.task)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let response = unwrapInboundIn(data)
        switch response {
        case .head(let head):
            if let redirectURL = redirectHandler?.redirectTarget(status: head.status, headers: head.headers) {
                self.state = .redirected(head, redirectURL)
            } else {
                self.state = .head
                self.delegate.didReceiveHead(task: self.task, head)
            }
        case .body(let body):
            switch self.state {
            case .redirected:
                break
            default:
                self.state = .body
                self.delegate.didReceivePart(task: self.task, body)
            }
        case .end:
            switch self.state {
            case .redirected(let head, let redirectURL):
                self.state = .end
                self.redirectHandler?.redirect(status: head.status, to: redirectURL, promise: self.promise)
            default:
                self.state = .end
                do {
                    self.promise.succeed(try self.delegate.didFinishRequest(task: self.task))
                } catch {
                    self.promise.fail(error)
                }
            }
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if (event as? IdleStateHandler.IdleStateEvent) == .read {
            self.state = .end
            let error = HTTPClientError.readTimeout
            delegate.didReceiveError(task: self.task, error)
            promise.fail(error)
        } else if (event as? TaskCancelEvent) != nil {
            self.state = .end
            let error = HTTPClientError.cancelled
            delegate.didReceiveError(task: self.task, error)
            promise.fail(error)
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        switch self.state {
        case .end:
            break
        default:
            self.state = .end
            let error = HTTPClientError.remoteConnectionClosed
            delegate.didReceiveError(task: self.task, error)
            promise.fail(error)
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
            default:
                self.state = .end
                self.delegate.didReceiveError(task: self.task, error)
                self.promise.fail(error)
            }
        default:
            self.state = .end
            self.delegate.didReceiveError(task: self.task, error)
            self.promise.fail(error)
        }
    }
}

internal struct RedirectHandler<T> {
    let request: HTTPClient.Request
    let execute: ((HTTPClient.Request) -> HTTPClient.Task<T>)

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

        guard HTTPClient.Request.isSchemeSupported(scheme: url.scheme) else {
            return nil
        }

        if url.isFileURL {
            return nil
        }

        return url.absoluteURL
    }

    func redirect(status: HTTPResponseStatus, to redirectURL: URL, promise: EventLoopPromise<T>) {
        let originalURL = self.request.url

        var request = self.request
        request.url = redirectURL

        var convertToGet = false
        if status == .seeOther, request.method != .HEAD {
            convertToGet = true
        } else if status == .movedPermanently || status == .found, request.method == .POST {
            convertToGet = true
        }

        if convertToGet {
            request.method = .GET
            request.body = nil
            request.headers.remove(name: "Content-Length")
            request.headers.remove(name: "Content-Type")
        }

        if !originalURL.hasTheSameOrigin(as: redirectURL) {
            request.headers.remove(name: "Origin")
            request.headers.remove(name: "Cookie")
            request.headers.remove(name: "Authorization")
            request.headers.remove(name: "Proxy-Authorization")
        }

        return self.execute(request).cascade(promise: promise)
    }
}
