// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "linkage-test",
    dependencies: [
        .package(name: "async-http-client", path: "../..")
    ],
    targets: [
        .executableTarget(
            name: "linkageTest",
            dependencies: [
                .product(name: "AsyncHTTPClient", package: "async-http-client")
            ]
        )
    ]
)
