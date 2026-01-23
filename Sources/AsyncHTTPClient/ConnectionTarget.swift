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

enum ConnectionTarget: Equatable, Hashable {
    // We keep the IP address serialization precisely as it is in the URL.
    // Some platforms have quirks in their implementations of 'ntop', for example
    // writing IPv6 addresses as having embedded IPv4 sections (e.g. [::192.168.0.1] vs [::c0a8:1]).
    // This serialization includes square brackets, so it is safe to write next to a port number.
    // Note: `address` must have an explicit port.
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

extension ConnectionTarget {
    /// The host name which will be send as an HTTP `Host` header.
    /// Only returns nil if the `self` is a `unixSocket`.
    var host: String? {
        switch self {
        case .ipAddress(let serialization, _): return serialization
        case .domain(let name, _): return name
        case .unixSocket: return nil
        }
    }

    /// The host name which will be send as an HTTP host header.
    /// Only returns nil if the `self` is a `unixSocket`.
    var port: Int? {
        switch self {
        case .ipAddress(_, let address): return address.port!
        case .domain(_, let port): return port
        case .unixSocket: return nil
        }
    }
}
