//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the AsyncHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore

extension HTTPClient.Configuration {
    /// Proxy server configuration
    /// Specifies the remote address of an HTTP proxy.
    ///
    /// Adding an `Proxy` to your client's `HTTPClient.Configuration`
    /// will cause requests to be passed through the specified proxy using the
    /// HTTP `CONNECT` method.
    ///
    /// If a `TLSConfiguration` is used in conjunction with `HTTPClient.Configuration.Proxy`,
    /// TLS will be established _after_ successful proxy, between your client
    /// and the destination server.
    public struct Proxy: Sendable, Hashable {
        enum ProxyType: Hashable {
            case http(HTTPClient.Authorization?)
            case socks
        }

        /// Specifies Proxy server host.
        public var host: String
        /// Specifies Proxy server port.
        public var port: Int
        /// Specifies Proxy server authorization.
        public var authorization: HTTPClient.Authorization? {
            set {
                precondition(
                    self.type == .http(self.authorization),
                    "SOCKS authorization support is not yet implemented."
                )
                self.type = .http(newValue)
            }

            get {
                switch self.type {
                case .http(let authorization):
                    return authorization
                case .socks:
                    return nil
                }
            }
        }

        var type: ProxyType

        /// Create a HTTP proxy.
        ///
        /// - parameters:
        ///     - host: proxy server host.
        ///     - port: proxy server port.
        public static func server(host: String, port: Int) -> Proxy {
            .init(host: host, port: port, type: .http(nil))
        }

        /// Create a HTTP proxy.
        ///
        /// - parameters:
        ///     - host: proxy server host.
        ///     - port: proxy server port.
        ///     - authorization: proxy server authorization.
        public static func server(host: String, port: Int, authorization: HTTPClient.Authorization? = nil) -> Proxy {
            .init(host: host, port: port, type: .http(authorization))
        }

        /// Create a SOCKSv5 proxy.
        /// - parameter host: The SOCKSv5 proxy address.
        /// - parameter port: The SOCKSv5 proxy port, defaults to 1080.
        /// - returns: A new instance of `Proxy` configured to connect to a `SOCKSv5` server.
        public static func socksServer(host: String, port: Int = 1080) -> Proxy {
            .init(host: host, port: port, type: .socks)
        }
    }
}
