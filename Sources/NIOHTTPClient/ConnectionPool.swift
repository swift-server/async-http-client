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
import NIOTLS

class ConnectionPool {
    let eventLoopGroup: EventLoopGroup
    let configuration: HTTPClient.Configuration
    private let lock = Lock()

    init(group: EventLoopGroup, configuration: HTTPClient.Configuration) {
        self.eventLoopGroup = group
        self.configuration = configuration
    }

    private var _connectionProviders: [Key: ConnectionProvider] = [:]
    private subscript(key: Key) -> ConnectionProvider? {
        get {
            return self.lock.withLock {
                _connectionProviders[key]
            }
        }
        set {
            self.lock.withLock {
                _connectionProviders[key] = newValue
            }
        }
    }

    func getConnection(for request: HTTPClient.Request) -> EventLoopFuture<Connection> {
        let key: Key
        do {
            key = try Key(url: request.url)
        } catch {
            return self.eventLoopGroup.next().makeFailedFuture(error)
        }

        // FIXME: See what to do with timeout
        _ = self.configuration.timeout

        if let provider = self[key] {
            return provider.getConnection()
        } else {
            let protocolChoosenPromise = self.eventLoopGroup.next().makePromise(of: ConnectionProvider.self)
            let bootstrap = ClientBootstrap.makeHTTPClientBootstrapBase(group: self.eventLoopGroup, host: request.host, port: request.port, configuration: self.configuration) { _ in
                self.eventLoopGroup.next().makeSucceededFuture(())
            }
            let address = HTTPClient.resolveAddress(host: request.host, port: request.port, proxy: self.configuration.proxy)
            return bootstrap.connect(host: address.host, port: address.port).flatMap { channel in
                let http1PipelineConfigurator: (ChannelPipeline) -> EventLoopFuture<Void> = { pipeline in
                    pipeline.addHTTPClientHandlers(leftOverBytesStrategy: .forwardBytes).map { _ in
                        let http1Provider = ConnectionProvider.http1(HTTP1ConnectionProvider(group: self.eventLoopGroup, key: key, configuration: self.configuration, initialConnection: Connection(key: key, channel: channel)))
                        self[key] = http1Provider
                        http1Provider.closeFuture.whenSuccess {
                            self[key] = nil
                        }
                        protocolChoosenPromise.succeed(http1Provider)
                    }
                }

                let h2PipelineConfigurator: (ChannelPipeline) -> EventLoopFuture<Void> = { _ in
                    channel.configureHTTP2Pipeline(mode: .client).map { multiplexer in
                        let http2Provider = ConnectionProvider.http2(HTTP2ConnectionProvider(group: self.eventLoopGroup, key: key, configuration: self.configuration, channel: channel, multiplexer: multiplexer))
                        self[key] = http2Provider
                        http2Provider.closeFuture.whenSuccess {
                            self[key] = nil
                        }
                        protocolChoosenPromise.succeed(http2Provider)
                    }
                }

                if request.useTLS {
                    _ = channel.pipeline.addSSLHandlerIfNeeded(for: request, tlsConfiguration: self.configuration.tlsConfiguration).flatMap { _ in
                        channel.pipeline.configureHTTP2SecureUpgrade(h2PipelineConfigurator: h2PipelineConfigurator, http1PipelineConfigurator: http1PipelineConfigurator)
                    }
                } else {
                    _ = http1PipelineConfigurator(channel.pipeline)
                }

                return protocolChoosenPromise.futureResult.flatMap { provider in
                    provider.getConnection()
                }
            }
        }
    }

    func release(_ connection: Connection) {
        if let provider = self[connection.key] {
            provider.release(connection: connection)
        } else {
            // FIXME: Is this acceptable to discard this ELF?
            _ = connection.channel.close()
        }
    }

    func closeAllConnections() -> EventLoopFuture<Void> {
        return self.lock.withLock {
            let closeFutures = _connectionProviders.values.map { $0.closeAllConnections() }
            return EventLoopFuture<Void>.andAllSucceed(closeFutures, on: eventLoopGroup.next())
        }
    }

    fileprivate struct Key: Hashable {
        init(url: URL) throws {
            switch url.scheme {
            case "http":
                self.scheme = .http
            case "https":
                self.scheme = .https
            default:
                if let scheme = url.scheme {
                    throw HTTPClientError.unsupportedScheme(scheme)
                } else {
                    throw HTTPClientError.emptyScheme
                }
            }

            switch url.port {
            case .some(let specifiedPort):
                self.port = specifiedPort
            case .none:
                switch self.scheme {
                case .http:
                    self.port = 80
                case .https:
                    self.port = 443
                }
            }

            guard let host = url.host else {
                throw HTTPClientError.emptyHost
            }
            self.host = host
        }

        var scheme: Scheme
        var host: String
        var port: Int

        enum Scheme: Hashable {
            case http
            case https
        }
    }

    class Connection {
        fileprivate init(key: Key, channel: Channel) {
            self.key = key
            self.channel = channel
        }

        fileprivate let key: Key
        let channel: Channel
    }

    private enum ConnectionProvider {
        case http1(HTTP1ConnectionProvider)
        case http2(HTTP2ConnectionProvider)

        func getConnection() -> EventLoopFuture<Connection> {
            switch self {
            case .http1(let provider):
                return provider.getConnection()
            case .http2(let provider):
                return provider.getConnection()
            }
        }

        func release(connection: Connection) {
            switch self {
            case .http1(let provider):
                return provider.release(connection: connection)
            case .http2(let provider):
                return provider.release(connection: connection)
            }
        }

        func closeAllConnections() -> EventLoopFuture<Void> {
            switch self {
            case .http1(let provider):
                return provider.closeAllConnections()
            case .http2(let provider):
                return provider.closeAllConnections()
            }
        }

        var closeFuture: EventLoopFuture<Void> {
            switch self {
            case .http1(let provider):
                return provider.closeFuture
            case .http2(let provider):
                return provider.closeFuture
            }
        }
    }

    private class HTTP1ConnectionProvider {
        init(group: EventLoopGroup, key: ConnectionPool.Key, configuration: HTTPClient.Configuration, initialConnection: Connection) {
            self.loopGroup = group
            self.configuration = configuration
            self.key = key
            self.closePromise = group.next().makePromise(of: Void.self)
            self.configureConnectionEvents(initialConnection)
            self.availableConnections.append(initialConnection)
        }

        deinit {
            assert(availableConnections.isEmpty, "Available connections should be empty before deinit")
            assert(leased == 0, "All leased connections should have been returned before deinit")
        }

        let loopGroup: EventLoopGroup
        let configuration: HTTPClient.Configuration
        let key: ConnectionPool.Key

        /// The curently opened, unleased connections in this connection provider
        var availableConnections: CircularBuffer<Connection> = .init(initialCapacity: 8) {
            didSet {
                self.closeIfNeeded()
            }
        }

        /// Consumers that weren't able to get a new connection without exceeding
        /// `maximumConcurrentConnections` get a `Future<Connection>` that is
        /// completed as soon as possible, in FIFO order.
        var waiters: CircularBuffer<EventLoopPromise<Connection>> = .init()

        var leased: Int = 0 {
            didSet {
                self.closeIfNeeded()
            }
        }

        let maximumConcurrentConnections: Int = 8

        /// This future is completed when the connection pool has no more
        /// opened connections
        var closeFuture: EventLoopFuture<Void> {
            return self.closePromise.futureResult
        }

        let closePromise: EventLoopPromise<Void>

        let lock = Lock()

        /// Get a new connection from this provider
        func getConnection() -> EventLoopFuture<Connection> {
            return self.lock.withLock {
                if leased < maximumConcurrentConnections {
                    leased += 1
                    if let connection = availableConnections.popFirst() {
                        return self.loopGroup.next().makeSucceededFuture(connection)
                    } else {
                        return self.makeConnection()
                    }
                } else {
                    let promise = self.loopGroup.next().makePromise(of: Connection.self)
                    self.waiters.append(promise)
                    return promise.futureResult
                }
            }
        }

        private func makeConnection() -> EventLoopFuture<Connection> {
            let bootstrap = ClientBootstrap.makeHTTPClientBootstrapBase(group: self.loopGroup, host: self.key.host, port: self.key.port, configuration: self.configuration) { channel in
                channel.pipeline.addHTTPClientHandlers(leftOverBytesStrategy: .forwardBytes)
            }
            let address = HTTPClient.resolveAddress(host: self.key.host, port: self.key.port, proxy: self.configuration.proxy)
            return bootstrap.connect(host: address.host, port: address.port).map { channel in
                let connection = Connection(key: self.key, channel: channel)
                self.configureConnectionEvents(connection)
                return connection
            }
        }

        func release(connection: Connection) {
            self.lock.withLock {
                if connection.channel.isActive {
                    if let firstWaiter = waiters.popFirst() {
                        firstWaiter.succeed(connection)
                    } else {
                        leased -= 1
                        self.availableConnections.append(connection)
                    }
                } else {
                    leased -= 1
                }
            }
        }

        func closeAllConnections() -> EventLoopFuture<Void> {
            return self.lock.withLock {
                let closeFutures = availableConnections.map { $0.channel.close() }
                return EventLoopFuture<Void>.andAllSucceed(closeFutures, on: loopGroup.next())
            }
        }

        private func configureConnectionEvents(_ connection: Connection) {
            connection.channel.closeFuture.whenSuccess {
                self.lock.withLock {
                    if let index = self.availableConnections.firstIndex(where: { ObjectIdentifier($0) == ObjectIdentifier(connection) }) {
                        self.availableConnections.remove(at: index)
                    }
                }
            }
        }

        private func closeIfNeeded() {
            if self.leased == 0, self.availableConnections.isEmpty {
                for waiter in self.waiters {
                    waiter.fail(HTTPClientError.remoteConnectionClosed)
                }
                self.closePromise.succeed(())
            }
        }
    }

    private class HTTP2ConnectionProvider {
        init(group: EventLoopGroup, key: Key, configuration: HTTPClient.Configuration, channel: Channel, multiplexer: HTTP2StreamMultiplexer) {
            self.loopGroup = group
            self.key = key
            self.configuration = configuration
            self.multiplexer = multiplexer
            self.channel = channel
        }

        let loopGroup: EventLoopGroup
        let key: Key
        let multiplexer: HTTP2StreamMultiplexer
        let channel: Channel
        let configuration: HTTPClient.Configuration
        let lock = Lock()
        var closeFuture: EventLoopFuture<Void> {
            return self.channel.closeFuture
        }

        func getConnection() -> EventLoopFuture<Connection> {
            return self.lock.withLock {
                let promise = self.loopGroup.next().makePromise(of: Channel.self)
                self.multiplexer.createStreamChannel(promise: promise) { channel, streamID in
                    channel.pipeline.addHandler(HTTP2ToHTTP1ClientCodec(streamID: streamID, httpProtocol: .https))
                }
                return promise.futureResult.map { channel in
                    Connection(key: self.key, channel: channel)
                }
            }
        }

        func release(connection: Connection) {
            _ = connection.channel.close()
        }

        func closeAllConnections() -> EventLoopFuture<Void> {
            return self.lock.withLock {
                // FIXME: Is this correct regarding the child channels?
                channel.close()
            }
        }
    }
}
