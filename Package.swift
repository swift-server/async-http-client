// swift-tools-version:5.8
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
        .library(name: "AsyncHTTPClient", targets: ["AsyncHTTPClient"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.71.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.1"),
        .package(url: "https://github.com/apple/swift-nio-http2.git", from: "1.19.0"),
        .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.13.0"),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.19.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.4.4"),
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.0.2"),
        .package(url: "https://github.com/apple/swift-algorithms.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "CAsyncHTTPClient",
            cSettings: [
                .define("_GNU_SOURCE")
            ]
        ),
        .target(
            name: "AsyncHTTPClient",
            dependencies: [
                .target(name: "CAsyncHTTPClient"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOTLS", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOHTTP2", package: "swift-nio-http2"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "NIOHTTPCompression", package: "swift-nio-extras"),
                .product(name: "NIOSOCKS", package: "swift-nio-extras"),
                .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Atomics", package: "swift-atomics"),
                .product(name: "Algorithms", package: "swift-algorithms"),
            ]
        ),
        .testTarget(
            name: "AsyncHTTPClientTests",
            dependencies: [
                .target(name: "AsyncHTTPClient"),
                .product(name: "NIOTLS", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOTestUtils", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "NIOHTTP2", package: "swift-nio-http2"),
                .product(name: "NIOSOCKS", package: "swift-nio-extras"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Atomics", package: "swift-atomics"),
                .product(name: "Algorithms", package: "swift-algorithms"),
            ],
            resources: [
                .copy("Resources/self_signed_cert.pem"),
                .copy("Resources/self_signed_key.pem"),
                .copy("Resources/example.com.cert.pem"),
                .copy("Resources/example.com.private-key.pem"),
            ]
        ),
    ]
)

// ---    STANDARD CROSS-REPO SETTINGS DO NOT EDIT   --- //
for target in package.targets {
    if target.type != .plugin {
        var settings = target.swiftSettings ?? []
        // https://github.com/swiftlang/swift-evolution/blob/main/proposals/0444-member-import-visibility.md
        settings.append(.enableUpcomingFeature("MemberImportVisibility"))
        target.swiftSettings = settings
    }
}
// --- END: STANDARD CROSS-REPO SETTINGS DO NOT EDIT --- //
