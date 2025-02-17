//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2025 Apple Inc. and the AsyncHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import AsyncHTTPClient
import NIO
import NIOFoundationCompat
import NIOHTTP1
import XCTest

final class HTTPClientStructuredConcurrencyTests: XCTestCase {
    func testDoNothingWorks() async throws {
        let actual = try await HTTPClient.withHTTPClient { httpClient in
            "OK"
        }
        XCTAssertEqual("OK", actual)
    }

    func testShuttingDownTheClientInBodyLeadsToError() async {
        do {
            let actual = try await HTTPClient.withHTTPClient { httpClient in
                try await httpClient.shutdown()
                return "OK"
            }
            XCTFail("Expected error, got \(actual)")
        } catch let error as HTTPClientError where error == .alreadyShutdown {
            // OK
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testBasicRequest() async throws {
        let httpBin = HTTPBin()
        defer { XCTAssertNoThrow(try httpBin.shutdown()) }

        let actualBytes = try await HTTPClient.withHTTPClient { httpClient in
            let response = try await httpClient.get(url: httpBin.baseURL).get()
            XCTAssertEqual(response.status, .ok)
            return response.body ?? ByteBuffer(string: "n/a")
        }
        let actual = try JSONDecoder().decode(RequestInfo.self, from: actualBytes)

        XCTAssertGreaterThanOrEqual(actual.requestNumber, 0)
        XCTAssertGreaterThanOrEqual(actual.connectionNumber, 0)
    }

    func testClientIsShutDownAfterReturn() async throws {
        let leakedClient = try await HTTPClient.withHTTPClient { httpClient in
            httpClient
        }
        do {
            try await leakedClient.shutdown()
            XCTFail("unexpected, shutdown should have failed")
        } catch let error as HTTPClientError where error == .alreadyShutdown {
            // OK
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testClientIsShutDownOnThrowAlso() async throws {
        struct TestError: Error {
            var httpClient: HTTPClient
        }

        let leakedClient: HTTPClient
        do {
            try await HTTPClient.withHTTPClient { httpClient in
                throw TestError(httpClient: httpClient)
            }
            XCTFail("unexpected, shutdown should have failed")
            return
        } catch let error as TestError {
            // OK
            leakedClient = error.httpClient
        } catch {
            XCTFail("unexpected error: \(error)")
            return
        }

        do {
            try await leakedClient.shutdown()
            XCTFail("unexpected, shutdown should have failed")
        } catch let error as HTTPClientError where error == .alreadyShutdown {
            // OK
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
