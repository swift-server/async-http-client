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

import AsyncHTTPClient
import NIOCore

@main
struct StreamingByteCounter {
    static func main() async throws {
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
        do {
            let request = HTTPClientRequest(url: "https://apple.com")
            let response = try await httpClient.execute(request, timeout: .seconds(30))
            print("HTTP head", response)

            // if defined, the content-length headers announces the size of the body
            let expectedBytes = response.headers.first(name: "content-length").flatMap(Int.init)

            var receivedBytes = 0
            // asynchronously iterates over all body fragments
            // this loop will automatically propagate backpressure correctly
            for try await buffer in response.body {
                // For this example, we are just interested in the size of the fragment
                receivedBytes += buffer.readableBytes

                if let expectedBytes = expectedBytes {
                    // if the body size is known, we calculate a progress indicator
                    let progress = Double(receivedBytes) / Double(expectedBytes)
                    print("progress: \(Int(progress * 100))%")
                }
            }
            print("did receive \(receivedBytes) bytes")
        } catch {
            print("request failed:", error)
        }
        // it is important to shutdown the httpClient after all requests are done, even if one failed
        try await httpClient.shutdown()
    }
}
