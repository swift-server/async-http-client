//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2021 Apple Inc. and the AsyncHTTPClient project authors
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
import NIOHTTP1
import XCTest

class MockRequestDelegate: HTTPClientResponseDelegate {
    typealias Response = HTTPClient.Response

    private(set) var didSendRequestHeadCount = 0
    private(set) var didSendRequestPartCount = 0
    private(set) var didSendRequestCount = 0

    func didSendRequestHead(task: HTTPClient.Task<HTTPClient.Response>, _ head: HTTPRequestHead) {
        self.didSendRequestHeadCount += 1
    }

    func didSendRequestPart(task: HTTPClient.Task<HTTPClient.Response>, _ part: IOData) {
        self.didSendRequestPartCount += 1
    }

    func didSendRequest(task: HTTPClient.Task<HTTPClient.Response>) {
        self.didSendRequestCount += 1
    }

    func didFinishRequest(task: HTTPClient.Task<HTTPClient.Response>) throws -> HTTPClient.Response {
        HTTPClient.Response(host: "localhost", status: .ok, version: .http1_1, headers: .init(), body: nil)
    }
}
