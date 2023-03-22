//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2023 Apple Inc. and the AsyncHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//



@testable import AsyncHTTPClient
import Logging
import NIOCore
import XCTest


private func makeDefaultHTTPClient(
    eventLoopGroupProvider: HTTPClient.EventLoopGroupProvider = .createNew
) -> HTTPClient {
    var config = HTTPClient.Configuration()
    config.tlsConfiguration = .clientDefault
    config.tlsConfiguration?.certificateVerification = .none
    config.httpVersion = .automatic
    return HTTPClient(
        eventLoopGroupProvider: eventLoopGroupProvider,
        configuration: config,
        backgroundActivityLogger: Logger(label: "HTTPClient", factory: StreamLogHandler.standardOutput(label:))
    )
}

final class HTTPClientResponseTests: XCTestCase {

    func testSimpleResponse() {
        let response = HTTPClientResponse.expectedContentLength(requestMethod: .GET, headers: ["content-length": "1025"], status: .ok)
        XCTAssertEqual(response, 1025)
    }

    func testSimpleResponseNotModified() {
        let response = HTTPClientResponse.expectedContentLength(requestMethod: .GET, headers: ["content-length": "1025"], status: .notModified)
        XCTAssertEqual(response, 0)
    }

    func testSimpleResponseHeadRequestMethod() {
        let response = HTTPClientResponse.expectedContentLength(requestMethod: .HEAD, headers: ["content-length": "1025"], status: .ok)
        XCTAssertEqual(response, 0)
    }

    func testReponseInitWithStatus() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest {
            var response = HTTPClientResponse(status: .notModified , requestMethod: .GET)
            response.headers.replaceOrAdd(name: "content-length", value: "1025")
            guard let body = await XCTAssertNoThrowWithResult(
                try await response.body.collect(upTo: 1024)
            ) else { return }
            XCTAssertEqual(0, body.readableBytes)
        }
    }
}
