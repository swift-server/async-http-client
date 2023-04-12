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
import NIOCore
import NIOHTTP1
import NIOHTTPCompression
import NIOPosix
import NIOSOCKS
import NIOSSL
import NIOTLS
#if canImport(Network)
import NIOTransportServices
#endif

extension HTTPConnectionPool {
    struct ConnectionFactory {
        let key: ConnectionPool.Key
        let clientConfiguration: HTTPClient.Configuration
        let tlsConfiguration: TLSConfiguration
        let sslContextCache: SSLContextCache

        init(key: ConnectionPool.Key,
             tlsConfiguration: TLSConfiguration?,
             clientConfiguration: HTTPClient.Configuration,
             sslContextCache: SSLContextCache) {
            self.key = key
            self.clientConfiguration = clientConfiguration
            self.sslContextCache = sslContextCache
            self.tlsConfiguration = tlsConfiguration ?? clientConfiguration.tlsConfiguration ?? .makeClientConfiguration()
        }
    }
}

protocol HTTPConnectionRequester {
    func http1ConnectionCreated(_: HTTP1Connection)
    func http2ConnectionCreated(_: HTTP2Connection, maximumStreams: Int)
    func failedToCreateHTTPConnection(_: HTTPConnectionPool.Connection.ID, error: Error)
    func waitingForConnectivity(_: HTTPConnectionPool.Connection.ID, error: Error)
}

extension HTTPConnectionPool.ConnectionFactory {
    func makeConnection<Requester: HTTPConnectionRequester>(
        for requester: Requester,
        connectionID: HTTPConnectionPool.Connection.ID,
        http1ConnectionDelegate: HTTP1ConnectionDelegate,
        http2ConnectionDelegate: HTTP2ConnectionDelegate,
        deadline: NIODeadline,
        eventLoop: EventLoop,
        logger: Logger
    ) {
        var logger = logger
        logger[metadataKey: "ahc-connection-id"] = "\(connectionID)"

        self.makeChannel(requester: requester, connectionID: connectionID, deadline: deadline, eventLoop: eventLoop, logger: logger).whenComplete { result in
            switch result {
            case .success(.http1_1(let channel)):
                do {
                    let connection = try HTTP1Connection.start(
                        channel: channel,
                        connectionID: connectionID,
                        delegate: http1ConnectionDelegate,
                        decompression: self.clientConfiguration.decompression,
                        logger: logger
                    )
                    requester.http1ConnectionCreated(connection)
                } catch {
                    requester.failedToCreateHTTPConnection(connectionID, error: error)
                }
            case .success(.http2(let channel)):
                HTTP2Connection.start(
                    channel: channel,
                    connectionID: connectionID,
                    delegate: http2ConnectionDelegate,
                    decompression: self.clientConfiguration.decompression,
                    maximumConnectionUses: self.clientConfiguration.maximumUsesPerConnection,
                    logger: logger
                ).whenComplete { result in
                    switch result {
                    case .success((let connection, let maximumStreams)):
                        requester.http2ConnectionCreated(connection, maximumStreams: maximumStreams)
                    case .failure(let error):
                        requester.failedToCreateHTTPConnection(connectionID, error: error)
                    }
                }

            case .failure(let error):
                requester.failedToCreateHTTPConnection(connectionID, error: error)
            }
        }
    }

    enum NegotiatedProtocol {
        case http1_1(Channel)
        case http2(Channel)
    }

    func makeChannel<Requester: HTTPConnectionRequester>(
        requester: Requester,
        connectionID: HTTPConnectionPool.Connection.ID,
        deadline: NIODeadline,
        eventLoop: EventLoop,
        logger: Logger
    ) -> EventLoopFuture<NegotiatedProtocol> {
        let channelFuture: EventLoopFuture<NegotiatedProtocol>

        if self.key.scheme.isProxyable, let proxy = self.clientConfiguration.proxy {
            switch proxy.type {
            case .socks:
                channelFuture = self.makeSOCKSProxyChannel(
                    proxy,
                    requester: requester,
                    connectionID: connectionID,
                    deadline: deadline,
                    eventLoop: eventLoop,
                    logger: logger
                )
            case .http:
                channelFuture = self.makeHTTPProxyChannel(
                    proxy,
                    requester: requester,
                    connectionID: connectionID,
                    deadline: deadline,
                    eventLoop: eventLoop,
                    logger: logger
                )
            }
        } else {
            channelFuture = self.makeNonProxiedChannel(requester: requester, connectionID: connectionID, deadline: deadline, eventLoop: eventLoop, logger: logger)
        }

        // let's map `ChannelError.connectTimeout` into a `HTTPClientError.connectTimeout`
        return channelFuture.flatMapErrorThrowing { error throws -> NegotiatedProtocol in
            switch error {
            case ChannelError.connectTimeout:
                throw HTTPClientError.connectTimeout
            default:
                throw error
            }
        }
    }

    private func makeNonProxiedChannel<Requester: HTTPConnectionRequester>(
        requester: Requester,
        connectionID: HTTPConnectionPool.Connection.ID,
        deadline: NIODeadline,
        eventLoop: EventLoop,
        logger: Logger
    ) -> EventLoopFuture<NegotiatedProtocol> {
        switch self.key.scheme {
        case .http, .httpUnix, .unix:
            return self.makePlainChannel(requester: requester, connectionID: connectionID, deadline: deadline, eventLoop: eventLoop).map { .http1_1($0) }
        case .https, .httpsUnix:
            return self.makeTLSChannel(requester: requester, connectionID: connectionID, deadline: deadline, eventLoop: eventLoop, logger: logger).flatMapThrowing {
                channel, negotiated in

                try self.matchALPNToHTTPVersion(negotiated, channel: channel)
            }
        }
    }

    private func makePlainChannel<Requester: HTTPConnectionRequester>(
        requester: Requester,
        connectionID: HTTPConnectionPool.Connection.ID,
        deadline: NIODeadline,
        eventLoop: EventLoop
    ) -> EventLoopFuture<Channel> {
        precondition(!self.key.scheme.usesTLS, "Unexpected scheme")
        return self.makePlainBootstrap(requester: requester, connectionID: connectionID, deadline: deadline, eventLoop: eventLoop).connect(target: self.key.connectionTarget)
    }

    private func makeHTTPProxyChannel<Requester: HTTPConnectionRequester>(
        _ proxy: HTTPClient.Configuration.Proxy,
        requester: Requester,
        connectionID: HTTPConnectionPool.Connection.ID,
        deadline: NIODeadline,
        eventLoop: EventLoop,
        logger: Logger
    ) -> EventLoopFuture<NegotiatedProtocol> {
        // A proxy connection starts with a plain text connection to the proxy server. After
        // the connection has been established with the proxy server, the connection might be
        // upgraded to TLS before we send our first request.
        let bootstrap = self.makePlainBootstrap(requester: requester, connectionID: connectionID, deadline: deadline, eventLoop: eventLoop)
        return bootstrap.connect(host: proxy.host, port: proxy.port).flatMap { channel in
            let encoder = HTTPRequestEncoder()
            let decoder = ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .dropBytes))
            let proxyHandler = HTTP1ProxyConnectHandler(
                target: self.key.connectionTarget,
                proxyAuthorization: proxy.authorization,
                deadline: deadline
            )

            do {
                try channel.pipeline.syncOperations.addHandler(encoder)
                try channel.pipeline.syncOperations.addHandler(decoder)
                try channel.pipeline.syncOperations.addHandler(proxyHandler)
            } catch {
                return channel.eventLoop.makeFailedFuture(error)
            }

            // The proxyEstablishedFuture is set as soon as the HTTP1ProxyConnectHandler is in a
            // pipeline. It is created in HTTP1ProxyConnectHandler's handlerAdded method.
            return proxyHandler.proxyEstablishedFuture!.flatMap {
                channel.pipeline.removeHandler(proxyHandler).flatMap {
                    channel.pipeline.removeHandler(decoder).flatMap {
                        channel.pipeline.removeHandler(encoder)
                    }
                }
            }.flatMap {
                self.setupTLSInProxyConnectionIfNeeded(channel, deadline: deadline, logger: logger)
            }
        }
    }

    private func makeSOCKSProxyChannel<Requester: HTTPConnectionRequester>(
        _ proxy: HTTPClient.Configuration.Proxy,
        requester: Requester,
        connectionID: HTTPConnectionPool.Connection.ID,
        deadline: NIODeadline,
        eventLoop: EventLoop,
        logger: Logger
    ) -> EventLoopFuture<NegotiatedProtocol> {
        // A proxy connection starts with a plain text connection to the proxy server. After
        // the connection has been established with the proxy server, the connection might be
        // upgraded to TLS before we send our first request.
        let bootstrap = self.makePlainBootstrap(requester: requester, connectionID: connectionID, deadline: deadline, eventLoop: eventLoop)
        return bootstrap.connect(host: proxy.host, port: proxy.port).flatMap { channel in
            let socksConnectHandler = SOCKSClientHandler(targetAddress: SOCKSAddress(self.key.connectionTarget))
            let socksEventHandler = SOCKSEventsHandler(deadline: deadline)

            do {
                try channel.pipeline.syncOperations.addHandler(socksConnectHandler)
                try channel.pipeline.syncOperations.addHandler(socksEventHandler)
            } catch {
                return channel.eventLoop.makeFailedFuture(error)
            }

            // The socksEstablishedFuture is set as soon as the SOCKSEventsHandler is in a
            // pipeline. It is created in SOCKSEventsHandler's handlerAdded method.
            return socksEventHandler.socksEstablishedFuture!.flatMap {
                channel.pipeline.removeHandler(socksEventHandler).flatMap {
                    channel.pipeline.removeHandler(socksConnectHandler)
                }
            }.flatMap {
                self.setupTLSInProxyConnectionIfNeeded(channel, deadline: deadline, logger: logger)
            }
        }
    }

    private func setupTLSInProxyConnectionIfNeeded(
        _ channel: Channel,
        deadline: NIODeadline,
        logger: Logger
    ) -> EventLoopFuture<NegotiatedProtocol> {
        switch self.key.scheme {
        case .unix, .httpUnix, .httpsUnix:
            preconditionFailure("Unexpected scheme. Not supported for proxy!")
        case .http:
            return channel.eventLoop.makeSucceededFuture(.http1_1(channel))
        case .https:
            var tlsConfig = self.tlsConfiguration
            switch self.clientConfiguration.httpVersion.configuration {
            case .automatic:
                // since we can support h2, we need to advertise this in alpn
                // "ProtocolNameList" contains the list of protocols advertised by the
                // client, in descending order of preference.
                // https://datatracker.ietf.org/doc/html/rfc7301#section-3.1
                tlsConfig.applicationProtocols = ["h2", "http/1.1"]
            case .http1Only:
                tlsConfig.applicationProtocols = ["http/1.1"]
            }
            let tlsEventHandler = TLSEventsHandler(deadline: deadline)

            let sslServerHostname = self.key.serverNameIndicator
            let sslContextFuture = self.sslContextCache.sslContext(
                tlsConfiguration: tlsConfig,
                eventLoop: channel.eventLoop,
                logger: logger
            )

            return sslContextFuture.flatMap { sslContext -> EventLoopFuture<String?> in
                do {
                    let sslHandler = try NIOSSLClientHandler(
                        context: sslContext,
                        serverHostname: sslServerHostname
                    )
                    try channel.pipeline.syncOperations.addHandler(sslHandler)
                    try channel.pipeline.syncOperations.addHandler(tlsEventHandler)

                    // The tlsEstablishedFuture is set as soon as the TLSEventsHandler is in a
                    // pipeline. It is created in TLSEventsHandler's handlerAdded method.
                    return tlsEventHandler.tlsEstablishedFuture!
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }.flatMap { negotiated -> EventLoopFuture<NegotiatedProtocol> in
                channel.pipeline.removeHandler(tlsEventHandler).flatMapThrowing {
                    try self.matchALPNToHTTPVersion(negotiated, channel: channel)
                }
            }
        }
    }

    private func makePlainBootstrap<Requester: HTTPConnectionRequester>(
        requester: Requester,
        connectionID: HTTPConnectionPool.Connection.ID,
        deadline: NIODeadline,
        eventLoop: EventLoop
    ) -> NIOClientTCPBootstrapProtocol {
        #if canImport(Network)
        if #available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *), let tsBootstrap = NIOTSConnectionBootstrap(validatingGroup: eventLoop) {
            return tsBootstrap
                .channelOption(NIOTSChannelOptions.waitForActivity, value: self.clientConfiguration.networkFrameworkWaitForConnectivity)
                .connectTimeout(deadline - NIODeadline.now())
                .channelInitializer { channel in
                    do {
                        try channel.pipeline.syncOperations.addHandler(HTTPClient.NWErrorHandler())
                        try channel.pipeline.syncOperations.addHandler(NWWaitingHandler(requester: requester, connectionID: connectionID))
                        return channel.eventLoop.makeSucceededVoidFuture()
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                }
        }
        #endif

        if let nioBootstrap = ClientBootstrap(validatingGroup: eventLoop) {
            return nioBootstrap
                .connectTimeout(deadline - NIODeadline.now())
        }

        preconditionFailure("No matching bootstrap found")
    }

    private func makeTLSChannel<Requester: HTTPConnectionRequester>(
        requester: Requester,
        connectionID: HTTPConnectionPool.Connection.ID,
        deadline: NIODeadline,
        eventLoop: EventLoop,
        logger: Logger
    ) -> EventLoopFuture<(Channel, String?)> {
        precondition(self.key.scheme.usesTLS, "Unexpected scheme")
        let bootstrapFuture = self.makeTLSBootstrap(
            requester: requester,
            connectionID: connectionID,
            deadline: deadline,
            eventLoop: eventLoop,
            logger: logger
        )

        var channelFuture = bootstrapFuture.flatMap { bootstrap -> EventLoopFuture<Channel> in
            return bootstrap.connect(target: self.key.connectionTarget)
        }.flatMap { channel -> EventLoopFuture<(Channel, String?)> in
            do {
                // if the channel is closed before flatMap is executed, all ChannelHandler are removed
                // and TLSEventsHandler is therefore not present either
                let tlsEventHandler = try channel.pipeline.syncOperations.handler(type: TLSEventsHandler.self)

                // The tlsEstablishedFuture is set as soon as the TLSEventsHandler is in a
                // pipeline. It is created in TLSEventsHandler's handlerAdded method.
                return tlsEventHandler.tlsEstablishedFuture!.flatMap { negotiated in
                    channel.pipeline.removeHandler(tlsEventHandler).map { (channel, negotiated) }
                }
            } catch {
                assert(channel.isActive == false, "if the channel is still active then TLSEventsHandler must be present but got error \(error)")
                return channel.eventLoop.makeFailedFuture(HTTPClientError.remoteConnectionClosed)
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

    private func makeTLSBootstrap<Requester: HTTPConnectionRequester>(
        requester: Requester,
        connectionID: HTTPConnectionPool.Connection.ID,
        deadline: NIODeadline,
        eventLoop: EventLoop,
        logger: Logger
    ) -> EventLoopFuture<NIOClientTCPBootstrapProtocol> {
        var tlsConfig = self.tlsConfiguration
        switch self.clientConfiguration.httpVersion.configuration {
        case .automatic:
            // since we can support h2, we need to advertise this in alpn
            // "ProtocolNameList" contains the list of protocols advertised by the
            // client, in descending order of preference.
            // https://datatracker.ietf.org/doc/html/rfc7301#section-3.1
            tlsConfig.applicationProtocols = ["h2", "http/1.1"]
        case .http1Only:
            tlsConfig.applicationProtocols = ["http/1.1"]
        }

        #if canImport(Network)
        if #available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *), let tsBootstrap = NIOTSConnectionBootstrap(validatingGroup: eventLoop) {
            // create NIOClientTCPBootstrap with NIOTS TLS provider
            let bootstrapFuture = tlsConfig.getNWProtocolTLSOptions(on: eventLoop, serverNameIndicatorOverride: key.serverNameIndicatorOverride).map {
                options -> NIOClientTCPBootstrapProtocol in

                tsBootstrap
                    .channelOption(NIOTSChannelOptions.waitForActivity, value: self.clientConfiguration.networkFrameworkWaitForConnectivity)
                    .connectTimeout(deadline - NIODeadline.now())
                    .tlsOptions(options)
                    .channelInitializer { channel in
                        do {
                            try channel.pipeline.syncOperations.addHandler(HTTPClient.NWErrorHandler())
                            try channel.pipeline.syncOperations.addHandler(NWWaitingHandler(requester: requester, connectionID: connectionID))
                            // we don't need to set a TLS deadline for NIOTS connections, since the
                            // TLS handshake is part of the TS connection bootstrap. If the TLS
                            // handshake times out the complete connection creation will be failed.
                            try channel.pipeline.syncOperations.addHandler(TLSEventsHandler(deadline: nil))
                            return channel.eventLoop.makeSucceededVoidFuture()
                        } catch {
                            return channel.eventLoop.makeFailedFuture(error)
                        }
                    } as NIOClientTCPBootstrapProtocol
            }
            return bootstrapFuture
        }
        #endif

        let sslContextFuture = sslContextCache.sslContext(
            tlsConfiguration: tlsConfig,
            eventLoop: eventLoop,
            logger: logger
        )

        let bootstrap = ClientBootstrap(group: eventLoop)
            .connectTimeout(deadline - NIODeadline.now())
            .channelInitializer { channel in
                sslContextFuture.flatMap { sslContext -> EventLoopFuture<Void> in
                    do {
                        let sync = channel.pipeline.syncOperations
                        let sslHandler = try NIOSSLClientHandler(
                            context: sslContext,
                            serverHostname: self.key.serverNameIndicator
                        )
                        let tlsEventHandler = TLSEventsHandler(deadline: deadline)

                        try sync.addHandler(sslHandler)
                        try sync.addHandler(tlsEventHandler)
                        return channel.eventLoop.makeSucceededVoidFuture()
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                }
            }

        return eventLoop.makeSucceededFuture(bootstrap)
    }

    private func matchALPNToHTTPVersion(_ negotiated: String?, channel: Channel) throws -> NegotiatedProtocol {
        switch negotiated {
        case .none, .some("http/1.1"):
            return .http1_1(channel)
        case .some("h2"):
            return .http2(channel)
        case .some(let unsupported):
            throw HTTPClientError.serverOfferedUnsupportedApplicationProtocol(unsupported)
        }
    }
}

extension Scheme {
    var isProxyable: Bool {
        switch self {
        case .http, .https:
            return true
        case .unix, .httpUnix, .httpsUnix:
            return false
        }
    }
}

extension ConnectionPool.Key {
    var serverNameIndicator: String? {
        serverNameIndicatorOverride ?? connectionTarget.sslServerHostname
    }
}

extension ConnectionTarget {
    fileprivate var sslServerHostname: String? {
        switch self {
        case .domain(let domain, _): return domain
        case .ipAddress, .unixSocket: return nil
        }
    }
}

extension SOCKSAddress {
    fileprivate init(_ host: ConnectionTarget) {
        switch host {
        case .ipAddress(_, let address): self = .address(address)
        case .domain(let domain, let port): self = .domain(domain, port: port)
        case .unixSocket: fatalError("Unix Domain Sockets are not supported by SOCKSAddress")
        }
    }
}

extension NIOClientTCPBootstrapProtocol {
    func connect(target: ConnectionTarget) -> EventLoopFuture<Channel> {
        switch target {
        case .ipAddress(_, let socketAddress):
            return self.connect(to: socketAddress)
        case .domain(let domain, let port):
            return self.connect(host: domain, port: port)
        case .unixSocket(let path):
            return self.connect(unixDomainSocketPath: path)
        }
    }
}
