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
import NIOHTTP2
import NIOSSL

public enum EventLoopGroupProvider {
    case shared(EventLoopGroup)
    case createNew
}

public class HTTPClient {
    public let eventLoopGroup: EventLoopGroup
    let eventLoopGroupProvider: EventLoopGroupProvider
    let configuration: Configuration
    let pool: ConnectionPool
    let isShutdown = Atomic<Bool>(value: false)

    public init(eventLoopGroupProvider: EventLoopGroupProvider, configuration: Configuration = Configuration()) {
        self.eventLoopGroupProvider = eventLoopGroupProvider
        switch self.eventLoopGroupProvider {
        case .shared(let group):
            self.eventLoopGroup = group
        case .createNew:
            self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        }
        self.configuration = configuration
        self.pool = ConnectionPool(group: self.eventLoopGroup, configuration: configuration)
    }

    deinit {
        assert(self.isShutdown.load(), "Client not stopped before the deinit.")
    }

    public func syncShutdown() throws {
        try self.pool.closeAllConnections().wait()
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

    public func get(url: String, timeout: Timeout? = nil) -> EventLoopFuture<Response> {
        do {
            let request = try Request(url: url, method: .GET)
            return self.execute(request: request)
        } catch {
            return self.eventLoopGroup.next().makeFailedFuture(error)
        }
    }

    public func post(url: String, body: Body? = nil, timeout: Timeout? = nil) -> EventLoopFuture<Response> {
        do {
            let request = try HTTPClient.Request(url: url, method: .POST, body: body)
            return self.execute(request: request)
        } catch {
            return self.eventLoopGroup.next().makeFailedFuture(error)
        }
    }

    public func patch(url: String, body: Body? = nil, timeout: Timeout? = nil) -> EventLoopFuture<Response> {
        do {
            let request = try HTTPClient.Request(url: url, method: .PATCH, body: body)
            return self.execute(request: request)
        } catch {
            return self.eventLoopGroup.next().makeFailedFuture(error)
        }
    }

    public func put(url: String, body: Body? = nil, timeout: Timeout? = nil) -> EventLoopFuture<Response> {
        do {
            let request = try HTTPClient.Request(url: url, method: .PUT, body: body)
            return self.execute(request: request)
        } catch {
            return self.eventLoopGroup.next().makeFailedFuture(error)
        }
    }

    public func delete(url: String, timeout: Timeout? = nil) -> EventLoopFuture<Response> {
        do {
            let request = try Request(url: url, method: .DELETE)
            return self.execute(request: request)
        } catch {
            return self.eventLoopGroup.next().makeFailedFuture(error)
        }
    }

    public func execute(request: Request, timeout: Timeout? = nil) -> EventLoopFuture<Response> {
        let accumulator = ResponseAccumulator(request: request)
        return self.execute(request: request, delegate: accumulator, timeout: timeout).future
    }

    public func execute<T: HTTPClientResponseDelegate>(request: Request, delegate: T, timeout: Timeout? = nil) -> Task<T.Response> {
        let timeout = timeout ?? configuration.timeout
        let promise: EventLoopPromise<T.Response> = self.eventLoopGroup.next().makePromise()

        let redirectHandler: RedirectHandler<T.Response>?
        if self.configuration.followRedirects {
            redirectHandler = RedirectHandler<T.Response>(request: request) { newRequest in
                self.execute(request: newRequest, delegate: delegate, timeout: timeout)
            }
        } else {
            redirectHandler = nil
        }

        let task = Task(future: promise.futureResult)

        let connection = self.pool.getConnection(for: request)

        connection.flatMap { connection -> EventLoopFuture<()> in
            task.future.whenComplete { _ in
                let removeResult = connection.channel.pipeline.removeHandler(name: "taskHandler")
                removeResult.whenComplete { result in
                    switch result {
                    case .success:
                        self.pool.release(connection)
                    case .failure(let error):
                        fatalError("Task handler removal shouldn't fail (error: \(error)")
                    }
                }
            }

            let channel = connection.channel
            let addedFuture: EventLoopFuture<Void>
            if let readTimeout = timeout.read {
                addedFuture = channel.pipeline.addHandler(IdleStateHandler(readTimeout: readTimeout))
            } else {
                addedFuture = channel.eventLoop.makeSucceededFuture(())
            }
            return addedFuture.flatMap {
                let taskHandler = TaskHandler(task: task, delegate: delegate, promise: promise, redirectHandler: redirectHandler)
                task.setChannel(channel)
                return channel.pipeline.addHandler(taskHandler, name: "taskHandler")
            }.flatMap {
                channel.writeAndFlush(request)
            }
        }.whenFailure { error in
            promise.fail(error)
        }

        return task
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

    static func resolveAddress(host: String, port: Int, proxy: HTTPClient.Proxy?) -> (host: String, port: Int) {
        switch proxy {
        case .none:
            return (host, port)
        case .some(let proxy):
            return (proxy.host, proxy.port)
        }
    }
}

extension HTTPRequestEncoder: RemovableChannelHandler {}

extension ChannelPipeline {
    func addProxyHandler(host: String, port: Int) -> EventLoopFuture<Void> {
        let encoder = HTTPRequestEncoder()
        let decoder = ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .forwardBytes))
        let handler = HTTPClientProxyHandler(host: host, port: port) { channel in
            let encoderRemovePromise = self.eventLoop.next().makePromise(of: Void.self)
            channel.pipeline.removeHandler(encoder, promise: encoderRemovePromise)
            return encoderRemovePromise.futureResult.flatMap {
                channel.pipeline.removeHandler(decoder)
            }
        }
        return addHandlers([encoder, decoder, handler])
    }

    func addSSLHandlerIfNeeded(for request: HTTPClient.Request, tlsConfiguration: TLSConfiguration?) -> EventLoopFuture<Void> {
        guard request.useTLS else {
            return self.eventLoop.makeSucceededFuture(())
        }

        do {
            let tlsConfiguration = tlsConfiguration ?? TLSConfiguration.forClient(applicationProtocols: NIOHTTP2SupportedALPNProtocols)
            let context = try NIOSSLContext(configuration: tlsConfiguration)
            return self.addHandler(try NIOSSLClientHandler(context: context, serverHostname: request.host))
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
