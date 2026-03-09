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
    /// DNS overrides.
    var dnsOverride: [String: String]
    /// The local IP address to bind outgoing connections to.
    var localAddress: String?

    init(
        idleReadTimeout: TimeAmount?,
        idleWriteTimeout: TimeAmount?,
        dnsOverride: [String: String],
        localAddress: String? = nil
    ) {
        self.idleReadTimeout = idleReadTimeout
        self.idleWriteTimeout = idleWriteTimeout
        self.dnsOverride = dnsOverride
        self.localAddress = localAddress
    }
}

extension RequestOptions {
    static func fromClientConfiguration(_ configuration: HTTPClient.Configuration) -> Self {
        RequestOptions(
            idleReadTimeout: configuration.timeout.read,
            idleWriteTimeout: configuration.timeout.write,
            dnsOverride: configuration.dnsOverride,
            localAddress: configuration.localAddress
        )
    }
}
