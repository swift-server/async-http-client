//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2024 Apple Inc. and the AsyncHTTPClient project authors
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
import ServiceContextModule

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension HTTPHeaders {
    mutating func propagate(_ context: ServiceContext) {
        InstrumentationSystem.instrument.inject(context, into: &self, using: Self.injector)
    }

    private static let injector = HTTPHeadersInjector()
}

private struct HTTPHeadersInjector: Injector {
    func inject(_ value: String, forKey name: String, into headers: inout HTTPHeaders) {
        headers.add(name: name, value: value)
    }
}
