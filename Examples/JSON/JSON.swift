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

// Structure to match httpbin.org response format
struct HttpBinResponse: Codable {
    let json: Comic
    let url: String
    let headers: [String: String]
    let origin: String
    let data: String?
    let form: [String: String]?
    let files: [String: String]?
}

@main
struct JSON {

    static func main() async throws {
        try await getJSON()
        try await postJSON()
    }

    static func getJSON() async throws {
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

    static func postJSON() async throws {
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)

        let comic: Comic = Comic(
            num: 0,
            title: "Adventures of Super Sally",
            day: "17",
            month: "4",
            year: "2025",
            img: "https://www.w3.org/Icons/w3c_main.png",
            alt: "Adventures of Super Sally, a super hero with many powers",
            news: "Today we learn about super heroes!",
            link: "http://comics.com/super-sally",
            transcript: "Once upon a time, there was a super hero named Super Sally. She had many powers and was a hero to many."
        )

        do {
            var request = HTTPClientRequest(url: "https://httpbin.org/post")
            request.headers.add(name: "Content-Type", value: "application/json")
            request.headers.add(name: "Accept", value: "application/json")
            request.method = .POST

            let jsonData = try JSONEncoder().encode(comic)
            request.body = .bytes(jsonData)
            
            let response = try await httpClient.execute(request, timeout: .seconds(30))
            let responseBody = try await response.body.collect(upTo: 1024 * 1024)  // 1 MB
            // we use an overload defined in `NIOFoundationCompat` for `decode(_:from:)` to
            // efficiently decode from a `ByteBuffer`

            // httpbin.org returns a JSON response that wraps our posted data in a "json" field
            let httpBinResponse = try JSONDecoder().decode(HttpBinResponse.self, from: responseBody)
            let returnedComic = httpBinResponse.json
            
            // Verify the data matches what we sent
            assert(comic.title == returnedComic.title)
            assert(comic.img == returnedComic.img)
            assert(comic.alt == returnedComic.alt)
            assert(comic.day == returnedComic.day)
            assert(comic.month == returnedComic.month)
            assert(comic.year == returnedComic.year)
            assert(comic.num == returnedComic.num)
            assert(comic.transcript == returnedComic.transcript)
            assert(comic.news == returnedComic.news)
            assert(comic.link == returnedComic.link)
            dump(returnedComic)
        } catch {
            print("request failed:", error)
        }
        // it is important to shutdown the httpClient after all requests are done, even if one failed
        try await httpClient.shutdown()
    }
}
