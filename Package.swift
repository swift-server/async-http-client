// swift-tools-version:5.0
//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the AsyncHTTPClient project authors
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
    name: "async-http-client",
    products: [
        .library(name: "AsyncHTTPClient", targets: ["AsyncHTTPClient"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.8.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "AsyncHTTPClient",
            dependencies: ["NIO", "NIOHTTP1", "NIOSSL", "NIOConcurrencyHelpers", "NIOHTTPCompression"]
        ),
        .testTarget(
            name: "AsyncHTTPClientTests",
            dependencies: ["NIO", "NIOConcurrencyHelpers", "NIOSSL", "AsyncHTTPClient", "NIOFoundationCompat"]
        ),
    ]
)
