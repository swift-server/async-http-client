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
#if canImport(Network)
import Network
#endif
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

final class ResponseDelayGetTests: XCTestCaseHTTPClientTestsBaseClass {
    func testResponseDelayGet() throws {
        let req = try HTTPClient.Request(url: self.defaultHTTPBinURLPrefix + "get",
                                         method: .GET,
                                         headers: ["X-internal-delay": "2000"],
                                         body: nil)
        let start = NIODeadline.now()
        let response = try self.defaultClient.execute(request: req).wait()
        XCTAssertGreaterThanOrEqual(.now() - start, .milliseconds(1_900 /* 1.9 seconds */ ))
        XCTAssertEqual(response.status, .ok)
    }
}
