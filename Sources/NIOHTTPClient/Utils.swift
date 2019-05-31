//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIOHTTPClient open source project
//
// Copyright (c) 2018-2019 Swift Server Working Group and the SwiftNIOHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIOHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO
import NIOHTTP1

public class HandlingHTTPResponseDelegate<T>: HTTPClientResponseDelegate {
    struct EmptyEndHandlerError: Error {}

    public typealias Result = T

    var handleHead: ((HTTPResponseHead) -> Void)?
    var handleBody: ((ByteBuffer) -> Void)?
    var handleError: ((Error) -> Void)?
    var handleEnd: (() throws -> T)?

    public func didTransmitRequestBody(task: HTTPClient.Task<T>) {}

    public func didReceiveHead(task: HTTPClient.Task<T>, _ head: HTTPResponseHead) {
        if let handler = handleHead {
            handler(head)
        }
    }

    public func didReceivePart(task: HTTPClient.Task<T>, eventLoop: EventLoop, _ buffer: ByteBuffer) -> EventLoopFuture<Void> {
        if let handler = handleBody {
            handler(buffer)
        }
        return eventLoop.makeSucceededFuture(())
    }

    public func didReceiveError(task: HTTPClient.Task<T>, _ error: Error) {
        if let handler = handleError {
            handler(error)
        }
    }

    public func didFinishRequest(task: HTTPClient.Task<T>) throws -> T {
        if let handler = handleEnd {
            return try handler()
        }
        throw EmptyEndHandlerError()
    }
}

final class CopyingDelegate: HTTPClientResponseDelegate {
    public typealias Response = Void

    let chunkHandler: (ByteBuffer) -> EventLoopFuture<Void>

    init(chunkHandler: @escaping (ByteBuffer) -> EventLoopFuture<Void>) {
        self.chunkHandler = chunkHandler
    }

    func didReceivePart(task: HTTPClient.Task<Void>, eventLoop: EventLoop, _ buffer: ByteBuffer) -> EventLoopFuture<Void> {
        return self.chunkHandler(buffer)
    }

    func didFinishRequest(task: HTTPClient.Task<Void>) throws {
        return ()
    }
}
