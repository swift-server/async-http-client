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
    platforms: [.iOS(.v12), .tvOS(.v12)],
    products: [
        .library(name: "AsyncHTTPClient", targets: ["AsyncHTTPClient"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.13.1"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.4.1"),
        .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.3.0"),
        .package(url: "https://github.com/adam-fowler/swift-nio-transport-services.git", .branch("master")),
    ],
    targets: [
        .target(
            name: "AsyncHTTPClient",
            dependencies: ["NIO", "NIOHTTP1", "NIOSSL", "NIOConcurrencyHelpers", "NIOHTTPCompression", "NIOFoundationCompat", "NIOTransportServices"]
        ),
        .testTarget(
            name: "AsyncHTTPClientTests",
            dependencies: ["NIO", "NIOConcurrencyHelpers", "NIOSSL", "AsyncHTTPClient", "NIOFoundationCompat", "NIOTestUtils"]
        ),
    ]
)
