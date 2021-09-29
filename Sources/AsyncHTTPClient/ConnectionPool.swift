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
    /// A key is initialized from a `URL`, it uses the components to derive a hashed value
    /// used by the `providers` dictionary to allow retrieving and creating
    /// connection providers associated to a certain request in constant time.
    struct Key: Hashable, CustomStringConvertible {
        init(_ request: HTTPClient.Request) {
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
            self.port = request.port
            self.host = request.host
            self.unixPath = request.socketPath
            if let tls = request.tlsConfiguration {
                self.tlsConfiguration = BestEffortHashableTLSConfiguration(wrapping: tls)
            }
        }

        var scheme: Scheme
        var host: String
        var port: Int
        var unixPath: String
        private var tlsConfiguration: BestEffortHashableTLSConfiguration?

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
            var path = ""
            if self.unixPath != "" {
                path = self.unixPath
            } else {
                path = "\(self.host):\(self.port)"
            }
            return "\(self.scheme)://\(path) TLS-hash: \(hash)"
        }
    }
}
