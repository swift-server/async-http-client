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

import Foundation

struct Endpoint {
    enum Scheme: String {
        case http
        case https
        case unix
        case httpUnix = "http+unix"
        case httpsUnix = "https+unix"
    }
    let scheme: Scheme
    let host: String
    let socketPath: String
    let port: Int
    let uri: String
    init(url: URL) throws {
        guard let schemeString = url.scheme else {
            throw HTTPClientError.emptyScheme
        }
        guard let scheme = Scheme(rawValue: schemeString.lowercased()) else {
            throw HTTPClientError.unsupportedScheme(schemeString)
        }
        self.scheme = scheme
        self.port = url.port ?? scheme.defaultPort
        switch scheme {
        case .http, .https:
            guard let host = url.host, !host.isEmpty else {
                throw HTTPClientError.emptyHost
            }
            self.host = host
            self.uri = url.uri
            self.socketPath = ""
            
        case .httpUnix, .httpsUnix:
            guard let socketPath = url.host, !socketPath.isEmpty else {
                throw HTTPClientError.missingSocketPath
            }
            self.host = ""
            self.uri = url.uri
            self.socketPath = socketPath
            
        case .unix:
            let socketPath = url.baseURL?.path ?? url.path
            let uri = url.baseURL != nil ? url.uri : "/"
            guard !socketPath.isEmpty else {
                throw HTTPClientError.missingSocketPath
            }
            self.host = ""
            self.uri = uri
            self.socketPath = socketPath
        }
    }
}

extension Endpoint.Scheme {
    var useTLS: Bool {
        switch self {
        case .http, .httpUnix, .unix:
            return false
        case .https, .httpsUnix:
            return true
        }
    }
    var defaultPort: Int {
        useTLS ? 443 : 80
    }
}
