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

public struct RequestBodyLength {
    /// size of the request body is not known before starting the request
    public static let dynamic: Self = .init(storage: .dynamic)
    /// size of the request body is fixed and exactly `count` bytes
    public static func fixed(_ count: Int) -> Self {
        .init(storage: .fixed(count))
    }
    internal enum Storage: Hashable {
        case dynamic
        case fixed(_ count: Int)
    }
    internal var storage: Storage
}
