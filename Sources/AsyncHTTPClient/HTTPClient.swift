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
import NIOHTTPCompression
import NIOSSL

/// HTTPClient class provides API for request execution.
///
/// Example:
///
/// ```swift
///     let client = HTTPClient(eventLoopGroupProvider = .createNew)
///     client.get(url: "https://swift.org", deadline: .now() + .seconds(1)).whenComplete { result in
///         switch result {
///         case .failure(let error):
///             // process error
///         case .success(let response):
///             if let response.status == .ok {
///                 // handle response
///             } else {
///                 // handle remote error
///             }
///         }
///     }
/// ```
///
/// It is important to close the client instance, for example in a defer statement, after use to cleanly shutdown the underlying NIO `EventLoopGroup`:
///
/// ```swift
///     try client.syncShutdown()
/// ```
public class HTTPClient {
    public let eventLoopGroup: EventLoopGroup
    let eventLoopGroupProvider: EventLoopGroupProvider
    let configuration: Configuration
    let isShutdown = Atomic<Bool>(value: false)

    /// Create an `HTTPClient` with specified `EventLoopGroup` provider and configuration.
    ///
    /// - parameters:
    ///     - eventLoopGroupProvider: Specify how `EventLoopGroup` will be created.
    ///     - configuration: Client configuration.
    public init(eventLoopGroupProvider: EventLoopGroupProvider, configuration: Configuration = Configuration()) {
        self.eventLoopGroupProvider = eventLoopGroupProvider
        switch self.eventLoopGroupProvider {
        case .shared(let group):
            self.eventLoopGroup = group
        case .createNew:
            self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        }
        self.configuration = configuration
    }

    deinit {
        assert(self.isShutdown.load(), "Client not shut down before the deinit. Please call client.syncShutdown() when no longer needed.")
    }

    /// Shuts down the client and `EventLoopGroup` if it was created by the client.
    public func syncShutdown() throws {
        switch self.eventLoopGroupProvider {
        case .shared:
            self.isShutdown.store(true)
            return
        case .createNew:
            if self.isShutdown.compareAndExchange(expected: false, desired: true) {
                try self.eventLoopGroup.syncShutdownGracefully()
            } else {
                throw HTTPClientError.alreadyShutdown
            }
        }
    }

    /// Execute `GET` request using specified URL.
    ///
    /// - parameters:
    ///     - url: Remote URL.
    ///     - deadline: Point in time by which the request must complete.
    public func get(url: String, deadline: NIODeadline? = nil) -> EventLoopFuture<Response> {
        do {
            let request = try Request(url: url, method: .GET)
            return self.execute(request: request, deadline: deadline)
        } catch {
            return self.eventLoopGroup.next().makeFailedFuture(error)
        }
    }

    /// Execute `POST` request using specified URL.
    ///
    /// - parameters:
    ///     - url: Remote URL.
    ///     - body: Request body.
    ///     - deadline: Point in time by which the request must complete.
    public func post(url: String, body: Body? = nil, deadline: NIODeadline? = nil) -> EventLoopFuture<Response> {
        do {
            let request = try HTTPClient.Request(url: url, method: .POST, body: body)
            return self.execute(request: request, deadline: deadline)
        } catch {
            return self.eventLoopGroup.next().makeFailedFuture(error)
        }
    }

    /// Execute `PATCH` request using specified URL.
    ///
    /// - parameters:
    ///     - url: Remote URL.
    ///     - body: Request body.
    ///     - deadline: Point in time by which the request must complete.
    public func patch(url: String, body: Body? = nil, deadline: NIODeadline? = nil) -> EventLoopFuture<Response> {
        do {
            let request = try HTTPClient.Request(url: url, method: .PATCH, body: body)
            return self.execute(request: request, deadline: deadline)
        } catch {
            return self.eventLoopGroup.next().makeFailedFuture(error)
        }
    }

    /// Execute `PUT` request using specified URL.
    ///
    /// - parameters:
    ///     - url: Remote URL.
    ///     - body: Request body.
    ///     - deadline: Point in time by which the request must complete.
    public func put(url: String, body: Body? = nil, deadline: NIODeadline? = nil) -> EventLoopFuture<Response> {
        do {
            let request = try HTTPClient.Request(url: url, method: .PUT, body: body)
            return self.execute(request: request, deadline: deadline)
        } catch {
            return self.eventLoopGroup.next().makeFailedFuture(error)
        }
    }

    /// Execute `DELETE` request using specified URL.
    ///
    /// - parameters:
    ///     - url: Remote URL.
    ///     - deadline: The time when the request must have been completed by.
    public func delete(url: String, deadline: NIODeadline? = nil) -> EventLoopFuture<Response> {
        do {
            let request = try Request(url: url, method: .DELETE)
            return self.execute(request: request, deadline: deadline)
        } catch {
            return self.eventLoopGroup.next().makeFailedFuture(error)
        }
    }

    /// Execute arbitrary HTTP request using specified URL.
    ///
    /// - parameters:
    ///     - request: HTTP request to execute.
    ///     - deadline: Point in time by which the request must complete.
    public func execute(request: Request, deadline: NIODeadline? = nil) -> EventLoopFuture<Response> {
        let accumulator = ResponseAccumulator(request: request)
        return self.execute(request: request, delegate: accumulator, deadline: deadline).futureResult
    }

    /// Execute arbitrary HTTP request using specified URL.
    ///
    /// - parameters:
    ///     - request: HTTP request to execute.
    ///     - eventLoop: NIO Event Loop preference.
    ///     - deadline: Point in time by which the request must complete.
    public func execute(request: Request, eventLoop: EventLoopPreference, deadline: NIODeadline? = nil) -> EventLoopFuture<Response> {
        let accumulator = ResponseAccumulator(request: request)
        return self.execute(request: request, delegate: accumulator, eventLoop: eventLoop, deadline: deadline).futureResult
    }

    /// Execute arbitrary HTTP request and handle response processing using provided delegate.
    ///
    /// - parameters:
    ///     - request: HTTP request to execute.
    ///     - delegate: Delegate to process response parts.
    ///     - deadline: Point in time by which the request must complete.
    public func execute<Delegate: HTTPClientResponseDelegate>(request: Request,
                                                              delegate: Delegate,
                                                              deadline: NIODeadline? = nil) -> Task<Delegate.Response> {
        let eventLoop = self.eventLoopGroup.next()
        return self.execute(request: request, delegate: delegate, eventLoop: eventLoop, deadline: deadline)
    }

    /// Execute arbitrary HTTP request and handle response processing using provided delegate.
    ///
    /// - parameters:
    ///     - request: HTTP request to execute.
    ///     - delegate: Delegate to process response parts.
    ///     - eventLoop: NIO Event Loop preference.
    ///     - deadline: Point in time by which the request must complete.
    public func execute<Delegate: HTTPClientResponseDelegate>(request: Request,
                                                              delegate: Delegate,
                                                              eventLoop: EventLoopPreference,
                                                              deadline: NIODeadline? = nil) -> Task<Delegate.Response> {
        switch eventLoop.preference {
        case .indifferent:
            return self.execute(request: request, delegate: delegate, eventLoop: self.eventLoopGroup.next(), deadline: deadline)
        case .delegate(on: let eventLoop):
            precondition(self.eventLoopGroup.makeIterator().contains { $0 === eventLoop }, "Provided EventLoop must be part of clients EventLoopGroup.")
            return self.execute(request: request, delegate: delegate, eventLoop: eventLoop, deadline: deadline)
        case .delegateAndChannel(on: let eventLoop):
            precondition(self.eventLoopGroup.makeIterator().contains { $0 === eventLoop }, "Provided EventLoop must be part of clients EventLoopGroup.")
            return self.execute(request: request, delegate: delegate, eventLoop: eventLoop, deadline: deadline)
        case .testOnly_exact(channelOn: let channelEL, delegateOn: let delegateEL):
            return self.execute(request: request,
                                delegate: delegate,
                                eventLoop: delegateEL,
                                channelEL: channelEL,
                                deadline: deadline)
        }
    }

    private func execute<Delegate: HTTPClientResponseDelegate>(request: Request,
                                                               delegate: Delegate,
                                                               eventLoop delegateEL: EventLoop,
                                                               channelEL: EventLoop? = nil,
                                                               deadline: NIODeadline? = nil) -> Task<Delegate.Response> {
        let redirectHandler: RedirectHandler<Delegate.Response>?
        switch self.configuration.redirectConfiguration.configuration {
        case .follow(let max, let allowCycles):
            var request = request
            if request.redirectState == nil {
                request.redirectState = .init(count: max, visited: allowCycles ? nil : Set())
            }
            redirectHandler = RedirectHandler<Delegate.Response>(request: request) { newRequest in
                self.execute(request: newRequest,
                             delegate: delegate,
                             eventLoop: delegateEL,
                             channelEL: channelEL,
                             deadline: deadline)
            }
        case .disallow:
            redirectHandler = nil
        }

        let task = Task<Delegate.Response>(eventLoop: delegateEL)

        var bootstrap = ClientBootstrap(group: channelEL ?? delegateEL)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
            .channelInitializer { channel in
                let encoder = HTTPRequestEncoder()
                let decoder = ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .forwardBytes))
                return channel.pipeline.addHandlers([encoder, decoder], position: .first).flatMap {
                    switch self.configuration.proxy {
                    case .none:
                        return channel.pipeline.addSSLHandlerIfNeeded(for: request, tlsConfiguration: self.configuration.tlsConfiguration)
                    case .some(let proxy):
                        return channel.pipeline.addProxyHandler(for: request, decoder: decoder, encoder: encoder, tlsConfiguration: self.configuration.tlsConfiguration, proxy: proxy)
                    }
                }.flatMap {
                    switch self.configuration.decompression {
                    case .disabled:
                        return channel.eventLoop.makeSucceededFuture(())
                    case .enabled(let limit):
                        return channel.pipeline.addHandler(NIOHTTPResponseDecompressor(limit: limit))
                    }
                }.flatMap {
                    if let timeout = self.resolve(timeout: self.configuration.timeout.read, deadline: deadline) {
                        return channel.pipeline.addHandler(IdleStateHandler(readTimeout: timeout))
                    } else {
                        return channel.eventLoop.makeSucceededFuture(())
                    }
                }.flatMap {
                    let taskHandler = TaskHandler(task: task, delegate: delegate, redirectHandler: redirectHandler, ignoreUncleanSSLShutdown: self.configuration.ignoreUncleanSSLShutdown)
                    return channel.pipeline.addHandler(taskHandler)
                }
            }

        if let timeout = self.resolve(timeout: self.configuration.timeout.connect, deadline: deadline) {
            bootstrap = bootstrap.connectTimeout(timeout)
        }

        let address = self.resolveAddress(request: request, proxy: self.configuration.proxy)
        bootstrap.connect(host: address.host, port: address.port)
            .map { channel in
                task.setChannel(channel)
            }
            .flatMap { channel in
                channel.writeAndFlush(request)
            }
            .cascadeFailure(to: task.promise)

        return task
    }

    private func resolve(timeout: TimeAmount?, deadline: NIODeadline?) -> TimeAmount? {
        switch (timeout, deadline) {
        case (.some(let timeout), .some(let deadline)):
            return min(timeout, deadline - .now())
        case (.some(let timeout), .none):
            return timeout
        case (.none, .some(let deadline)):
            return deadline - .now()
        case (.none, .none):
            return nil
        }
    }

    private func resolveAddress(request: Request, proxy: Configuration.Proxy?) -> (host: String, port: Int) {
        switch self.configuration.proxy {
        case .none:
            return (request.host, request.port)
        case .some(let proxy):
            return (proxy.host, proxy.port)
        }
    }

    /// `HTTPClient` configuration.
    public struct Configuration {
        /// TLS configuration, defaults to `TLSConfiguration.forClient()`.
        public var tlsConfiguration: TLSConfiguration?
        /// Enables following 3xx redirects automatically, defaults to `false`.
        ///
        /// Following redirects are supported:
        ///  - `301: Moved Permanently`
        ///  - `302: Found`
        ///  - `303: See Other`
        ///  - `304: Not Modified`
        ///  - `305: Use Proxy`
        ///  - `307: Temporary Redirect`
        ///  - `308: Permanent Redirect`
        public var redirectConfiguration: RedirectConfiguration
        /// Default client timeout, defaults to no timeouts.
        public var timeout: Timeout
        /// Upstream proxy, defaults to no proxy.
        public var proxy: Proxy?
        /// Enables automatic body decompression. Supported algorithms are gzip and deflate.
        public var decompression: Decompression
        /// Ignore TLS unclean shutdown error, defaults to `false`.
        public var ignoreUncleanSSLShutdown: Bool

        public init(tlsConfiguration: TLSConfiguration? = nil,
                    redirectConfiguration: RedirectConfiguration? = nil,
                    timeout: Timeout = Timeout(),
                    proxy: Proxy? = nil,
                    ignoreUncleanSSLShutdown: Bool = false,
                    decompression: Decompression = .disabled) {
            self.tlsConfiguration = tlsConfiguration
            self.redirectConfiguration = redirectConfiguration ?? RedirectConfiguration()
            self.timeout = timeout
            self.proxy = proxy
            self.ignoreUncleanSSLShutdown = ignoreUncleanSSLShutdown
            self.decompression = decompression
        }

        public init(certificateVerification: CertificateVerification,
                    redirectConfiguration: RedirectConfiguration? = nil,
                    timeout: Timeout = Timeout(),
                    proxy: Proxy? = nil,
                    ignoreUncleanSSLShutdown: Bool = false,
                    decompression: Decompression = .disabled) {
            self.tlsConfiguration = TLSConfiguration.forClient(certificateVerification: certificateVerification)
            self.redirectConfiguration = redirectConfiguration ?? RedirectConfiguration()
            self.timeout = timeout
            self.proxy = proxy
            self.ignoreUncleanSSLShutdown = ignoreUncleanSSLShutdown
            self.decompression = decompression
        }
    }

    /// Specifies how `EventLoopGroup` will be created and establishes lifecycle ownership.
    public enum EventLoopGroupProvider {
        /// `EventLoopGroup` will be provided by the user. Owner of this group is responsible for its lifecycle.
        case shared(EventLoopGroup)
        /// `EventLoopGroup` will be created by the client. When `syncShutdown` is called, created `EventLoopGroup` will be shut down as well.
        case createNew
    }

    /// Specifies how the library will treat event loop passed by the user.
    public struct EventLoopPreference {
        enum Preference {
            /// Event Loop will be selected by the library.
            case indifferent
            /// The delegate will be run on the specified EventLoop (and the Channel if possible).
            case delegate(on: EventLoop)
            /// The delegate and the `Channel` will be run on the specified EventLoop.
            case delegateAndChannel(on: EventLoop)

            case testOnly_exact(channelOn: EventLoop, delegateOn: EventLoop)
        }

        var preference: Preference

        init(_ preference: Preference) {
            self.preference = preference
        }

        /// Event Loop will be selected by the library.
        public static let indifferent = EventLoopPreference(.indifferent)

        /// The delegate will be run on the specified EventLoop (and the Channel if possible).
        ///
        /// This will call the configured delegate on `eventLoop` and will try to use a `Channel` on the same
        /// `EventLoop` but will not establish a new network connection just to satisfy the `EventLoop` preference if
        /// another existing connection on a different `EventLoop` is readily available from a connection pool.
        public static func delegate(on eventLoop: EventLoop) -> EventLoopPreference {
            return EventLoopPreference(.delegate(on: eventLoop))
        }

        /// The delegate and the `Channel` will be run on the specified EventLoop.
        ///
        /// Use this for use-cases where you prefer a new connection to be established over re-using an existing
        /// connection that might be on a different `EventLoop`.
        public static func delegateAndChannel(on eventLoop: EventLoop) -> EventLoopPreference {
            return EventLoopPreference(.delegateAndChannel(on: eventLoop))
        }
    }

    /// Specifies decompression settings.
    public enum Decompression {
        /// Decompression is disabled.
        case disabled
        /// Decompression is enabled.
        case enabled(limit: NIOHTTPDecompression.DecompressionLimit)
    }
}

extension HTTPClient.Configuration {
    /// Timeout configuration
    public struct Timeout {
        /// Specifies connect timeout.
        public var connect: TimeAmount?
        /// Specifies read timeout.
        public var read: TimeAmount?

        /// Create timeout.
        ///
        /// - parameters:
        ///     - connect: `connect` timeout.
        ///     - read: `read` timeout.
        public init(connect: TimeAmount? = nil, read: TimeAmount? = nil) {
            self.connect = connect
            self.read = read
        }
    }

    /// Specifies redirect processing settings.
    public struct RedirectConfiguration {
        enum Configuration {
            /// Redirects are not followed.
            case disallow
            /// Redirects are followed with a specified limit.
            case follow(max: Int, allowCycles: Bool)
        }

        var configuration: Configuration

        init() {
            self.configuration = .follow(max: 5, allowCycles: false)
        }

        init(configuration: Configuration) {
            self.configuration = configuration
        }

        /// Redirects are not followed.
        public static let disallow = RedirectConfiguration(configuration: .disallow)

        /// Redirects are followed with a specified limit.
        ///
        /// - parameters:
        ///     - max: The maximum number of allowed redirects.
        ///     - allowCycles: Whether cycles are allowed.
        ///
        /// - warning: Cycle detection will keep all visited URLs in memory which means a malicious server could use this as a denial-of-service vector.
        public static func follow(max: Int, allowCycles: Bool) -> RedirectConfiguration { return .init(configuration: .follow(max: max, allowCycles: allowCycles)) }
    }
}

private extension ChannelPipeline {
    func addProxyHandler(for request: HTTPClient.Request, decoder: ByteToMessageHandler<HTTPResponseDecoder>, encoder: HTTPRequestEncoder, tlsConfiguration: TLSConfiguration?, proxy: HTTPClient.Configuration.Proxy?) -> EventLoopFuture<Void> {
        let handler = HTTPClientProxyHandler(host: request.host, port: request.port, authorization: proxy?.authorization, onConnect: { channel in
            channel.pipeline.removeHandler(decoder).flatMap {
                return channel.pipeline.addHandler(
                    ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .forwardBytes)),
                    position: .after(encoder)
                )
            }.flatMap {
                return channel.pipeline.addSSLHandlerIfNeeded(for: request, tlsConfiguration: tlsConfiguration)
            }
        })
        return self.addHandler(handler)
    }

    func addSSLHandlerIfNeeded(for request: HTTPClient.Request, tlsConfiguration: TLSConfiguration?) -> EventLoopFuture<Void> {
        guard request.useTLS else {
            return self.eventLoop.makeSucceededFuture(())
        }

        do {
            let tlsConfiguration = tlsConfiguration ?? TLSConfiguration.forClient()
            let context = try NIOSSLContext(configuration: tlsConfiguration)
            return self.addHandler(try NIOSSLClientHandler(context: context, serverHostname: request.host),
                                   position: .first)
        } catch {
            return self.eventLoop.makeFailedFuture(error)
        }
    }
}

/// Possible client errors.
public struct HTTPClientError: Error, Equatable, CustomStringConvertible {
    private enum Code: Equatable {
        case invalidURL
        case emptyHost
        case alreadyShutdown
        case emptyScheme
        case unsupportedScheme(String)
        case readTimeout
        case remoteConnectionClosed
        case cancelled
        case identityCodingIncorrectlyPresent
        case chunkedSpecifiedMultipleTimes
        case invalidProxyResponse
        case contentLengthMissing
        case proxyAuthenticationRequired
        case redirectLimitReached
        case redirectCycleDetected
    }

    private var code: Code

    private init(code: Code) {
        self.code = code
    }

    public var description: String {
        return "HTTPClientError.\(String(describing: self.code))"
    }

    /// URL provided is invalid.
    public static let invalidURL = HTTPClientError(code: .invalidURL)
    /// URL does not contain host.
    public static let emptyHost = HTTPClientError(code: .emptyHost)
    /// Client is shutdown and cannot be used for new requests.
    public static let alreadyShutdown = HTTPClientError(code: .alreadyShutdown)
    /// URL does not contain scheme.
    public static let emptyScheme = HTTPClientError(code: .emptyScheme)
    /// Provided URL scheme is not supported, supported schemes are: `http` and `https`
    public static func unsupportedScheme(_ scheme: String) -> HTTPClientError { return HTTPClientError(code: .unsupportedScheme(scheme)) }
    /// Request timed out.
    public static let readTimeout = HTTPClientError(code: .readTimeout)
    /// Remote connection was closed unexpectedly.
    public static let remoteConnectionClosed = HTTPClientError(code: .remoteConnectionClosed)
    /// Request was cancelled.
    public static let cancelled = HTTPClientError(code: .cancelled)
    /// Request contains invalid identity encoding.
    public static let identityCodingIncorrectlyPresent = HTTPClientError(code: .identityCodingIncorrectlyPresent)
    /// Request contains multiple chunks definitions.
    public static let chunkedSpecifiedMultipleTimes = HTTPClientError(code: .chunkedSpecifiedMultipleTimes)
    /// Proxy response was invalid.
    public static let invalidProxyResponse = HTTPClientError(code: .invalidProxyResponse)
    /// Request does not contain `Content-Length` header.
    public static let contentLengthMissing = HTTPClientError(code: .contentLengthMissing)
    /// Proxy Authentication Required.
    public static let proxyAuthenticationRequired = HTTPClientError(code: .proxyAuthenticationRequired)
    /// Redirect Limit reached.
    public static let redirectLimitReached = HTTPClientError(code: .redirectLimitReached)
    /// Redirect Cycle detected.
    public static let redirectCycleDetected = HTTPClientError(code: .redirectCycleDetected)
}
