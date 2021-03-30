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

import NIO
import NIOHTTP1

struct ResponseReadBuffer {
    private var responseParts: CircularBuffer<HTTPClientResponsePart>

    init() {
        self.responseParts = CircularBuffer(initialCapacity: 16)
    }

    mutating func appendPart(_ part: HTTPClientResponsePart) {
        self.responseParts.append(part)
    }

    mutating func nextRead() -> HTTPClientResponsePart? {
        return self.responseParts.popFirst()
    }
}
