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

    var dnsOverride: [String: String]

    init(idleReadTimeout: TimeAmount?, dnsOverride: [String: String]) {
        self.idleReadTimeout = idleReadTimeout
        self.dnsOverride = dnsOverride
    }
}

extension RequestOptions {
    static func fromClientConfiguration(_ configuration: HTTPClient.Configuration) -> Self {
        RequestOptions(
            idleReadTimeout: configuration.timeout.read,
            dnsOverride: configuration.dnsOverride
        )
    }
}
