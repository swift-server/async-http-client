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
import Atomics
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOFoundationCompat
import NIOHTTP1
import NIOHTTPCompression
import NIOPosix
import NIOSSL
import NIOTestUtils
import NIOTransportServices
import XCTest

#if canImport(Network)
import Network
#endif

final class NoBytesSentOverBodyLimitTests: XCTestCaseHTTPClientTestsBaseClass {
    func testNoBytesSentOverBodyLimit() throws {
        let server = NIOHTTP1TestServer(group: self.serverGroup)
        defer {
            XCTAssertNoThrow(try server.stop())
        }

        let tooLong = "XBAD BAD BAD NOT HTTP/1.1\r\n\r\n"

        let request = try Request(
            url: "http://localhost:\(server.serverPort)",
            body: .stream(contentLength: 1) { streamWriter in
                streamWriter.write(.byteBuffer(ByteBuffer(string: tooLong)))
            }
        )

        let future = self.defaultClient.execute(request: request)

        // Okay, what happens here needs an explanation:
        //
        // In the request state machine, we should start the request, which will lead to an
        // invocation of `context.write(HTTPRequestHead)`. Since we will receive a streamed request
        // body a `context.flush()` will be issued. Further the request stream will be started.
        // Since the request stream immediately produces to much data, the request will be failed
        // and the connection will be closed.
        //
        // Even though a flush was issued after the request head, there is no guarantee that the
        // request head was written to the network. For this reason we must accept not receiving a
        // request and receiving a request head.

        do {
            _ = try server.receiveHead()

            // A request head was sent. We expect the request now to fail with a parsing error,
            // since the client ended the connection to early (from the server's point of view.)
            XCTAssertThrowsError(try server.readInbound()) {
                XCTAssertEqual($0 as? HTTPParserError, HTTPParserError.invalidEOFState)
            }
        } catch {
            // TBD: We sadly can't verify the error type, since it is private in `NIOTestUtils`:
            //      NIOTestUtils.BlockingQueue<Element>.TimeoutError
        }

        // request must always be failed with this error
        XCTAssertThrowsError(try future.wait()) {
            XCTAssertEqual($0 as? HTTPClientError, .bodyLengthMismatch)
        }
    }
}
