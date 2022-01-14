//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2020 Apple Inc. and the AsyncHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Instrumentation
import NIOHTTP1

/// Injects values into `NIOHTTP1.HTTPHeaders`.
struct HTTPHeadersInjector: Injector {
    init() {}

    func inject(_ value: String, forKey key: String, into headers: inout HTTPHeaders) {
        headers.replaceOrAdd(name: key, value: value)
    }
}
