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

        let promise: EventLoopPromise<T.Response> = group.next().makePromise()

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
            channel.pipeline.addHTTPClientHandlers().flatMap {
                self.configureSSL(channel: channel, useTLS: request.useTLS, hostname: request.host)
            }.flatMap {
                if let readTimeout = timeout.read {
                    return channel.pipeline.addHandler(IdleStateHandler(readTimeout: readTimeout))
                } else {
                    return channel.eventLoop.makeSucceededFuture(())
                }
            }.flatMap {
                channel.pipeline.addHandler(TaskHandler(task: task, delegate: delegate, promise: promise, redirectHandler: redirectHandler))
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

    public struct Configuration {
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

    public struct Timeout {
        public var connect: TimeAmount?
        public var read: TimeAmount?

        public init(connect: TimeAmount? = nil, read: TimeAmount? = nil) {
            self.connect = connect
            self.read = read
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
    }

    private var code: Code

    private init(code: Code) {
        self.code = code
    }

    public var description: String {
        return "SandwichError.\(String(describing: self.code))"
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
}
