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

#if $ExperimentalHTTPAPIsSupport
import AsyncHTTPClient
import HTTPAPIs
import HTTPClient
import HTTPClientConformance
internal import NIOPosix
import Testing

@Suite struct AsyncHTTPClientTests {
    @available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
    @Test func conformance() async throws {
        var config = HTTPClient.Configuration()
        config.connectionPool.concurrentHTTP1ConnectionsPerHostSoftLimit = 1
        config.httpVersion = .automatic
        let httpClient = HTTPClient(eventLoopGroup: .singletonMultiThreadedEventLoopGroup, configuration: config)
        defer { Task { try await httpClient.shutdown() } }

        try await runAllConformanceTests {
            httpClient
        }
    }
}

@available(macOS 26.2, *)
extension AsyncHTTPClient.HTTPClient.RequestOptions: HTTPClientCapability.RedirectionHandler {
    @available(macOS 26.2, *)
    public var redirectionHandler: (any HTTPClientRedirectionHandler)? {
        get {
            nil
        }
        set {

        }
    }
}
#endif
