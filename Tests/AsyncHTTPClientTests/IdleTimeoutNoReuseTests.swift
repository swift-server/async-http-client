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

final class TestIdleTimeoutNoReuse: XCTestCaseHTTPClientTestsBaseClass {
    func testIdleTimeoutNoReuse() throws {
        var req = try HTTPClient.Request(url: self.defaultHTTPBinURLPrefix + "get", method: .GET)
        XCTAssertNoThrow(try self.defaultClient.execute(request: req, deadline: .now() + .seconds(2)).wait())
        req.headers.add(name: "X-internal-delay", value: "2500")
        try self.defaultClient.eventLoopGroup.next().scheduleTask(in: .milliseconds(250)) {}.futureResult.wait()
        XCTAssertNoThrow(try self.defaultClient.execute(request: req).timeout(after: .seconds(10)).wait())
    }
}
