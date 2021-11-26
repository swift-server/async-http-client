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

import enum NIOCore.SocketAddress

enum ConnectionPool {
    enum Host: Hashable {
        // We keep the IP address serialization precisely as it is in the URL.
        // Some platforms have quirks in their implementations of 'ntop', for example
        // writing IPv6 addresses as having embedded IPv4 sections (e.g. [::192.168.0.1] vs [::c0a8:1]).
        // This serialization includes square brackets, so it is safe to write next to a port number.
        // Note: `address` must always have a non-nil port.
        case ipAddress(serialization: String, address: SocketAddress)
        case domain(name: String, port: Int)
        case unixSocket(path: String)

        init(remoteHost: String, port: Int) {
            if let addr = try? SocketAddress(ipAddress: remoteHost, port: port) {
                switch addr {
                case .v6:
                    self = .ipAddress(serialization: "[\(remoteHost)]", address: addr)
                case .v4:
                    self = .ipAddress(serialization: remoteHost, address: addr)
                case .unixDomainSocket:
                    fatalError("Expected a remote host")
                }
            } else {
                precondition(!remoteHost.isEmpty, "HTTPClient.Request should already reject empty remote hostnames")
                self = .domain(name: remoteHost, port: port)
            }
        }
    }

    /// Used by the `ConnectionPool` to index its `HTTP1ConnectionProvider`s
    ///
    /// A key is initialized from a `URL`, it uses the components to derive a hashed value
    /// used by the `providers` dictionary to allow retrieving and creating
    /// connection providers associated to a certain request in constant time.
    struct Key: Hashable, CustomStringConvertible {
        var scheme: Scheme
        var host: Host
        private var tlsConfiguration: BestEffortHashableTLSConfiguration?

        init(_ request: HTTPClient.Request) {
            switch request.scheme {
            case "http":
                self.scheme = .http
                self.host = Host(remoteHost: request.host, port: request.port)
            case "https":
                self.scheme = .https
                self.host = Host(remoteHost: request.host, port: request.port)
            case "unix":
                self.scheme = .unix
                self.host = .unixSocket(path: request.socketPath)
            case "http+unix":
                self.scheme = .http_unix
                self.host = .unixSocket(path: request.socketPath)
            case "https+unix":
                self.scheme = .https_unix
                self.host = .unixSocket(path: request.socketPath)
            default:
                fatalError("HTTPClient.Request scheme should already be a valid one")
            }
            if let tls = request.tlsConfiguration {
                self.tlsConfiguration = BestEffortHashableTLSConfiguration(wrapping: tls)
            }
        }

        enum Scheme: Hashable {
            case http
            case https
            case unix
            case http_unix
            case https_unix

            var requiresTLS: Bool {
                switch self {
                case .https, .https_unix:
                    return true
                default:
                    return false
                }
            }
        }

        /// Returns a key-specific `HTTPClient.Configuration` by overriding the properties of `base`
        func config(overriding base: HTTPClient.Configuration) -> HTTPClient.Configuration {
            var config = base
            if let tlsConfiguration = self.tlsConfiguration {
                config.tlsConfiguration = tlsConfiguration.base
            }
            return config
        }

        var description: String {
            var hasher = Hasher()
            self.tlsConfiguration?.hash(into: &hasher)
            let hash = hasher.finalize()
            var hostDescription = ""
            switch host {
            case .ipAddress(let serialization, let addr):
                hostDescription = "\(serialization):\(addr.port!)"
            case .domain(let domain, port: let port):
                hostDescription = "\(domain):\(port)"
            case .unixSocket(let socketPath):
                hostDescription = socketPath
            }
            return "\(self.scheme)://\(hostDescription) TLS-hash: \(hash)"
        }
    }
}
