// swift-tools-version:6.0
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

let strictConcurrencyDevelopment = false

let strictConcurrencySettings: [SwiftSetting] = {
    var initialSettings: [SwiftSetting] = []

    if strictConcurrencyDevelopment {
        // -warnings-as-errors here is a workaround so that IDE-based development can
        // get tripped up on -require-explicit-sendable.
        initialSettings.append(.unsafeFlags(["-Xfrontend", "-require-explicit-sendable", "-warnings-as-errors"]))
    }

    return initialSettings
}()

let package = Package(
    name: "async-http-client",
    products: [
        .library(name: "AsyncHTTPClient", targets: ["AsyncHTTPClient"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.30.0"),
        .package(url: "https://github.com/apple/swift-nio-http2.git", from: "1.36.0"),
        .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.26.0"),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.24.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.7.1"),
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.0.2"),
        .package(url: "https://github.com/apple/swift-algorithms.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-distributed-tracing.git", from: "1.3.0"),
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
                .product(name: "Atomics", package: "swift-atomics"),
                .product(name: "Algorithms", package: "swift-algorithms"),
                // Observability support
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Tracing", package: "swift-distributed-tracing"),
            ],
            swiftSettings: strictConcurrencySettings
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
                .product(name: "Atomics", package: "swift-atomics"),
                .product(name: "Algorithms", package: "swift-algorithms"),
                // Observability support
                .product(name: "Logging", package: "swift-log"),
                .product(name: "InMemoryLogging", package: "swift-log"),
                .product(name: "Tracing", package: "swift-distributed-tracing"),
                .product(name: "InMemoryTracing", package: "swift-distributed-tracing"),
            ],
            resources: [
                .copy("Resources/self_signed_cert.pem"),
                .copy("Resources/self_signed_key.pem"),
                .copy("Resources/example.com.cert.pem"),
                .copy("Resources/example.com.private-key.pem"),
            ],
            swiftSettings: strictConcurrencySettings
        ),
    ]
)

// ---    STANDARD CROSS-REPO SETTINGS DO NOT EDIT   --- //
for target in package.targets {
    switch target.type {
    case .regular, .test, .executable:
        var settings = target.swiftSettings ?? []
        // https://github.com/swiftlang/swift-evolution/blob/main/proposals/0444-member-import-visibility.md
        settings.append(.enableUpcomingFeature("MemberImportVisibility"))
        target.swiftSettings = settings
    case .macro, .plugin, .system, .binary:
        ()  // not applicable
    @unknown default:
        ()  // we don't know what to do here, do nothing
    }
}
// --- END: STANDARD CROSS-REPO SETTINGS DO NOT EDIT --- //
