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
    mutating func validate(body: HTTPClient.Body?) throws {
        // validate transfer encoding and content length (https://tools.ietf.org/html/rfc7230#section-3.3.1)
        var transferEncoding: String?
        var contentLength: Int?
        let encodings = self[canonicalForm: "Transfer-Encoding"].map { $0.lowercased() }

        guard !encodings.contains("identity") else {
            throw HTTPClientError.identityCodingIncorrectlyPresent
        }

        self.remove(name: "Transfer-Encoding")
        self.remove(name: "Content-Length")

        if let body = body {
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
        } else {
            contentLength = 0
        }
        // add headers if required
        if let enc = transferEncoding {
            self.add(name: "Transfer-Encoding", value: enc)
        }
        if let length = contentLength {
            self.add(name: "Content-Length", value: String(length))
        }
    }
}
