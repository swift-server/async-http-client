//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIOHTTP open source project
//
// Copyright (c) 2017-2018 Swift Server Working Group and the SwiftNIOHTTP project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIOHTTP project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO
import NIOHTTP1

public class HandlingHTTPResponseDelegate<T> : HTTPResponseDelegate {

    struct EmptyEndHandlerError : Error {
    }

    public typealias Result = T

    var handleHead: ((HTTPResponseHead) -> Void)?
    var handleBody: ((ByteBuffer) -> Void)?
    var handleError: ((Error) -> Void)?
    var handleEnd: (() throws -> T)?

    public func didTransmitRequestBody() {
    }

    public func didReceiveHead(_ head: HTTPResponseHead) {
        if let handler = handleHead {
            handler(head)
        }
    }

    public func didReceivePart(_ buffer: ByteBuffer) {
        if let handler = handleBody {
            handler(buffer)
        }
    }

    public func didReceiveError(_ error: Error) {
        if let handler = handleError {
            handler(error)
        }
    }

    public func didFinishRequest() throws -> T {
        if let handler = handleEnd {
            return try handler()
        }
        throw EmptyEndHandlerError()
    }
}
