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

import Logging
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOHTTP2

@testable import AsyncHTTPClient

extension EmbeddedChannel {
    public func receiveHeadAndVerify(_ verify: (HTTPRequestHead) throws -> Void = { _ in }) throws {
        let part = try self.readOutbound(as: HTTPClientRequestPart.self)
        switch part {
        case .head(let head):
            try verify(head)
        case .body, .end:
            throw HTTP1EmbeddedChannelError(reason: "Expected .head but got '\(part!)'")
        case .none:
            throw HTTP1EmbeddedChannelError(reason: "Nothing in buffer")
        }
    }

    public func receiveBodyAndVerify(_ verify: (IOData) throws -> Void = { _ in }) throws {
        let part = try self.readOutbound(as: HTTPClientRequestPart.self)
        switch part {
        case .body(let iodata):
            try verify(iodata)
        case .head, .end:
            throw HTTP1EmbeddedChannelError(reason: "Expected .head but got '\(part!)'")
        case .none:
            throw HTTP1EmbeddedChannelError(reason: "Nothing in buffer")
        }
    }

    public func receiveEnd() throws {
        let part = try self.readOutbound(as: HTTPClientRequestPart.self)
        switch part {
        case .end:
            break
        case .head, .body:
            throw HTTP1EmbeddedChannelError(reason: "Expected .head but got '\(part!)'")
        case .none:
            throw HTTP1EmbeddedChannelError(reason: "Nothing in buffer")
        }
    }
}

struct HTTP1TestTools {
    let connection: HTTP1Connection.SendableView
    let connectionDelegate: MockConnectionDelegate
    let readEventHandler: ReadEventHitHandler
    let logger: Logger
}

extension EmbeddedChannel {
    func setupHTTP1Connection() throws -> HTTP1TestTools {
        let logger = Logger(label: "test")
        let readEventHandler = ReadEventHitHandler()

        try self.pipeline.syncOperations.addHandler(readEventHandler)
        try self.connect(to: .makeAddressResolvingHost("localhost", port: 0)).wait()

        let connectionDelegate = MockConnectionDelegate()
        let connection = try HTTP1Connection.start(
            channel: self,
            connectionID: 1,
            delegate: connectionDelegate,
            decompression: .disabled,
            logger: logger
        )

        // remove HTTP client encoder and decoder

        let decoder = try self.pipeline.syncOperations.handler(type: ByteToMessageHandler<HTTPResponseDecoder>.self)
        let encoder = try self.pipeline.syncOperations.handler(type: HTTPRequestEncoder.self)

        let removeDecoderFuture = self.pipeline.syncOperations.removeHandler(decoder)
        let removeEncoderFuture = self.pipeline.syncOperations.removeHandler(encoder)

        self.embeddedEventLoop.run()

        try removeDecoderFuture.wait()
        try removeEncoderFuture.wait()

        return .init(
            connection: connection.sendableView,
            connectionDelegate: connectionDelegate,
            readEventHandler: readEventHandler,
            logger: logger
        )
    }
}

public struct HTTP1EmbeddedChannelError: Error, Hashable, CustomStringConvertible {
    public var reason: String

    public init(reason: String) {
        self.reason = reason
    }

    public var description: String {
        self.reason
    }
}
