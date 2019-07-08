//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2018-2019 Swift Server Working Group and the AsyncHTTPClient project authors
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

/// HTTPClient class provides API for request execution.
///
/// Example:
///
/// ```swift
///     let client = HTTPClient(eventLoopGroupProvider = .createNew)
///     client.get(url: "https://swift.org", deadline: .now() + .seconds(1)).whenComplete { result in
///         switch result {
///         case .failure(let error):
///         // process error
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

    /// Create an HTTPClient with specified `EventLoopGroup` provider and configuration.
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
        switch self.eventLoopGroupProvider {
        case .shared:
            return
        case .createNew:
            assert(self.isShutdown.load(), "Client not stopped before the deinit.")
        }
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

    /// Execute GET request using specified URL.
    ///
    /// - parameters:
    ///     - url: Remote URL.
    ///     - deadline: The time when the request must have been completed by.
    public func get(url: String, deadline: NIODeadline? = nil) -> EventLoopFuture<Response> {
        do {
            let request = try Request(url: url, method: .GET)
            return self.execute(request: request, deadline: deadline)
        } catch {
            return self.eventLoopGroup.next().makeFailedFuture(error)
        }
    }

    /// Execute POST request using specified URL.
    ///
    /// - parameters:
    ///     - url: Remote URL.
    ///     - body: Request body.
    ///     - deadline: The time when the request must have been completed by.
    public func post(url: String, body: Body? = nil, deadline: NIODeadline? = nil) -> EventLoopFuture<Response> {
        do {
            let request = try HTTPClient.Request(url: url, method: .POST, body: body)
            return self.execute(request: request, deadline: deadline)
        } catch {
            return self.eventLoopGroup.next().makeFailedFuture(error)
        }
    }

    /// Execute PATCH request using specified URL.
    ///
    /// - parameters:
    ///     - url: Remote URL.
    ///     - body: Request body.
    ///     - deadline: The time when the request must have been completed by.
    public func patch(url: String, body: Body? = nil, deadline: NIODeadline? = nil) -> EventLoopFuture<Response> {
        do {
            let request = try HTTPClient.Request(url: url, method: .PATCH, body: body)
            return self.execute(request: request, deadline: deadline)
        } catch {
            return self.eventLoopGroup.next().makeFailedFuture(error)
        }
    }

    /// Execute PUT request using specified URL.
    ///
    /// - parameters:
    ///     - url: Remote URL.
    ///     - body: Request body.
    ///     - deadline: The time when the request must have been completed by.
    public func put(url: String, body: Body? = nil, deadline: NIODeadline? = nil) -> EventLoopFuture<Response> {
        do {
            let request = try HTTPClient.Request(url: url, method: .PUT, body: body)
            return self.execute(request: request, deadline: deadline)
        } catch {
            return self.eventLoopGroup.next().makeFailedFuture(error)
        }
    }

    /// Execute DELETE request using specified URL.
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
    ///     - deadline: The time when the request must have been completed by
    public func execute(request: Request, deadline: NIODeadline? = nil) -> EventLoopFuture<Response> {
        let accumulator = ResponseAccumulator(request: request)
        return self.execute(request: request, delegate: accumulator, deadline: deadline).futureResult
    }

    /// Execute arbitrary HTTP request and handle response processing using provided delegate.
    ///
    /// - parameters:
    ///     - request: HTTP request to execute.
    ///     - delegate: Delegate to process response parts.
    ///     - deadline: The time when the request must have been completed by.
    public func execute<T: HTTPClientResponseDelegate>(request: Request, delegate: T, deadline: NIODeadline? = nil) -> Task<T.Response> {
        let eventLoop = self.eventLoopGroup.next()

        let redirectHandler: RedirectHandler<T.Response>?
        if self.configuration.followRedirects {
            redirectHandler = RedirectHandler<T.Response>(request: request) { newRequest in
                self.execute(request: newRequest, delegate: delegate, deadline: deadline)
            }
        } else {
            redirectHandler = nil
        }

        let task = Task<T.Response>(eventLoop: eventLoop)

        var bootstrap = ClientBootstrap(group: eventLoop)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
            .channelInitializer { channel in
                let encoder = HTTPRequestEncoder()
                let decoder = ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .forwardBytes))
                return channel.pipeline.addHandlers([encoder, decoder], position: .first).flatMap {
                    switch self.configuration.proxy {
                    case .none:
                        return channel.pipeline.addSSLHandlerIfNeeded(for: request, tlsConfiguration: self.configuration.tlsConfiguration)
                    case .some:
                        return channel.pipeline.addProxyHandler(for: request, decoder: decoder, encoder: encoder, tlsConfiguration: self.configuration.tlsConfiguration)
                    }
                }.flatMap {
                    if let timeout = self.resolve(timeout: self.configuration.timeout.read, deadline: deadline) {
                        return channel.pipeline.addHandler(IdleStateHandler(readTimeout: timeout))
                    } else {
                        return channel.eventLoop.makeSucceededFuture(())
                    }
                }.flatMap {
                    let taskHandler = TaskHandler(task: task, delegate: delegate, redirectHandler: redirectHandler)
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
            .whenFailure { error in
                task.fail(error)
            }

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

    private func resolveAddress(request: Request, proxy: Proxy?) -> (host: String, port: Int) {
        switch self.configuration.proxy {
        case .none:
            return (request.host, request.port)
        case .some(let proxy):
            return (proxy.host, proxy.port)
        }
    }

    /// HTTPClient configuration.
    public struct Configuration {
        /// TLS configuration, defaults to `TLSConfiguration.forClient()`.
        public var tlsConfiguration: TLSConfiguration?
        /// Enables following certain 3xx redirects automatically, defaults to `false`.
        public var followRedirects: Bool
        /// Default client timeout, defaults to no timeouts.
        public var timeout: Timeout
        /// Upstream proxy, defaults to no proxy.
        public var proxy: Proxy?

        public init(tlsConfiguration: TLSConfiguration? = nil, followRedirects: Bool = false, timeout: Timeout = Timeout(), proxy: Proxy? = nil) {
            self.tlsConfiguration = tlsConfiguration
            self.followRedirects = followRedirects
            self.timeout = timeout
            self.proxy = proxy
        }

        public init(certificateVerification: CertificateVerification, followRedirects: Bool = false, timeout: Timeout = Timeout(), proxy: Proxy? = nil) {
            self.tlsConfiguration = TLSConfiguration.forClient(certificateVerification: certificateVerification)
            self.followRedirects = followRedirects
            self.timeout = timeout
            self.proxy = proxy
        }
    }

    /// Specifies how `EventLoopGroup` will be created and establishes lifecycle ownership.
    public enum EventLoopGroupProvider {
        /// `EventLoopGroup` will be provided by the user. Owner of this group is responsible for it's lifecycle.
        case shared(EventLoopGroup)
        /// `EventLoopGroup` will be created by the client. When `syncShutdown` is called, created `EventLoopGroup` will be shut down as well.
        case createNew
    }

    /// Timeout configuration
    public struct Timeout {
        /// Specifies `connect` timeout.
        public var connect: TimeAmount?
        /// Specifies `read` timeout.
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
}

private extension ChannelPipeline {
    func addProxyHandler(for request: HTTPClient.Request, decoder: ByteToMessageHandler<HTTPResponseDecoder>, encoder: HTTPRequestEncoder, tlsConfiguration: TLSConfiguration?) -> EventLoopFuture<Void> {
        let handler = HTTPClientProxyHandler(host: request.host, port: request.port, onConnect: { channel in
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
}
