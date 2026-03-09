//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2019-2021 Apple Inc. and the AsyncHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import CNIOLinux
import NIOCore
import NIOSSL

#if canImport(Darwin)
import Darwin.C
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#elseif os(Linux) || os(FreeBSD)
import Glibc
#else
#error("unsupported target operating system")
#endif

extension String {
    var isIPAddress: Bool {
        var ipv4Address = in_addr()
        var ipv6Address = in6_addr()
        return self.withCString { host in
            inet_pton(AF_INET, host, &ipv4Address) == 1 || inet_pton(AF_INET6, host, &ipv6Address) == 1
        }
    }
}

enum ConnectionPool {
    /// Used by the `ConnectionPool` to index its `HTTP1ConnectionProvider`s
    ///
    /// A key is initialized from a `Request`, it uses the components to derive a hashed value
    /// used by the `providers` dictionary to allow retrieving and creating
    /// connection providers associated to a certain request in constant time.
    struct Key: Hashable, CustomStringConvertible {
        var scheme: Scheme
        var connectionTarget: ConnectionTarget
        private var tlsConfiguration: BestEffortHashableTLSConfiguration?
        var serverNameIndicatorOverride: String?
        var localAddress: String?

        init(
            scheme: Scheme,
            connectionTarget: ConnectionTarget,
            tlsConfiguration: BestEffortHashableTLSConfiguration? = nil,
            serverNameIndicatorOverride: String?,
            localAddress: String? = nil
        ) {
            self.scheme = scheme
            self.connectionTarget = connectionTarget
            self.tlsConfiguration = tlsConfiguration
            self.serverNameIndicatorOverride = serverNameIndicatorOverride
            self.localAddress = localAddress
        }

        var description: String {
            var hasher = Hasher()
            self.tlsConfiguration?.hash(into: &hasher)
            let hash = hasher.finalize()
            let hostDescription: String
            switch self.connectionTarget {
            case .ipAddress(let serialization, let addr):
                hostDescription = "\(serialization):\(addr.port!)"
            case .domain(let domain, let port):
                hostDescription = "\(domain):\(port)"
            case .unixSocket(let socketPath):
                hostDescription = socketPath
            }
            var result =
                "\(self.scheme)://\(hostDescription)\(self.serverNameIndicatorOverride.map { " SNI: \($0)" } ?? "") TLS-hash: \(hash)"
            if let addr = self.localAddress {
                result += " bind: \(addr)"
            }
            return result
        }
    }
}

extension DeconstructedURL {
    func applyDNSOverride(_ dnsOverride: [String: String]) -> (ConnectionTarget, serverNameIndicatorOverride: String?) {
        guard
            let originalHost = self.connectionTarget.host,
            let hostOverride = dnsOverride[originalHost]
        else {
            return (self.connectionTarget, nil)
        }
        return (
            .init(remoteHost: hostOverride, port: self.connectionTarget.port ?? self.scheme.defaultPort),
            serverNameIndicatorOverride: originalHost.isIPAddress ? nil : originalHost
        )
    }
}

extension ConnectionPool.Key {
    init(url: DeconstructedURL, tlsConfiguration: TLSConfiguration?, dnsOverride: [String: String], localAddress: String? = nil) {
        let (connectionTarget, serverNameIndicatorOverride) = url.applyDNSOverride(dnsOverride)
        self.init(
            scheme: url.scheme,
            connectionTarget: connectionTarget,
            tlsConfiguration: tlsConfiguration.map {
                BestEffortHashableTLSConfiguration(wrapping: $0)
            },
            serverNameIndicatorOverride: serverNameIndicatorOverride,
            localAddress: localAddress
        )
    }

    init(_ request: HTTPClient.Request, dnsOverride: [String: String] = [:], localAddress: String? = nil) {
        self.init(
            url: request.deconstructedURL,
            tlsConfiguration: request.tlsConfiguration,
            dnsOverride: dnsOverride,
            localAddress: localAddress
        )
    }
}
