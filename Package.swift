// swift-tools-version:5.6
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
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.50.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.22.0"),
        .package(url: "https://github.com/apple/swift-nio-http2.git", from: "1.19.0"),
        .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.13.0"),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.11.4"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.4.4"),
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.0.2"),
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.0.0"),
    ],
    targets: [
        .target(name: "CAsyncHTTPClient"),
        .target(
            name: "AsyncHTTPClient",
            dependencies: [
                .target(name: "CAsyncHTTPClient"),
                .product(name: "NIO", package: "swift-nio"),
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
            ]
        ),
        .testTarget(
            name: "AsyncHTTPClientTests",
            dependencies: [
                .target(name: "AsyncHTTPClient"),
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
