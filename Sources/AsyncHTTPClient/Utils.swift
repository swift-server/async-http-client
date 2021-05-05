//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2018-2020 Apple Inc. and the AsyncHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation
#if canImport(Network)
    import Network
#endif
import NIO
import NIOHTTP1
import NIOHTTPCompression
import NIOSSL
import NIOTransportServices

internal extension String {
    var isIPAddress: Bool {
        var ipv4Addr = in_addr()
        var ipv6Addr = in6_addr()

        return self.withCString { ptr in
            inet_pton(AF_INET, ptr, &ipv4Addr) == 1 ||
                inet_pton(AF_INET6, ptr, &ipv6Addr) == 1
        }
    }
}

public final class HTTPClientCopyingDelegate: HTTPClientResponseDelegate {
    public typealias Response = Void

    let chunkHandler: (ByteBuffer) -> EventLoopFuture<Void>

    public init(chunkHandler: @escaping (ByteBuffer) -> EventLoopFuture<Void>) {
        self.chunkHandler = chunkHandler
    }

    public func didReceiveBodyPart(task: HTTPClient.Task<Void>, _ buffer: ByteBuffer) -> EventLoopFuture<Void> {
        return self.chunkHandler(buffer)
    }

    public func didFinishRequest(task: HTTPClient.Task<Void>) throws {
        return ()
    }
}

extension ClientBootstrap {
    fileprivate func makeClientTCPBootstrap(
        host: String,
        requiresTLS: Bool,
        configuration: HTTPClient.Configuration
    ) throws -> NIOClientTCPBootstrap {
        // if there is a proxy don't create TLS provider as it will be added at a later point
        if configuration.proxy != nil {
            return NIOClientTCPBootstrap(self, tls: NIOInsecureNoTLS())
        } else {
            let tlsConfiguration = configuration.tlsConfiguration ?? TLSConfiguration.forClient()
            let sslContext = try NIOSSLContext(configuration: tlsConfiguration)
            let hostname = (!requiresTLS || host.isIPAddress || host.isEmpty) ? nil : host
            let tlsProvider = try NIOSSLClientTLSProvider<ClientBootstrap>(context: sslContext, serverHostname: hostname)
            return NIOClientTCPBootstrap(self, tls: tlsProvider)
        }
    }
}

extension NIOClientTCPBootstrap {
    /// create a TCP Bootstrap based off what type of `EventLoop` has been passed to the function.
    fileprivate static func makeBootstrap(
        on eventLoop: EventLoop,
        host: String,
        requiresTLS: Bool,
        configuration: HTTPClient.Configuration
    ) throws -> NIOClientTCPBootstrap {
        var bootstrap: NIOClientTCPBootstrap
        #if canImport(Network)
            // if eventLoop is compatible with NIOTransportServices create a NIOTSConnectionBootstrap
            if #available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *), let tsBootstrap = NIOTSConnectionBootstrap(validatingGroup: eventLoop) {
                // if there is a proxy don't create TLS provider as it will be added at a later point
                if configuration.proxy != nil {
                    bootstrap = NIOClientTCPBootstrap(tsBootstrap, tls: NIOInsecureNoTLS())
                } else {
                    // create NIOClientTCPBootstrap with NIOTS TLS provider
                    let tlsConfiguration = configuration.tlsConfiguration ?? TLSConfiguration.forClient()
                    let parameters = tlsConfiguration.getNWProtocolTLSOptions()
                    let tlsProvider = NIOTSClientTLSProvider(tlsOptions: parameters)
                    bootstrap = NIOClientTCPBootstrap(tsBootstrap, tls: tlsProvider)
                }
            } else if let clientBootstrap = ClientBootstrap(validatingGroup: eventLoop) {
                bootstrap = try clientBootstrap.makeClientTCPBootstrap(host: host, requiresTLS: requiresTLS, configuration: configuration)
            } else {
                preconditionFailure("Cannot create bootstrap for the supplied EventLoop")
            }
        #else
            if let clientBootstrap = ClientBootstrap(validatingGroup: eventLoop) {
                bootstrap = try clientBootstrap.makeClientTCPBootstrap(host: host, requiresTLS: requiresTLS, configuration: configuration)
            } else {
                preconditionFailure("Cannot create bootstrap for the supplied EventLoop")
            }
        #endif

        if let timeout = configuration.timeout.connect {
            bootstrap = bootstrap.connectTimeout(timeout)
        }

        // don't enable TLS if we have a proxy, this will be enabled later on
        if requiresTLS, configuration.proxy == nil {
            return bootstrap.enableTLS()
        }

        return bootstrap
    }

    static func makeHTTPClientBootstrapBase(
        on eventLoop: EventLoop,
        host: String,
        port: Int,
        requiresTLS: Bool,
        configuration: HTTPClient.Configuration
    ) throws -> NIOClientTCPBootstrap {
        return try self.makeBootstrap(on: eventLoop, host: host, requiresTLS: requiresTLS, configuration: configuration)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
            .channelInitializer { channel in
                do {
                    if let proxy = configuration.proxy {
                        try channel.pipeline.syncAddProxyHandler(host: host, port: port, authorization: proxy.authorization)
                    } else if requiresTLS {
                        // We only add the handshake verifier if we need TLS and we're not going through a proxy. If we're going
                        // through a proxy we add it later.
                        let completionPromise = channel.eventLoop.makePromise(of: Void.self)
                        try channel.pipeline.syncOperations.addHandler(TLSEventsHandler(completionPromise: completionPromise), name: TLSEventsHandler.handlerName)
                    }
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
    }

    static func makeHTTP1Channel(destination: ConnectionPool.Key, eventLoop: EventLoop, configuration: HTTPClient.Configuration, preference: HTTPClient.EventLoopPreference) -> EventLoopFuture<Channel> {
        let channelEventLoop = preference.bestEventLoop ?? eventLoop

        let key = destination

        let requiresTLS = key.scheme.requiresTLS
        // Override optional connection pool configuration.
        var keyConfiguration = configuration
        if let tlsConfiguration = key.tlsConfiguration {
            keyConfiguration.tlsConfiguration = tlsConfiguration.base
        }
        let bootstrap: NIOClientTCPBootstrap
        do {
            bootstrap = try NIOClientTCPBootstrap.makeHTTPClientBootstrapBase(on: channelEventLoop, host: key.host, port: key.port, requiresTLS: requiresTLS, configuration: keyConfiguration)
        } catch {
            return channelEventLoop.makeFailedFuture(error)
        }

        let channel: EventLoopFuture<Channel>
        switch key.scheme {
        case .http, .https:
            let address = HTTPClient.resolveAddress(host: key.host, port: key.port, proxy: keyConfiguration.proxy)
            channel = bootstrap.connect(host: address.host, port: address.port)
        case .unix, .http_unix, .https_unix:
            channel = bootstrap.connect(unixDomainSocketPath: key.unixPath)
        }

        return channel.flatMap { channel in
            let requiresTLS = key.scheme.requiresTLS
            let requiresLateSSLHandler = configuration.proxy != nil && requiresTLS
            let handshakeFuture: EventLoopFuture<Void>

            if requiresLateSSLHandler {
                let handshakePromise = channel.eventLoop.makePromise(of: Void.self)
                channel.pipeline.syncAddLateSSLHandlerIfNeeded(for: key, tlsConfiguration: keyConfiguration.tlsConfiguration, handshakePromise: handshakePromise)
                handshakeFuture = handshakePromise.futureResult
            } else if requiresTLS {
                do {
                    handshakeFuture = try channel.pipeline.syncOperations.handler(type: TLSEventsHandler.self).completionPromise.futureResult
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            } else {
                handshakeFuture = channel.eventLoop.makeSucceededVoidFuture()
            }

            return handshakeFuture.flatMapThrowing {
                let syncOperations = channel.pipeline.syncOperations

                // If we got here and we had a TLSEventsHandler in the pipeline, we can remove it ow.
                if requiresTLS {
                    channel.pipeline.removeHandler(name: TLSEventsHandler.handlerName, promise: nil)
                }

                try syncOperations.addHTTPClientHandlers(leftOverBytesStrategy: .forwardBytes)

                #if canImport(Network)
                    if #available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *), bootstrap.underlyingBootstrap is NIOTSConnectionBootstrap {
                        try syncOperations.addHandler(HTTPClient.NWErrorHandler(), position: .first)
                    }
                #endif

                switch configuration.decompression {
                case .disabled:
                    ()
                case .enabled(let limit):
                    let decompressHandler = NIOHTTPResponseDecompressor(limit: limit)
                    try syncOperations.addHandler(decompressHandler)
                }

                return channel
            }
        }.flatMapError { error in
            #if canImport(Network)
                var error = error
                if #available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *), bootstrap.underlyingBootstrap is NIOTSConnectionBootstrap {
                    error = HTTPClient.NWErrorHandler.translateError(error)
                }
            #endif
            return channelEventLoop.makeFailedFuture(error)
        }
    }
}

extension Connection {
    func removeHandler<Handler: RemovableChannelHandler>(_ type: Handler.Type) -> EventLoopFuture<Void> {
        return self.channel.pipeline.handler(type: type).flatMap { handler in
            self.channel.pipeline.removeHandler(handler)
        }.recover { _ in }
    }
}
