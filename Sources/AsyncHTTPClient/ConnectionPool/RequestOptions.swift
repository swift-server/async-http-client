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

import NIOCore

struct RequestOptions {
    /// The maximal `TimeAmount` that is allowed to pass between `channelRead`s from the Channel.
    var idleReadTimeout: TimeAmount?
    /// The maximal `TimeAmount` that is allowed to pass between `write`s into the Channel.
    var idleWriteTimeout: TimeAmount?
    /// The maximum time the request will wait for a usable connection to be established
    /// (TCP connect + TLS handshake) before giving up.
    var connectionCreationTimeout: TimeAmount
    /// DNS overrides.
    var dnsOverride: [String: String]
    /// The local IP address to bind outgoing connections to. This is typically used on multi-NIC
    /// systems where we want to control where traffic goes.
    var localAddress: String?

    init(
        idleReadTimeout: TimeAmount?,
        idleWriteTimeout: TimeAmount?,
        connectionCreationTimeout: TimeAmount,
        dnsOverride: [String: String],
        localAddress: String? = nil
    ) {
        self.idleReadTimeout = idleReadTimeout
        self.idleWriteTimeout = idleWriteTimeout
        self.connectionCreationTimeout = connectionCreationTimeout
        self.dnsOverride = dnsOverride
        self.localAddress = localAddress
    }
}

extension RequestOptions {
    static func fromClientConfiguration(_ configuration: HTTPClient.Configuration) -> Self {
        RequestOptions(
            idleReadTimeout: configuration.timeout.read,
            idleWriteTimeout: configuration.timeout.write,
            connectionCreationTimeout: configuration.timeout.connectionCreationTimeout,
            dnsOverride: configuration.dnsOverride,
            localAddress: configuration.localAddress
        )
    }

    /// Applies a per-request stall timeout that, when non-nil, replaces the connect, read, and
    /// write timeouts derived from the client configuration. A `nil` value is a no-op so the
    /// configured defaults stand.
    mutating func apply(stallTimeout: TimeAmount?) {
        guard let stallTimeout else { return }
        self.idleReadTimeout = stallTimeout
        self.idleWriteTimeout = stallTimeout
        self.connectionCreationTimeout = stallTimeout
    }
}
