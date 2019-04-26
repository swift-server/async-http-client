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

public enum EventLoopGroupProvider {
    case shared(EventLoopGroup)
    case createNew
}

public class HTTPClient {
    let eventLoopGroupProvider: EventLoopGroupProvider
    let group: EventLoopGroup
    let configuration: Configuration

    let isShutdown = Atomic<Bool>(value: false)

    public init(eventLoopGroupProvider: EventLoopGroupProvider, configuration: Configuration = Configuration()) {
        self.eventLoopGroupProvider = eventLoopGroupProvider
        switch self.eventLoopGroupProvider {
        case .shared(let group):
            self.group = group
        case .createNew:
            self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
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

    public func syncShutdown() throws {
        switch self.eventLoopGroupProvider {
        case .shared:
            self.isShutdown.store(true)
            return
        case .createNew:
            if self.isShutdown.compareAndExchange(expected: false, desired: true) {
                try self.group.syncShutdownGracefully()
            } else {
                throw HTTPClientError.alreadyShutdown
            }
        }
    }

    public func get(url: String, timeout: Timeout? = nil) -> EventLoopFuture<Response> {
        do {
            let request = try Request(url: url, method: .GET)
            return self.execute(request: request)
        } catch {
            return self.group.next().makeFailedFuture(error)
        }
    }

    public func post(url: String, body: Body? = nil, timeout: Timeout? = nil) -> EventLoopFuture<Response> {
        do {
            let request = try HTTPClient.Request(url: url, method: .POST, body: body)
            return self.execute(request: request)
        } catch {
            return self.group.next().makeFailedFuture(error)
        }
    }

    public func patch(url: String, body: Body? = nil, timeout: Timeout? = nil) -> EventLoopFuture<Response> {
        do {
            let request = try HTTPClient.Request(url: url, method: .PATCH, body: body)
            return self.execute(request: request)
        } catch {
            return self.group.next().makeFailedFuture(error)
        }
    }

    public func put(url: String, body: Body? = nil, timeout: Timeout? = nil) -> EventLoopFuture<Response> {
        do {
            let request = try HTTPClient.Request(url: url, method: .PUT, body: body)
            return self.execute(request: request)
        } catch {
            return self.group.next().makeFailedFuture(error)
        }
    }

    public func delete(url: String, timeout: Timeout? = nil) -> EventLoopFuture<Response> {
        do {
            let request = try Request(url: url, method: .DELETE)
            return self.execute(request: request)
        } catch {
            return self.group.next().makeFailedFuture(error)
        }
    }

    public func execute(request: Request, timeout: Timeout? = nil) -> EventLoopFuture<Response> {
        let accumulator = ResponseAccumulator(request: request)
        return self.execute(request: request, delegate: accumulator, timeout: timeout).future
    }

    public func execute<T: HTTPClientResponseDelegate>(request: Request, delegate: T, timeout: Timeout? = nil) -> Task<T.Response> {
        let timeout = timeout ?? configuration.timeout

        let promise: EventLoopPromise<T.Response> = self.group.next().makePromise()

        let redirectHandler: RedirectHandler<T.Response>?
        if self.configuration.followRedirects {
            redirectHandler = RedirectHandler<T.Response>(request: request) { newRequest in
                self.execute(request: newRequest, delegate: delegate, timeout: timeout)
            }
        } else {
            redirectHandler = nil
        }

        let task = Task(future: promise.futureResult)

        var bootstrap = ClientBootstrap(group: group)
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
                    if let readTimeout = timeout.read {
                        return channel.pipeline.addHandler(IdleStateHandler(readTimeout: readTimeout))
                    } else {
                        return channel.eventLoop.makeSucceededFuture(())
                    }
                }.flatMap {
                    let taskHandler = TaskHandler(task: task, delegate: delegate, promise: promise, redirectHandler: redirectHandler)
                    return channel.pipeline.addHandler(taskHandler)
                }
            }

        if let connectTimeout = timeout.connect {
            bootstrap = bootstrap.connectTimeout(connectTimeout)
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
                promise.fail(error)
            }

        return task
    }

    private func resolveAddress(request: Request, proxy: Proxy?) -> (host: String, port: Int) {
        switch self.configuration.proxy {
        case .none:
            return (request.host, request.port)
        case .some(let proxy):
            return (proxy.host, proxy.port)
        }
    }

    public struct Configuration {
        public var tlsConfiguration: TLSConfiguration?
        public var followRedirects: Bool
        public var timeout: Timeout
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

    public struct Timeout {
        public var connect: TimeAmount?
        public var read: TimeAmount?

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
    }

    private var code: Code

    private init(code: Code) {
        self.code = code
    }

    public var description: String {
        return "HTTPClientError.\(String(describing: self.code))"
    }

    public static let invalidURL = HTTPClientError(code: .invalidURL)
    public static let emptyHost = HTTPClientError(code: .emptyHost)
    public static let alreadyShutdown = HTTPClientError(code: .alreadyShutdown)
    public static let emptyScheme = HTTPClientError(code: .emptyScheme)
    public static func unsupportedScheme(_ scheme: String) -> HTTPClientError { return HTTPClientError(code: .unsupportedScheme(scheme)) }
    public static let readTimeout = HTTPClientError(code: .readTimeout)
    public static let remoteConnectionClosed = HTTPClientError(code: .remoteConnectionClosed)
    public static let cancelled = HTTPClientError(code: .cancelled)
    public static let identityCodingIncorrectlyPresent = HTTPClientError(code: .identityCodingIncorrectlyPresent)
    public static let chunkedSpecifiedMultipleTimes = HTTPClientError(code: .chunkedSpecifiedMultipleTimes)
    public static let invalidProxyResponse = HTTPClientError(code: .invalidProxyResponse)
}
