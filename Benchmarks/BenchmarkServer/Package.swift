// swift-tools-version:6.4
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

import PackageDescription

let package = Package(
    name: "benchmark-server",
    platforms: [
        .macOS("27")
    ],
    products: [
        .executable(name: "benchmark-server", targets: ["BenchmarkServer"])
    ],
    dependencies: [
        .package(url: "https://github.com/swift-server/swift-http-server.git", .upToNextMinor(from: "0.4.0")),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.4.0"),
        // swift-async-algorithms 1.1.5, which swift-http-server uses, doesn't build on macOS with swift-collections 1.7.
        .package(url: "https://github.com/apple/swift-collections.git", .upToNextMinor(from: "1.6.0")),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.19.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"6.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "BenchmarkServer",
            dependencies: [
                .product(name: "NIOHTTPServer", package: "swift-http-server"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "BasicContainers", package: "swift-collections"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        )
    ]
)
