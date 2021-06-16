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
import Logging
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

extension NIOClientTCPBootstrap {
    static func makeHTTP1Channel(destination: ConnectionPool.Key,
                                 eventLoop: EventLoop,
                                 configuration: HTTPClient.Configuration,
                                 sslContextCache: SSLContextCache,
                                 preference: HTTPClient.EventLoopPreference,
                                 logger: Logger) -> EventLoopFuture<Channel> {
        let channelEventLoop = preference.bestEventLoop ?? eventLoop

        let key = destination
        let requiresTLS = key.scheme.requiresTLS
        let sslContext: EventLoopFuture<NIOSSLContext?>
        if key.scheme.requiresTLS, configuration.proxy != nil {
            // If we use a proxy & also require TLS, then we always use NIOSSL (and not Network.framework TLS because
            // it can't be added later) and therefore require a `NIOSSLContext`.
            // In this case, `makeAndConfigureBootstrap` will not create another `NIOSSLContext`.
            //
            // Note that TLS proxies are not supported at the moment. This means that we will always speak
            // plaintext to the proxy but we do support sending HTTPS traffic through the proxy.
            sslContext = sslContextCache.sslContext(tlsConfiguration: configuration.tlsConfiguration ?? .forClient(),
                                                    eventLoop: eventLoop,
                                                    logger: logger).map { $0 }
        } else {
            sslContext = eventLoop.makeSucceededFuture(nil)
        }

        let bootstrap = NIOClientTCPBootstrap.makeAndConfigureBootstrap(on: channelEventLoop,
                                                                        host: key.host,
                                                                        port: key.port,
                                                                        requiresTLS: requiresTLS,
                                                                        configuration: configuration,
                                                                        sslContextCache: sslContextCache,
                                                                        logger: logger)
        return bootstrap.flatMap { bootstrap -> EventLoopFuture<Channel> in
            let channel: EventLoopFuture<Channel>
            switch key.scheme {
            case .http, .https:
                let address = HTTPClient.resolveAddress(host: key.host, port: key.port, proxy: configuration.proxy)
                channel = bootstrap.connect(host: address.host, port: address.port)
            case .unix, .http_unix, .https_unix:
                channel = bootstrap.connect(unixDomainSocketPath: key.unixPath)
            }

            return channel.flatMap { channel -> EventLoopFuture<(Channel, NIOSSLContext?)> in
                sslContext.map { sslContext -> (Channel, NIOSSLContext?) in
                    (channel, sslContext)
                }
            }.flatMap { channel, sslContext in
                configureChannelPipeline(channel,
                                         isNIOTS: bootstrap.isNIOTS,
                                         sslContext: sslContext,
                                         configuration: configuration,
                                         key: key)
            }.flatMapErrorThrowing { error in
                if bootstrap.isNIOTS {
                    throw HTTPClient.NWErrorHandler.translateError(error)
                } else {
                    throw error
                }
            }
        }
    }

    /// Creates and configures a bootstrap given the `eventLoop`, if TLS/a proxy is being used.
    private static func makeAndConfigureBootstrap(
        on eventLoop: EventLoop,
        host: String,
        port: Int,
        requiresTLS: Bool,
        configuration: HTTPClient.Configuration,
        sslContextCache: SSLContextCache,
        logger: Logger
    ) -> EventLoopFuture<NIOClientTCPBootstrap> {
        return self.makeBestBootstrap(host: host,
                                      eventLoop: eventLoop,
                                      requiresTLS: requiresTLS,
                                      sslContextCache: sslContextCache,
                                      tlsConfiguration: configuration.tlsConfiguration ?? .forClient(),
                                      useProxy: configuration.proxy != nil,
                                      logger: logger)
            .map { bootstrap -> NIOClientTCPBootstrap in
                var bootstrap = bootstrap

                if let timeout = configuration.timeout.connect {
                    bootstrap = bootstrap.connectTimeout(timeout)
                }

                // Don't enable TLS if we have a proxy, this will be enabled later on (outside of this method).
                if requiresTLS, configuration.proxy == nil {
                    bootstrap = bootstrap.enableTLS()
                }

                return bootstrap.channelInitializer { channel in
                    do {
                        if let proxy = configuration.proxy {
                            switch proxy.type {
                            case .http:
                                try channel.pipeline.syncAddProxyHandler(host: host,
                                                                         port: port,
                                                                         authorization: proxy.authorization)
                            case .socks:
                                try channel.pipeline.syncAddSOCKSProxyHandler(host: host, port: port)
                            }
                        } else if requiresTLS {
                            // We only add the handshake verifier if we need TLS and we're not going through a proxy.
                            // If we're going through a proxy we add it later (outside of this method).
                            let completionPromise = channel.eventLoop.makePromise(of: Void.self)
                            try channel.pipeline.syncOperations.addHandler(TLSEventsHandler(completionPromise: completionPromise),
                                                                           name: TLSEventsHandler.handlerName)
                        }
                        return channel.eventLoop.makeSucceededVoidFuture()
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                }
            }
    }

    /// Creates the best-suited bootstrap given an `EventLoop` and pairs it with an appropriate TLS provider.
    private static func makeBestBootstrap(
        host: String,
        eventLoop: EventLoop,
        requiresTLS: Bool,
        sslContextCache: SSLContextCache,
        tlsConfiguration: TLSConfiguration,
        useProxy: Bool,
        logger: Logger
    ) -> EventLoopFuture<NIOClientTCPBootstrap> {
        #if canImport(Network)
            // if eventLoop is compatible with NIOTransportServices create a NIOTSConnectionBootstrap
            if #available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *), let tsBootstrap = NIOTSConnectionBootstrap(validatingGroup: eventLoop) {
                // create NIOClientTCPBootstrap with NIOTS TLS provider
                return tlsConfiguration.getNWProtocolTLSOptions(on: eventLoop)
                    .map { parameters in
                        let tlsProvider = NIOTSClientTLSProvider(tlsOptions: parameters)
                        return NIOClientTCPBootstrap(tsBootstrap, tls: tlsProvider)
                    }
            }
        #endif

        if let clientBootstrap = ClientBootstrap(validatingGroup: eventLoop) {
            // If there is a proxy don't create TLS provider as it will be added at a later point.
            if !requiresTLS || useProxy {
                return eventLoop.makeSucceededFuture(NIOClientTCPBootstrap(clientBootstrap,
                                                                           tls: NIOInsecureNoTLS()))
            } else {
                return sslContextCache.sslContext(tlsConfiguration: tlsConfiguration,
                                                  eventLoop: eventLoop,
                                                  logger: logger)
                    .flatMapThrowing { sslContext in
                        let hostname = (host.isIPAddress || host.isEmpty) ? nil : host
                        let tlsProvider = try NIOSSLClientTLSProvider<ClientBootstrap>(context: sslContext, serverHostname: hostname)
                        return NIOClientTCPBootstrap(clientBootstrap, tls: tlsProvider)
                    }
            }
        }

        preconditionFailure("Cannot create bootstrap for event loop \(eventLoop)")
    }
}

private func configureChannelPipeline(_ channel: Channel,
                                      isNIOTS: Bool,
                                      sslContext: NIOSSLContext?,
                                      configuration: HTTPClient.Configuration,
                                      key: ConnectionPool.Key) -> EventLoopFuture<Channel> {
    let requiresTLS = key.scheme.requiresTLS
    let handshakeFuture: EventLoopFuture<Void>

    if requiresTLS, configuration.proxy != nil {
        let handshakePromise = channel.eventLoop.makePromise(of: Void.self)
        channel.pipeline.syncAddLateSSLHandlerIfNeeded(for: key,
                                                       sslContext: sslContext!,
                                                       handshakePromise: handshakePromise)
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

        if isNIOTS {
            try syncOperations.addHandler(HTTPClient.NWErrorHandler(), position: .first)
        }

        switch configuration.decompression {
        case .disabled:
            ()
        case .enabled(let limit):
            let decompressHandler = NIOHTTPResponseDecompressor(limit: limit)
            try syncOperations.addHandler(decompressHandler)
        }

        return channel
    }
}

extension Connection {
    func removeHandler<Handler: RemovableChannelHandler>(_ type: Handler.Type) -> EventLoopFuture<Void> {
        return self.channel.pipeline.handler(type: type).flatMap { handler in
            self.channel.pipeline.removeHandler(handler)
        }.recover { _ in }
    }
}

extension NIOClientTCPBootstrap {
    var isNIOTS: Bool {
        #if canImport(Network)
            if #available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *) {
                return self.underlyingBootstrap is NIOTSConnectionBootstrap
            } else {
                return false
            }
        #else
            return false
        #endif
    }
}
