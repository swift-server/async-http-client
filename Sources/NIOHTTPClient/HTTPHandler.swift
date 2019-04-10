//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIOHTTP open source project
//
// Copyright (c) 2017-2018 Swift Server Working Group and the SwiftNIOHTTP project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIOHTTP project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation
import NIO
import NIOHTTP1
import NIOSSL
import NIOConcurrencyHelpers

protocol HTTPClientError : Error { }

public struct HTTPClientErrors {

    public struct InvalidURLError : HTTPClientError {
    }

    public struct EmptyHostError : HTTPClientError {
    }

    public struct AlreadyShutdown : HTTPClientError {
    }

    public struct EmptySchemeError : HTTPClientError {
    }

    public struct UnsupportedSchemeError : HTTPClientError {
        var scheme: String
    }

    public struct ReadTimeoutError : HTTPClientError {
    }

    public struct RemoteConnectionClosedError : HTTPClientError {
    }

    public struct CancelledError : HTTPClientError {
    }
}

public enum HTTPBody : Equatable {
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
            return string.count
        }
    }
}

public struct HTTPRequest : Equatable {

    public var version: HTTPVersion
    public var method: HTTPMethod
    public var url: URL
    public var scheme: String
    public var host: String
    public var headers: HTTPHeaders
    public var body: HTTPBody?

    public init(url: String, version: HTTPVersion = HTTPVersion(major: 1, minor: 1), method: HTTPMethod = .GET, headers: HTTPHeaders = HTTPHeaders(), body: HTTPBody? = nil) throws {
        guard let url = URL(string: url) else {
            throw HTTPClientErrors.InvalidURLError()
        }

        try self.init(url: url, version: version, method: method, headers: headers, body: body)
    }

    public init(url: URL, version: HTTPVersion, method: HTTPMethod = .GET, headers: HTTPHeaders = HTTPHeaders(), body: HTTPBody? = nil) throws {
        guard let scheme = url.scheme else {
            throw HTTPClientErrors.EmptySchemeError()
        }

        guard HTTPRequest.isSchemeSupported(scheme: scheme) else {
            throw HTTPClientErrors.UnsupportedSchemeError(scheme: scheme)
        }

        guard let host = url.host else {
            throw HTTPClientErrors.EmptyHostError()
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
        return url.scheme == "https"
    }

    public var port: Int {
        return url.port ?? (useTLS ? 443 : 80)
    }

    static func isSchemeSupported(scheme: String?) -> Bool {
        return scheme == "http" || scheme == "https"
    }
}

public struct HTTPResponse : Equatable {
    public var host: String
    public var status: HTTPResponseStatus
    public var headers: HTTPHeaders
    public var body: ByteBuffer?
}

/// This delegate is strongly held by the HTTPTaskHandler
/// for the duration of the HTTPRequest processing and will be
/// released together with the HTTPTaskHandler when channel is closed
public protocol HTTPResponseDelegate : class {
    associatedtype Response

    func didTransmitRequestBody()

    func didReceiveHead(_ head: HTTPResponseHead)

    func didReceivePart(_ buffer: ByteBuffer)

    func didReceiveError(_ error: Error)

    func didFinishRequest() throws -> Response
}

extension HTTPResponseDelegate {

    func didTransmitRequestBody() {
    }

    func didReceiveHead(_ head: HTTPResponseHead) {
    }

    func didReceivePart(_ buffer: ByteBuffer) {
    }

    func didReceiveError(_ error: Error) {
    }
}

class HTTPResponseAccumulator : HTTPResponseDelegate {
    typealias Response = HTTPResponse

    enum State {
        case idle
        case head(HTTPResponseHead)
        case body(HTTPResponseHead, ByteBuffer)
        case end
        case error(Error)
    }

    var state = State.idle
    let request: HTTPRequest

    init(request: HTTPRequest) {
        self.request = request
    }

    func didTransmitRequestBody() {
    }

    func didReceiveHead(_ head: HTTPResponseHead) {
        switch state {
        case .idle:
            state = .head(head)
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

    func didReceivePart(_ part: ByteBuffer) {
        switch state {
        case .idle:
            preconditionFailure("no head received before body")
        case .head(let head):
            state = .body(head, part)
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

    func didReceiveError(_ error: Error) {
        state = .error(error)
    }

    func didFinishRequest() throws -> HTTPResponse {
        switch state {
        case .idle:
            preconditionFailure("no head received before end")
        case .head(let head):
            return HTTPResponse(host: request.host, status: head.status, headers: head.headers, body: nil)
        case .body(let head, let body):
            return HTTPResponse(host: request.host, status: head.status, headers: head.headers, body: body)
        case .end:
            preconditionFailure("request already processed")
        case .error(let error):
            throw error
        }
    }
}

internal extension URL {
    var uri: String {
        return path.isEmpty ? "/" : path + (query.map { "?" + $0 } ?? "")
    }

    func hasTheSameOrigin(as other: URL) -> Bool {
        return host == other.host && scheme == other.scheme && port == other.port
    }
}

struct CancelEvent {
}

public final class HTTPTask<Response> {

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
        return lock.withLock {
            self.channel = channel
            return channel
        }
    }

    public func wait() throws -> Response {
        return try future.wait()
    }

    public func cancel() {
        lock.withLock {
            if !cancelled {
                cancelled = true
                channel?.pipeline.fireUserInboundEventTriggered(CancelEvent())
            }
        }
    }

    public func cascade(promise: EventLoopPromise<Response>) {
        future.cascade(to: promise)
    }

}

class HTTPTaskHandler<T: HTTPResponseDelegate> : ChannelInboundHandler, ChannelOutboundHandler {
    typealias OutboundIn = HTTPRequest
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

    let delegate: T
    let promise: EventLoopPromise<T.Response>
    let redirectHandler: RedirectHandler<T.Response>?

    var state: State = .idle

    init(delegate: T, promise: EventLoopPromise<T.Response>, redirectHandler: RedirectHandler<T.Response>?) {
        self.delegate = delegate
        self.promise = promise
        self.redirectHandler = redirectHandler
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        state = .idle
        let request = unwrapOutboundIn(data)

        var head = HTTPRequestHead(version: request.version, method: request.method, uri: request.url.uri)
        var headers = request.headers

        if request.version.major == 1 && request.version.minor == 1 && !request.headers.contains(name: "Host") {
            headers.add(name: "Host", value: request.host)
        }

        do {
            try headers.validate(body: request.body)
        } catch {
            context.fireErrorCaught(error)
            state = .end
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
                var buffer = context.channel.allocator.buffer(capacity: string.count)
                buffer.writeString(string)
                part = HTTPClientRequestPart.body(.byteBuffer(buffer))
            }

            context.write(wrapOutboundOut(part), promise: nil)
        }

        context.write(wrapOutboundOut(.end(nil)), promise: promise)
        context.flush()

        state = .sent
        delegate.didTransmitRequestBody()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let response = unwrapInboundIn(data)
        switch response {
        case .head(let head):
            if let redirectURL = redirectHandler?.redirectTarget(status: head.status, headers: head.headers) {
                state = .redirected(head, redirectURL)
            } else {
                state = .head
                delegate.didReceiveHead(head)
            }
        case .body(let body):
            switch state {
            case .redirected:
                break
            default:
                state = .body
                delegate.didReceivePart(body)
            }
        case .end:
            switch state {
            case .redirected(let head, let redirectURL):
                state = .end
                redirectHandler?.redirect(status: head.status, to: redirectURL, promise: promise)
            default:
                state = .end
                do {
                    promise.succeed(try delegate.didFinishRequest())
                } catch {
                    promise.fail(error)
                }
            }
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if (event as? IdleStateHandler.IdleStateEvent) == .read {
            state = .end
            let error = HTTPClientErrors.ReadTimeoutError()
            delegate.didReceiveError(error)
            promise.fail(error)
        } else if (event as? CancelEvent) != nil {
            state = .end
            let error = HTTPClientErrors.CancelledError()
            delegate.didReceiveError(error)
            promise.fail(error)
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        switch state {
        case .end:
            break
        default:
            state = .end
            let error = HTTPClientErrors.RemoteConnectionClosedError()
            delegate.didReceiveError(error)
            promise.fail(error)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        switch error {
        case NIOSSLError.uncleanShutdown:
            switch state {
            case .end:
                /// Some HTTP Servers can 'forget' to respond with CloseNotify when client is closing connection,
                /// this could lead to incomplete SSL shutdown. But since request is already processed, we can ignore this error.
                break
            default:
                state = .end
                delegate.didReceiveError(error)
                promise.fail(error)
            }
        default:
            state = .end
            delegate.didReceiveError(error)
            promise.fail(error)
        }
    }
}

struct RedirectHandler<T> {

    let request: HTTPRequest
    let execute: ((HTTPRequest) -> HTTPTask<T>)

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

        guard HTTPRequest.isSchemeSupported(scheme: url.scheme) else {
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
        if status == .seeOther && request.method != .HEAD {
            convertToGet = true
        } else if (status == .movedPermanently || status == .found) && request.method == .POST {
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

        return execute(request).cascade(promise: promise)
    }
}
