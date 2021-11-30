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

        init(_ request: HTTPClient.Request) {
            self.connectionTarget = request.connectionTarget
            switch request.scheme {
            case "http":
                self.scheme = .http
            case "https":
                self.scheme = .https
            case "unix":
                self.scheme = .unix
            case "http+unix":
                self.scheme = .http_unix
            case "https+unix":
                self.scheme = .https_unix
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
            let hostDescription: String
            switch self.connectionTarget {
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
