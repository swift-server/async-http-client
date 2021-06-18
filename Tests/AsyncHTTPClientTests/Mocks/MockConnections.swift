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

class MockHTTPRequestTask: HTTPRequestTask {
    let eventLoopPreference: HTTPClient.EventLoopPreference
    let logger: Logger
    let connectionDeadline: NIODeadline
    let idleReadTimeout: TimeAmount?

    init(eventLoop: EventLoop,
         logger: Logger = Logger(label: "mock"),
         connectionTimeout: TimeAmount = .seconds(60),
         idleReadTimeout: TimeAmount? = nil,
         requiresEventLoopForChannel: Bool = false) {
        self.logger = logger

        self.connectionDeadline = .now() + connectionTimeout
        self.idleReadTimeout = idleReadTimeout

        if requiresEventLoopForChannel {
            self.eventLoopPreference = .delegateAndChannel(on: eventLoop)
        } else {
            self.eventLoopPreference = .delegate(on: eventLoop)
        }
    }

    var eventLoop: EventLoop {
        switch self.eventLoopPreference.preference {
        case .indifferent, .testOnly_exact:
            preconditionFailure("Unimplemented")
        case .delegate(on: let eventLoop), .delegateAndChannel(on: let eventLoop):
            return eventLoop
        }
    }

    func requestWasQueued(_: HTTP1RequestQueuer) {
        preconditionFailure("Unimplemented")
    }

    func willBeExecutedOnConnection(_: HTTPConnectionPool.Connection) {
        preconditionFailure("Unimplemented")
    }

    func willExecuteRequest(_: HTTP1RequestExecutor) -> Bool {
        preconditionFailure("Unimplemented")
    }

    func requestHeadSent(_: HTTPRequestHead) {
        preconditionFailure("Unimplemented")
    }

    func startRequestBodyStream() {
        preconditionFailure("Unimplemented")
    }

    func pauseRequestBodyStream() {
        preconditionFailure("Unimplemented")
    }

    func resumeRequestBodyStream() {
        preconditionFailure("Unimplemented")
    }

    var request: HTTPClient.Request {
        preconditionFailure("Unimplemented")
    }

    func nextRequestBodyPart(channelEL: EventLoop) -> EventLoopFuture<IOData?> {
        preconditionFailure("Unimplemented")
    }

    func didSendRequestHead(_: HTTPRequestHead) {
        preconditionFailure("Unimplemented")
    }

    func didSendRequestPart(_: IOData) {
        preconditionFailure("Unimplemented")
    }

    func didSendRequest() {
        preconditionFailure("Unimplemented")
    }

    func receiveResponseHead(_: HTTPResponseHead) {
        preconditionFailure("Unimplemented")
    }

    func receiveResponseBodyPart(_: ByteBuffer) {
        preconditionFailure("Unimplemented")
    }

    func receiveResponseEnd() {
        preconditionFailure("Unimplemented")
    }

    func fail(_: Error) {
        preconditionFailure("Unimplemented")
    }
}
