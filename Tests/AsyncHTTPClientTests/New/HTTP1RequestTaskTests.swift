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

@testable import AsyncHTTPClient
import Logging
import NIO
import NIOHTTP1
import XCTest

class HTTPRequestTaskTests: XCTestCase {
    func testWrapperOfAwesomeness() {
//        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 2)
//        let channelEventLoop = elg.next()
//        let delegateEventLoop = elg.next()
//        let logger = Logger(label: "test")
//
//        let request = try! HTTPClient.Request(
//            url: "http://localhost/",
//            method: .POST, headers: HTTPHeaders([("content-length", "4")]),
//            body: .stream({ writer -> EventLoopFuture<Void> in
//                func recursive(count: UInt8, promise: EventLoopPromise<Void>) {
//                    writer.write(.byteBuffer(ByteBuffer(bytes: [count]))).whenComplete { result in
//                        switch result {
//                        case .failure(let error):
//                            XCTFail("Unexpected error: \(error)")
//                        case .success:
//                            guard count < 4 else {
//                                return promise.succeed(())
//                            }
//                            recursive(count: count + 1, promise: promise)
//                        }
//                    }
//                }
//
//                let promise = channelEventLoop.makePromise(of: Void.self)
//                recursive(count: 0, promise: promise)
//                return promise.futureResult
//            }))
//
//
//        let task = HTTPClient.Task<HTTPClient.Response>(eventLoop: channelEventLoop, logger: logger)
//
//        let wrapper = RequestBag(
//            request: request,
//            eventLoopPreference: .delegate(on: delegateEventLoop),
//            task: task,
//            connectionDeadline: .now() + .seconds(60),
//            delegate: MockRequestDelegate())
//
//        XCTAssertNoThrow(try task.futureResult.wait())
    }
}
