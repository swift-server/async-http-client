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

/// - Note: use `HTTPClientRequest.Body.Length` if you want to expose `RequestBodyLength` publicly
@usableFromInline
internal enum RequestBodyLength: Hashable, Sendable {
    /// size of the request body is not known before starting the request
    case unknown
    /// size of the request body is fixed and exactly `count` bytes
    case known(_ count: Int)
}
