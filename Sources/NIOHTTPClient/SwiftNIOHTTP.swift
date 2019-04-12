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

public struct Timeout {
    public var connect: TimeAmount?
    public var read: TimeAmount?

    public init(connectTimeout: TimeAmount? = nil, readTimeout: TimeAmount? = nil) {
        self.connect = connectTimeout
        self.read = readTimeout
    }
}

public struct HTTPClientConfiguration {
    public var tlsConfiguration: TLSConfiguration?
    public var followRedirects: Bool
    public var timeout: Timeout
    public var proxy: HTTPClientProxy?

    public init(tlsConfiguration: TLSConfiguration? = nil, followRedirects: Bool = false, timeout: Timeout = Timeout(), proxy: HTTPClientProxy? = nil) {
        self.tlsConfiguration = tlsConfiguration
        self.followRedirects = followRedirects
        self.timeout = timeout
        self.proxy = proxy
    }

    public init(certificateVerification: CertificateVerification, followRedirects: Bool = false, timeout: Timeout = Timeout(), proxy: HTTPClientProxy? = nil) {
        self.tlsConfiguration = TLSConfiguration.forClient(certificateVerification: certificateVerification)
        self.followRedirects = followRedirects
        self.timeout = timeout
        self.proxy = proxy
    }
}

public class HTTPClient {
    let eventLoopGroupProvider: EventLoopGroupProvider
    let group: EventLoopGroup
    let configuration: HTTPClientConfiguration

    let isShutdown = Atomic<Bool>(value: false)

    public init(eventLoopGroupProvider: EventLoopGroupProvider, configuration: HTTPClientConfiguration = HTTPClientConfiguration()) {
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
                throw HTTPClientErrors.AlreadyShutdown()
            }
        }
    }

    public func get(url: String, timeout: Timeout? = nil) -> EventLoopFuture<HTTPResponse> {
        do {
            let request = try HTTPRequest(url: url, method: .GET)
            return self.execute(request: request)
        } catch {
            return self.group.next().makeFailedFuture(error)
        }
    }

    public func post(url: String, body: HTTPBody? = nil, timeout: Timeout? = nil) -> EventLoopFuture<HTTPResponse> {
        do {
            let request = try HTTPRequest(url: url, method: .POST, body: body)
            return self.execute(request: request)
        } catch {
            return self.group.next().makeFailedFuture(error)
        }
    }

    public func put(url: String, body: HTTPBody? = nil, timeout: Timeout? = nil) -> EventLoopFuture<HTTPResponse> {
        do {
            let request = try HTTPRequest(url: url, method: .PUT, body: body)
            return self.execute(request: request)
        } catch {
            return self.group.next().makeFailedFuture(error)
        }
    }

    public func delete(url: String, timeout: Timeout? = nil) -> EventLoopFuture<HTTPResponse> {
        do {
            let request = try HTTPRequest(url: url, method: .DELETE)
            return self.execute(request: request)
        } catch {
            return self.group.next().makeFailedFuture(error)
        }
    }

    public func execute(request: HTTPRequest, timeout: Timeout? = nil) -> EventLoopFuture<HTTPResponse> {
        let accumulator = HTTPResponseAccumulator(request: request)
        return self.execute(request: request, delegate: accumulator, timeout: timeout).future
    }

    public func execute<T: HTTPResponseDelegate>(request: HTTPRequest, delegate: T, timeout: Timeout? = nil) -> HTTPTask<T.Response> {
        let timeout = timeout ?? configuration.timeout

        let promise: EventLoopPromise<T.Response> = group.next().makePromise()

        let redirectHandler: RedirectHandler<T.Response>?
        if self.configuration.followRedirects {
            redirectHandler = RedirectHandler<T.Response>(request: request) { newRequest in
                self.execute(request: newRequest, delegate: delegate, timeout: timeout)
            }
        } else {
            redirectHandler = nil
        }

        let task = HTTPTask(future: promise.futureResult)

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
                    let taskHandler = HTTPTaskHandler(task: task, delegate: delegate, promise: promise, redirectHandler: redirectHandler)
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

    private func resolveAddress(request: HTTPRequest, proxy: HTTPClientProxy?) -> (host: String, port: Int)  {
        switch self.configuration.proxy {
        case .none:
            return (request.host, request.port)
        case .some(let proxy):
            return (proxy.host, proxy.port)
        }
    }
}

private extension ChannelPipeline {
    func addProxyHandler(for request: HTTPRequest, decoder: ByteToMessageHandler<HTTPResponseDecoder>, encoder: HTTPRequestEncoder, tlsConfiguration: TLSConfiguration?) -> EventLoopFuture<Void> {
        let handler = HTTPClientProxyHandler(host: request.host, port: request.port, onConnect: { channel in
            return channel.pipeline.removeHandler(decoder).flatMap {
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

    func addSSLHandlerIfNeeded(for request: HTTPRequest, tlsConfiguration: TLSConfiguration?) -> EventLoopFuture<Void> {
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
