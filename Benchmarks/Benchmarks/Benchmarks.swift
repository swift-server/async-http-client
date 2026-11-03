//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2026 Apple Inc. and the AsyncHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Benchmark
import NIOCore
import NIOHTTP1

let benchmarks: @Sendable () -> Void = {
    let configuration = Benchmark.Configuration(
        metrics: [
            .wallClock, .cpuTotal, .instructions, .mallocCountTotal,
            .syscalls, .contextSwitches, .readSyscalls, .writeSyscalls,
        ],
        scalingFactor: .kilo,
        maxDuration: .seconds(10),
        maxIterations: 10,
        thresholds: [
            .mallocCountTotal: .init(relative: [.p90: 0.5]),
            .readSyscalls: .init(relative: [.p90: 5]),
            .writeSyscalls: .init(relative: [.p90: 5]),
        ]
    )

    Benchmark("Echo512B", configuration: configuration) { benchmark in
        try await benchmark.measureRequests(.POST, "/echo", body: ByteBuffer(repeating: UInt8(ascii: "a"), count: 512))
    }

    Benchmark("Download512B", configuration: configuration) { benchmark in
        try await benchmark.measureRequests(.GET, "/download/512")
    }

    Benchmark("Upload250B", configuration: configuration) { benchmark in
        try await benchmark.measureRequests(
            .POST,
            "/upload",
            body: ByteBuffer(repeating: UInt8(ascii: "a"), count: 250)
        )
    }

    Benchmark("NewConnection", configuration: configuration) { benchmark in
        try await benchmark.measureRequests(.GET, "/download/512", reusingConnection: false)
    }
}
