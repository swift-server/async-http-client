//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2021 Apple Inc. and the AsyncHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Logging
import NIO
import NIOHTTP1
import NIOSOCKS
import NIOSSL
import NIOTLS
#if canImport(Network)
    import NIOTransportServices
#endif

extension HTTPConnectionPool {
    enum NegotiatedProtocol {
        case http1_1(Channel)
        case http2_0(Channel)
    }

    final class ConnectionFactory {
        
        struct Timeouts {
            /// the `TimeAmount` waited before the TCP connection creation is failed with a timeout error
            var connect: TimeAmount = .seconds(10)
            
            /// the `TimeAmount` waited before the SOCKS proxy connection creation is failed with a timeout error
            var socksProxyHandshake: TimeAmount = .seconds(10)
            
            /// the `TimeAmount` waited before the HTTP proxy connection creation is failed with a timeout error
            var httpProxyHandshake: TimeAmount = .seconds(10)
            
            /// the `TimeAmount` waited before we the TLS handshake is failed with a timeout error
            var tlsHandshake: TimeAmount = .seconds(10)
        }
        
        let key: ConnectionPool.Key
        let clientConfiguration: HTTPClient.Configuration
        let tlsConfiguration: TLSConfiguration
        let sslContextCache: SSLContextCache
        let timeouts: Timeouts

        init(key: ConnectionPool.Key,
             tlsConfiguration: TLSConfiguration?,
             clientConfiguration: HTTPClient.Configuration,
             sslContextCache: SSLContextCache,
             timeouts: Timeouts = .init()) {
            self.key = key
            self.clientConfiguration = clientConfiguration
            self.sslContextCache = sslContextCache
            self.tlsConfiguration = tlsConfiguration ?? clientConfiguration.tlsConfiguration ?? .forClient()
            
            var timeouts = timeouts
            if let connect = clientConfiguration.timeout.connect {
                timeouts.connect = connect
            }
            self.timeouts = timeouts
        }
    }
}

extension HTTPConnectionPool.ConnectionFactory {
    func makeChannel(connectionID: HTTPConnectionPool.Connection.ID, eventLoop: EventLoop, logger: Logger) -> EventLoopFuture<(Channel, HTTPVersion)> {
        if self.key.scheme.isProxyable, let proxy = self.clientConfiguration.proxy {
            switch proxy.type {
            case .socks:
                return self.makeSOCKSProxyChannel(proxy, connectionID: connectionID, eventLoop: eventLoop, logger: logger)
            case .http:
                return self.makeHTTPProxyChannel(proxy, connectionID: connectionID, eventLoop: eventLoop, logger: logger)
            }
        } else {
            return self.makeNonProxiedChannel(eventLoop: eventLoop, logger: logger)
        }
    }

    private func makeNonProxiedChannel(eventLoop: EventLoop, logger: Logger) -> EventLoopFuture<(Channel, HTTPVersion)> {
        switch self.key.scheme {
        case .http, .http_unix, .unix:
            return self.makePlainChannel(eventLoop: eventLoop).map { ($0, .http1_1) }
        case .https, .https_unix:
            return self.makeTLSChannel(eventLoop: eventLoop, logger: logger).map {
                (channel, negotiated) -> (Channel, HTTPVersion) in
                let version = negotiated == "h2" ? HTTPVersion.http2 : HTTPVersion.http1_1
                return (channel, version)
            }
        }
    }

    private func makePlainChannel(eventLoop: EventLoop) -> EventLoopFuture<Channel> {
        let bootstrap = self.makePlainBootstrap(eventLoop: eventLoop)

        switch self.key.scheme {
        case .http:
            return bootstrap.connect(host: self.key.host, port: self.key.port)
        case .http_unix, .unix:
            return bootstrap.connect(unixDomainSocketPath: self.key.unixPath)
        case .https, .https_unix:
            preconditionFailure("Unexpected scheme")
        }
    }

    private func makeHTTPProxyChannel(
        _ proxy: HTTPClient.Configuration.Proxy,
        connectionID: HTTPConnectionPool.Connection.ID,
        eventLoop: EventLoop,
        logger: Logger
    ) -> EventLoopFuture<(Channel, HTTPVersion)> {
        // A proxy connection starts with a plain text connection to the proxy server. After
        // the connection has been established with the proxy server, the connection might be
        // upgraded to TLS before we send our first request.
        let bootstrap = self.makePlainBootstrap(eventLoop: eventLoop)
        return bootstrap.connect(host: proxy.host, port: proxy.port).flatMap { channel in
            let encoder = HTTPRequestEncoder()
            let decoder = ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .dropBytes))
            let proxyHandler = HTTP1ProxyConnectHandler(
                targetHost: self.key.host,
                targetPort: self.key.port,
                proxyAuthorization: proxy.authorization,
                deadline: .now() + self.timeouts.httpProxyHandshake
            )

            do {
                try channel.pipeline.syncOperations.addHandler(encoder)
                try channel.pipeline.syncOperations.addHandler(decoder)
                try channel.pipeline.syncOperations.addHandler(proxyHandler)
            } catch {
                return channel.eventLoop.makeFailedFuture(error)
            }

            return proxyHandler.proxyEstablishedFuture.flatMap {
                channel.pipeline.removeHandler(proxyHandler).flatMap {
                    channel.pipeline.removeHandler(decoder).flatMap {
                        channel.pipeline.removeHandler(encoder)
                    }
                }
            }.flatMap {
                self.setupTLSInProxyConnectionIfNeeded(channel, logger: logger)
            }
        }
    }

    private func makeSOCKSProxyChannel(
        _ proxy: HTTPClient.Configuration.Proxy,
        connectionID: HTTPConnectionPool.Connection.ID,
        eventLoop: EventLoop,
        logger: Logger
    ) -> EventLoopFuture<(Channel, HTTPVersion)> {
        // A proxy connection starts with a plain text connection to the proxy server. After
        // the connection has been established with the proxy server, the connection might be
        // upgraded to TLS before we send our first request.
        let bootstrap = self.makePlainBootstrap(eventLoop: eventLoop)
        return bootstrap.connect(host: proxy.host, port: proxy.port).flatMap { channel in
            let socksConnectHandler = SOCKSClientHandler(targetAddress: .domain(self.key.host, port: self.key.port))
            let socksEventHandler = SOCKSEventsHandler(deadline: .now() + self.timeouts.socksProxyHandshake)

            do {
                try channel.pipeline.syncOperations.addHandler(socksConnectHandler)
                try channel.pipeline.syncOperations.addHandler(socksEventHandler)
            } catch {
                return channel.eventLoop.makeFailedFuture(error)
            }

            return socksEventHandler.socksEstablishedFuture.flatMap {
                channel.pipeline.removeHandler(socksEventHandler).flatMap {
                    channel.pipeline.removeHandler(socksConnectHandler)
                }
            }.flatMap {
                self.setupTLSInProxyConnectionIfNeeded(channel, logger: logger)
            }
        }
    }

    private func setupTLSInProxyConnectionIfNeeded(_ channel: Channel, logger: Logger) -> EventLoopFuture<(Channel, HTTPVersion)> {
        switch self.key.scheme {
        case .unix, .http_unix, .https_unix:
            preconditionFailure("Unexpected scheme. Not supported for proxy!")
        case .http:
            return channel.eventLoop.makeSucceededFuture((channel, .http1_1))
        case .https:
            var tlsConfig = self.tlsConfiguration
            // since we can support h2, we need to advertise this in alpn
            tlsConfig.applicationProtocols = ["http/1.1" /* , "h2" */ ]
            let tlsEventHandler = TLSEventsHandler(deadline: .now() + self.timeouts.tlsHandshake)

            let sslContextFuture = self.sslContextCache.sslContext(
                tlsConfiguration: tlsConfig,
                eventLoop: channel.eventLoop,
                logger: logger
            )

            return sslContextFuture.flatMap { sslContext -> EventLoopFuture<String?> in
                do {
                    let sslHandler = try NIOSSLClientHandler(
                        context: sslContext,
                        serverHostname: self.key.host
                    )
                    try channel.pipeline.syncOperations.addHandler(sslHandler)
                    try channel.pipeline.syncOperations.addHandler(tlsEventHandler)
                    return tlsEventHandler.tlsEstablishedFuture
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }.flatMap { negotiated -> EventLoopFuture<(Channel, HTTPVersion)> in
                channel.pipeline.removeHandler(tlsEventHandler).map {
                    switch negotiated {
                    case "h2":
                        return (channel, .http2)
                    default:
                        return (channel, .http1_1)
                    }
                }
            }
        }
    }

    private func makePlainBootstrap(eventLoop: EventLoop) -> NIOClientTCPBootstrapProtocol {
        #if canImport(Network)
            if #available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *), let tsBootstrap = NIOTSConnectionBootstrap(validatingGroup: eventLoop) {
                return tsBootstrap
                    .connectTimeout(self.timeouts.connect)
                    .channelInitializer { channel in
                        do {
                            try channel.pipeline.syncOperations.addHandler(HTTPClient.NWErrorHandler())
                            return channel.eventLoop.makeSucceededFuture(())
                        } catch {
                            return channel.eventLoop.makeFailedFuture(error)
                        }
                    }
            }
        #endif

        if let nioBootstrap = ClientBootstrap(validatingGroup: eventLoop) {
            return nioBootstrap
                .connectTimeout(self.timeouts.connect)
        }

        preconditionFailure("No matching bootstrap found")
    }

    private func makeTLSChannel(eventLoop: EventLoop, logger: Logger) -> EventLoopFuture<(Channel, String?)> {
        let bootstrapFuture = self.makeTLSBootstrap(
            eventLoop: eventLoop,
            logger: logger
        )

        var channelFuture = bootstrapFuture.flatMap { bootstrap -> EventLoopFuture<Channel> in
            switch self.key.scheme {
            case .https:
                return bootstrap.connect(host: self.key.host, port: self.key.port)
            case .https_unix:
                return bootstrap.connect(unixDomainSocketPath: self.key.unixPath)
            case .http, .http_unix, .unix:
                preconditionFailure("Unexpected scheme")
            }
        }.flatMap { channel -> EventLoopFuture<(Channel, String?)> in
            let tlsEventHandler = try! channel.pipeline.syncOperations.handler(type: TLSEventsHandler.self)
            return tlsEventHandler.tlsEstablishedFuture.flatMap { negotiated in
                channel.pipeline.removeHandler(tlsEventHandler).map { (channel, negotiated) }
            }
        }

        #if canImport(Network)
            // If NIOTransportSecurity is used, we want to map NWErrors into NWPOsixErrors or NWTLSError.
            channelFuture = channelFuture.flatMapErrorThrowing { error in
                throw HTTPClient.NWErrorHandler.translateError(error)
            }
        #endif

        return channelFuture
    }

    private func makeTLSBootstrap(eventLoop: EventLoop, logger: Logger)
        -> EventLoopFuture<NIOClientTCPBootstrapProtocol> {
        // since we can support h2, we need to advertise this in alpn
        var tlsConfig = self.tlsConfiguration
        tlsConfig.applicationProtocols = ["http/1.1" /* , "h2" */ ]

        #if canImport(Network)
            if #available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *), let tsBootstrap = NIOTSConnectionBootstrap(validatingGroup: eventLoop) {
                // create NIOClientTCPBootstrap with NIOTS TLS provider
                let bootstrapFuture = tlsConfig.getNWProtocolTLSOptions(on: eventLoop).map {
                    options -> NIOClientTCPBootstrapProtocol in

                    tsBootstrap
                        .connectTimeout(self.timeouts.connect)
                        .tlsOptions(options)
                        .channelInitializer { channel in
                            do {
                                try channel.pipeline.syncOperations.addHandler(HTTPClient.NWErrorHandler())
                                // we don't need to set a TLS deadline for NIOTS connections, since the
                                // TLS handshake is part of the TS connection bootstrap. If the TLS
                                // handshake times out the complete connection creation will be failed.
                                try channel.pipeline.syncOperations.addHandler(TLSEventsHandler(deadline: nil))
                                return channel.eventLoop.makeSucceededFuture(())
                            } catch {
                                return channel.eventLoop.makeFailedFuture(error)
                            }
                        } as NIOClientTCPBootstrapProtocol
                }
                return bootstrapFuture
            }
        #endif

        let host = self.key.host
        let hostname = (host.isIPAddress || host.isEmpty) ? nil : host

        let sslContextFuture = sslContextCache.sslContext(
            tlsConfiguration: tlsConfig,
            eventLoop: eventLoop,
            logger: logger
        )

        let bootstrap = ClientBootstrap(group: eventLoop)
            .connectTimeout(self.timeouts.connect)
            .channelInitializer { channel in
                sslContextFuture.flatMap { (sslContext) -> EventLoopFuture<Void> in
                    do {
                        let sync = channel.pipeline.syncOperations
                        let sslHandler = try NIOSSLClientHandler(
                            context: sslContext,
                            serverHostname: hostname
                        )
                        let tlsEventHandler = TLSEventsHandler(deadline: .now() + self.timeouts.tlsHandshake)

                        try sync.addHandler(sslHandler)
                        try sync.addHandler(tlsEventHandler)
                        return channel.eventLoop.makeSucceededFuture(())
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                }
            }

        return eventLoop.makeSucceededFuture(bootstrap)
    }
}

extension ConnectionPool.Key.Scheme {
    var isProxyable: Bool {
        switch self {
        case .http, .https:
            return true
        case .unix, .http_unix, .https_unix:
            return false
        }
    }
}

private extension String {
    var isIPAddress: Bool {
        var ipv4Addr = in_addr()
        var ipv6Addr = in6_addr()

        return self.withCString { ptr in
            inet_pton(AF_INET, ptr, &ipv4Addr) == 1 ||
                inet_pton(AF_INET6, ptr, &ipv6Addr) == 1
        }
    }
}
