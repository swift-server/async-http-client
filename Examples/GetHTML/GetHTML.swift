//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2022 Apple Inc. and the AsyncHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

// TODO: remove @testable after async/await API is public
@testable import AsyncHTTPClient
import NIOCore

#if compiler(>=5.5.2) && canImport(_Concurrency)

@main
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
struct GetHTML {
    static func main() async throws {
        let httpClient = HTTPClient(eventLoopGroupProvider: .createNew)
        do {
            let request = HTTPClientRequest(url: "https://apple.com")
            let response = try await httpClient.execute(request, timeout: .seconds(30))
            print("HTTP head", response)
            let body = try await response.body.collect(upTo: 1024 * 1024) // 1 MB
            print(String(buffer: body))
        } catch {
            print("request failed:", error)
        }
        // it is important to shutdown the httpClient after all requests are done, even if one failed
        try await httpClient.shutdown()
    }
}

#endif
