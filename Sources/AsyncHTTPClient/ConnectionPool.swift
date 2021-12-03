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

import NIOSSL

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

        init(
            scheme: Scheme,
            connectionTarget: ConnectionTarget,
            tlsConfiguration: BestEffortHashableTLSConfiguration? = nil
        ) {
            self.scheme = scheme
            self.connectionTarget = connectionTarget
            self.tlsConfiguration = tlsConfiguration
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

extension ConnectionPool.Key {
    init(url: DeconstructedURL, tlsConfiguration: TLSConfiguration?) {
        self.init(
            scheme: url.scheme,
            connectionTarget: url.connectionTarget,
            tlsConfiguration: tlsConfiguration.map {
                BestEffortHashableTLSConfiguration(wrapping: $0)
            }
        )
    }

    init(_ request: HTTPClient.Request) {
        self.init(
            url: request.deconstructedURL,
            tlsConfiguration: request.tlsConfiguration
        )
    }
}
