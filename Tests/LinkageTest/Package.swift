// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "linkage-test",
    platforms: [
        .macOS(.v10_15), .macCatalyst(.v13), .iOS(.v13), .tvOS(.v13), .watchOS(.v6), .visionOS(.v1)
    ],
    dependencies: [
        .package(name: "swift-async-http-client", path: "../.."),
        // Disable all traits from Configuration to prevent linking Foundation
        .package(url: "https://github.com/apple/swift-configuration.git", from: "1.0.0", traits: []),
    ],
    targets: [
        .executableTarget(
            name: "linkageTest",
            dependencies: [
                .product(name: "AsyncHTTPClient", package: "swift-async-http-client")
            ]
        )
    ]
)