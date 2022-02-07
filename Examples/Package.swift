// swift-tools-version:5.5
//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the AsyncHTTPClient project authors
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
    name: "async-http-client-examples",
    products: [
        .executable(name: "GetHTML", targets: ["GetHTML"]),
        .executable(name: "GetJSON", targets: ["GetJSON"]),
        .executable(name: "StreamingByteCounter", targets: ["StreamingByteCounter"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", .branch("main")),
        
        // in real-world projects this would be
        // .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.9.0")
        .package(name: "async-http-client", path: "../"),
    ],
    targets: [
        // MARK: - Examples
        .executableTarget(
            name: "GetHTML",
            dependencies: [
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "NIOCore", package: "swift-nio"),
            ], path: "GetHTML"
        ),
        .executableTarget(
            name: "GetJSON",
            dependencies: [
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
            ], path: "GetJSON"
        ),
        .executableTarget(
            name: "StreamingByteCounter",
            dependencies: [
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "NIOCore", package: "swift-nio"),
            ], path: "StreamingByteCounter"
        ),
    ]
)
