//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the AsyncHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO
import NIOHTTP1

extension HTTPHeaders {
    mutating func validate(method: HTTPMethod, body: HTTPClient.Body?) throws {
        // validate transfer encoding and content length (https://tools.ietf.org/html/rfc7230#section-3.3.1)
        var transferEncoding: String?
        var contentLength: Int?
        let encodings = self[canonicalForm: "Transfer-Encoding"].map { $0.lowercased() }

        guard !encodings.contains("identity") else {
            throw HTTPClientError.identityCodingIncorrectlyPresent
        }

        self.remove(name: "Transfer-Encoding")
        self.remove(name: "Content-Length")

        guard let body = body else {
            // if we don't have a body we might not need to send the Content-Length field
            // https://tools.ietf.org/html/rfc7230#section-3.3.2
            switch method {
            case .GET, .HEAD, .DELETE, .CONNECT, .TRACE:
                // A user agent SHOULD NOT send a Content-Length header field when the request
                // message does not contain a payload body and the method semantics do not
                // anticipate such a body.
                return
            default:
                // A user agent SHOULD send a Content-Length in a request message when
                // no Transfer-Encoding is sent and the request method defines a meaning
                // for an enclosed payload body.
                self.add(name: "Content-Length", value: "0")
                return
            }
        }

        if case .TRACE = method {
            // A client MUST NOT send a message body in a TRACE request.
            // https://tools.ietf.org/html/rfc7230#section-4.3.8
            throw HTTPClientError.traceRequestWithBody
        }

        guard (encodings.filter { $0 == "chunked" }.count <= 1) else {
            throw HTTPClientError.chunkedSpecifiedMultipleTimes
        }

        if encodings.isEmpty {
            guard let length = body.length else {
                throw HTTPClientError.contentLengthMissing
            }
            contentLength = length
        } else {
            transferEncoding = encodings.joined(separator: ", ")
            if !encodings.contains("chunked") {
                guard let length = body.length else {
                    throw HTTPClientError.contentLengthMissing
                }
                contentLength = length
            }
        }

        // add headers if required
        if let enc = transferEncoding {
            self.add(name: "Transfer-Encoding", value: enc)
        } else if let length = contentLength {
            // A sender MUST NOT send a Content-Length header field in any message
            // that contains a Transfer-Encoding header field.
            self.add(name: "Content-Length", value: String(length))
        }
    }
}
