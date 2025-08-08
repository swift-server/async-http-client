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
import Foundation
import NIOCore
import NIOFoundationCompat

struct Comic: Codable {
    var num: Int
    var title: String
    var day: String
    var month: String
    var year: String
    var img: String
    var alt: String
    var news: String
    var link: String
    var transcript: String
}

@main
struct GetJSON {
    static func main() async throws {
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
        do {
            let request = HTTPClientRequest(url: "https://xkcd.com/info.0.json")
            let response = try await httpClient.execute(request, timeout: .seconds(30))
            print("HTTP head", response)
            let body = try await response.body.collect(upTo: 1024 * 1024)  // 1 MB
            // we use an overload defined in `NIOFoundationCompat` for `decode(_:from:)` to
            // efficiently decode from a `ByteBuffer`
            let comic = try JSONDecoder().decode(Comic.self, from: body)
            dump(comic)
        } catch {
            print("request failed:", error)
        }
        // it is important to shutdown the httpClient after all requests are done, even if one failed
        try await httpClient.shutdown()
    }
}
