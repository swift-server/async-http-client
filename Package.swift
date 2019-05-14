// swift-tools-version:5.0
//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIOHTTPClient open source project
//
// Copyright (c) 2018-2019 Swift Server Working Group and the SwiftNIOHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIOHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import PackageDescription

let package = Package(
    name: "swift-nio-http-client",
    products: [
        .library(name: "NIOHTTPClient", targets: ["NIOHTTPClient"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-nio-http2.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "NIOHTTPClient",
            dependencies: ["NIO", "NIOHTTP1", "NIOHTTP2", "NIOSSL", "NIOConcurrencyHelpers"]
        ),
        .testTarget(
            name: "NIOHTTPClientTests",
            dependencies: ["NIOHTTPClient", "NIOFoundationCompat"]
        ),
    ]
)
