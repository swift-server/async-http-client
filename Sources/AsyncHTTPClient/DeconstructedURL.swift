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

import struct Foundation.URL

struct DeconstructedURL {
    var scheme: Scheme
    var connectionTarget: ConnectionTarget
    var uri: String

    init(
        scheme: Scheme,
        connectionTarget: ConnectionTarget,
        uri: String
    ) {
        self.scheme = scheme
        self.connectionTarget = connectionTarget
        self.uri = uri
    }
}

extension DeconstructedURL {
    init(url: String) throws {
        guard let url = URL(string: url) else {
            throw HTTPClientError.invalidURL
        }
        try self.init(url: url)
    }

    init(url: URL) throws {
        guard let schemeString = url.scheme else {
            throw HTTPClientError.emptyScheme
        }
        guard let scheme = Scheme(rawValue: schemeString.lowercased()) else {
            throw HTTPClientError.unsupportedScheme(schemeString)
        }

        switch scheme {
        case .http, .https:
            #if !canImport(Darwin)
            guard let urlHost = url.host, !urlHost.isEmpty else {
                throw HTTPClientError.emptyHost
            }
            let host = urlHost.trimIPv6Brackets()
            #else
            guard let host = url.host, !host.isEmpty else {
                throw HTTPClientError.emptyHost
            }
            #endif
            self.init(
                scheme: scheme,
                connectionTarget: .init(remoteHost: host, port: url.port ?? scheme.defaultPort),
                uri: url.uri
            )

        case .httpUnix, .httpsUnix:
            guard let socketPath = url.host, !socketPath.isEmpty else {
                throw HTTPClientError.missingSocketPath
            }
            self.init(
                scheme: scheme,
                connectionTarget: .unixSocket(path: socketPath),
                uri: url.uri
            )

        case .unix:
            let socketPath = url.baseURL?.path ?? url.path
            let uri = url.baseURL != nil ? url.uri : "/"
            guard !socketPath.isEmpty else {
                throw HTTPClientError.missingSocketPath
            }
            self.init(
                scheme: scheme,
                connectionTarget: .unixSocket(path: socketPath),
                uri: uri
            )
        }
    }
}

#if !canImport(Darwin)
extension String {
    @inlinable internal func trimIPv6Brackets() -> String {
        var utf8View = self.utf8[...]

        var modified = false
        if utf8View.first == UInt8(ascii: "[") {
            utf8View = utf8View.dropFirst()
            modified = true
        }
        if utf8View.last == UInt8(ascii: "]") {
            utf8View = utf8View.dropLast()
            modified = true
        }

        if modified {
            return String(Substring(utf8View))
        }
        return self
    }
}
#endif
