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

import NIOSSL

/// Wrapper around `TLSConfiguration` from NIOSSL to provide a best effort implementation of `Hashable`
struct BestEffortHashableTLSConfiguration: Hashable {
    let base: TLSConfiguration

    init(wrapping base: TLSConfiguration) {
        self.base = base
    }

    func hash(into hasher: inout Hasher) {
        self.base.bestEffortHash(into: &hasher)
    }

    static func == (lhs: BestEffortHashableTLSConfiguration, rhs: BestEffortHashableTLSConfiguration) -> Bool {
        lhs.base.bestEffortEquals(rhs.base)
    }
}
