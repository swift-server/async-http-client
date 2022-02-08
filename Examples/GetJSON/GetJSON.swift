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
import Foundation
import NIOCore
import NIOFoundationCompat

#if compiler(>=5.5.2) && canImport(_Concurrency)

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
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
struct GetJSON {
    static func main() async throws {
        let httpClient = HTTPClient(eventLoopGroupProvider: .createNew)
        do {
            let request = HTTPClientRequest(url: "https://xkcd.com/info.0.json")
            let response = try await httpClient.execute(request, timeout: .seconds(30))
            print("HTTP head", response)
            let body = try await response.body.collect(upTo: 1024 * 1024) // 1 MB
            let comic = try JSONDecoder().decode(Comic.self, from: body)
            dump(comic)
        } catch {
            print("request failed:", error)
        }
        // it is important to shutdown the httpClient after all requests are done, even if one failed
        try await httpClient.shutdown()
    }
}

#endif
