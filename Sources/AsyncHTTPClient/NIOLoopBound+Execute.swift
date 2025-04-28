//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2025 Apple Inc. and the AsyncHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore

extension NIOLoopBound {
    @inlinable
    func execute(_ body: @Sendable @escaping (Value) -> Void) {
        if self.eventLoop.inEventLoop {
            body(self.value)
        } else {
            self.eventLoop.execute {
                body(self.value)
            }
        }
    }
}
