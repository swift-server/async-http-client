//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2018-2020 Apple Inc. and the AsyncHTTPClient project authors
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
    mutating func validate(method: HTTPMethod, body: HTTPClient.Body?) throws -> RequestFramingMetadata {
        var metadata = RequestFramingMetadata(connectionClose: false, body: .none)

        if self[canonicalForm: "connection"].map({ $0.lowercased() }).contains("close") {
            metadata.connectionClose = true
        }

        // validate transfer encoding and content length (https://tools.ietf.org/html/rfc7230#section-3.3.1)
        if self.contains(name: "Transfer-Encoding"), self.contains(name: "Content-Length") {
            throw HTTPClientError.incompatibleHeaders
        }

        var transferEncoding: String?
        var contentLength: Int?
        let encodings = self[canonicalForm: "Transfer-Encoding"].map { $0.lowercased() }

        guard !encodings.contains("identity") else {
            throw HTTPClientError.identityCodingIncorrectlyPresent
        }

        self.remove(name: "Transfer-Encoding")

        try self.validateFieldNames()

        guard let body = body else {
            self.remove(name: "Content-Length")
            // if we don't have a body we might not need to send the Content-Length field
            // https://tools.ietf.org/html/rfc7230#section-3.3.2
            switch method {
            case .GET, .HEAD, .DELETE, .CONNECT, .TRACE:
                // A user agent SHOULD NOT send a Content-Length header field when the request
                // message does not contain a payload body and the method semantics do not
                // anticipate such a body.
                return metadata
            default:
                // A user agent SHOULD send a Content-Length in a request message when
                // no Transfer-Encoding is sent and the request method defines a meaning
                // for an enclosed payload body.
                self.add(name: "Content-Length", value: "0")
                return metadata
            }
        }

        if case .TRACE = method {
            // A client MUST NOT send a message body in a TRACE request.
            // https://tools.ietf.org/html/rfc7230#section-4.3.8
            throw HTTPClientError.traceRequestWithBody
        }

        guard (encodings.lazy.filter { $0 == "chunked" }.count <= 1) else {
            throw HTTPClientError.chunkedSpecifiedMultipleTimes
        }

        if encodings.isEmpty {
            if let length = body.length {
                self.remove(name: "Content-Length")
                contentLength = length
            } else if !self.contains(name: "Content-Length") {
                transferEncoding = "chunked"
            }
        } else {
            self.remove(name: "Content-Length")

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
            metadata.body = .stream
        } else if let length = contentLength {
            // A sender MUST NOT send a Content-Length header field in any message
            // that contains a Transfer-Encoding header field.
            self.add(name: "Content-Length", value: String(length))
            metadata.body = .fixedSize(length)
        }

        return metadata
    }

    private func validateFieldNames() throws {
        let invalidFieldNames = self.compactMap { (name, _) -> String? in
            let satisfy = name.utf8.allSatisfy { (char) -> Bool in
                switch char {
                case UInt8(ascii: "a")...UInt8(ascii: "z"),
                     UInt8(ascii: "A")...UInt8(ascii: "Z"),
                     UInt8(ascii: "0")...UInt8(ascii: "9"),
                     UInt8(ascii: "!"),
                     UInt8(ascii: "#"),
                     UInt8(ascii: "$"),
                     UInt8(ascii: "%"),
                     UInt8(ascii: "&"),
                     UInt8(ascii: "'"),
                     UInt8(ascii: "*"),
                     UInt8(ascii: "+"),
                     UInt8(ascii: "-"),
                     UInt8(ascii: "."),
                     UInt8(ascii: "^"),
                     UInt8(ascii: "_"),
                     UInt8(ascii: "`"),
                     UInt8(ascii: "|"),
                     UInt8(ascii: "~"):
                    return true
                default:
                    return false
                }
            }

            return satisfy ? nil : name
        }

        guard invalidFieldNames.count == 0 else {
            throw HTTPClientError.invalidHeaderFieldNames(invalidFieldNames)
        }
    }
}
