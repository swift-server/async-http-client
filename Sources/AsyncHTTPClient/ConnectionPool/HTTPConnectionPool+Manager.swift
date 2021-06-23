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

import NIOConcurrencyHelpers

extension HTTPConnectionPool.Connection.ID {
    static var globalGenerator = Generator()

    struct Generator {
        private let atomic: NIOAtomic<Int>

        init() {
            self.atomic = .makeAtomic(value: 0)
        }

        func next() -> Int {
            return self.atomic.add(1)
        }
    }
}
