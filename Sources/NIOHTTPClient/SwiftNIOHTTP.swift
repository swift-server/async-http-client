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

    public init(tlsConfiguration: TLSConfiguration? = nil, followRedirects: Bool = false, timeout: Timeout = Timeout()) {
        self.tlsConfiguration = tlsConfiguration
        self.followRedirects = followRedirects
        self.timeout = timeout
    }

    public init(certificateVerification: CertificateVerification, followRedirects: Bool = false, timeout: Timeout = Timeout()) {
        self.tlsConfiguration = TLSConfiguration.forClient(certificateVerification: certificateVerification)
        self.followRedirects = followRedirects
        self.timeout = timeout
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
            channel.pipeline.addHTTPClientHandlers().flatMap {
                self.configureSSL(channel: channel, useTLS: request.useTLS, hostname: request.host)
            }.flatMap {
                if let readTimeout = timeout.read {
                    return channel.pipeline.addHandler(IdleStateHandler(readTimeout: readTimeout))
                } else {
                    return channel.eventLoop.makeSucceededFuture(())
                }
            }.flatMap {
                channel.pipeline.addHandler(HTTPTaskHandler(task: task, delegate: delegate, promise: promise, redirectHandler: redirectHandler))
            }
        }

        if let connectTimeout = timeout.connect {
            bootstrap = bootstrap.connectTimeout(connectTimeout)
        }

        bootstrap.connect(host: request.host, port: request.port)
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

    private func configureSSL(channel: Channel, useTLS: Bool, hostname: String) -> EventLoopFuture<Void> {
        if useTLS {
            do {
                let tlsConfiguration = self.configuration.tlsConfiguration ?? TLSConfiguration.forClient()
                let context = try NIOSSLContext(configuration: tlsConfiguration)
                return channel.pipeline.addHandler(try NIOSSLClientHandler(context: context, serverHostname: hostname),
                                                   position: .first)
            } catch {
                return channel.eventLoop.makeFailedFuture(error)
            }
        } else {
            return channel.eventLoop.makeSucceededFuture(())
        }
    }
}
