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

import NIOCore
import NIOHTTP1

extension HTTPHeaders {
    mutating func validateAndFixTransportFraming(
        method: HTTPMethod,
        bodyLength: RequestBodyLength
    ) throws -> RequestFramingMetadata {
        let contentLength = self.first(name: "Content-Length")
        let encodings = self[canonicalForm: "Transfer-Encoding"]

        // "Transfer-Encoding" and "Content-Length" are not allowed to present at the same time (https://tools.ietf.org/html/rfc7230#section-3.3.1)
        guard encodings.isEmpty || contentLength == nil else {
            throw HTTPClientError.incompatibleHeaders
        }

        try self.validateFieldNames()
        try Self.validateTransferEncoding(encodings)

        if contentLength != nil {
            self.remove(name: "Content-Length")
        }
        if !encodings.isEmpty {
            self.remove(name: "Transfer-Encoding")
        }

        let connectionClose = self[canonicalForm: "connection"].lazy.map { $0.lowercased() }.contains("close")

        switch bodyLength {
        case .fixed(0):
            // if we don't have a body we might not need to send the Content-Length field
            // https://tools.ietf.org/html/rfc7230#section-3.3.2
            switch method {
            case .GET, .HEAD, .DELETE, .CONNECT, .TRACE:
                // A user agent SHOULD NOT send a Content-Length header field when the request
                // message does not contain a payload body and the method semantics do not
                // anticipate such a body.
                break
            default:
                // A user agent SHOULD send a Content-Length in a request message when
                // no Transfer-Encoding is sent and the request method defines a meaning
                // for an enclosed payload body.
                self.add(name: "Content-Length", value: "0")
            }
            return .init(connectionClose: connectionClose, body: .fixedSize(0))
        case .fixed(let length):
            if case .TRACE = method {
                // A client MUST NOT send a message body in a TRACE request.
                // https://tools.ietf.org/html/rfc7230#section-4.3.8
                throw HTTPClientError.traceRequestWithBody
            }
            if encodings.isEmpty {
                self.add(name: "Content-Length", value: String(length))
                return .init(connectionClose: connectionClose, body: .fixedSize(length))
            } else {
                self.add(name: "Transfer-Encoding", value: encodings.joined(separator: ", "))
                return .init(connectionClose: connectionClose, body: .stream)
            }
        case .dynamic:
            if case .TRACE = method {
                // A client MUST NOT send a message body in a TRACE request.
                // https://tools.ietf.org/html/rfc7230#section-4.3.8
                throw HTTPClientError.traceRequestWithBody
            }

            if encodings.isEmpty && contentLength == nil {
                // if a user forgot to specify a Content-Length and Transfer-Encoding, we will set it for them
                self.add(name: "Transfer-Encoding", value: "chunked")
            } else {
                self.add(name: "Transfer-Encoding", value: encodings.joined(separator: ", "))
            }

            return .init(connectionClose: connectionClose, body: .stream)
        }
    }

    func validateFieldNames() throws {
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

    static func validateTransferEncoding<Encodings>(
        _ encodings: Encodings
    ) throws where Encodings: Sequence, Encodings.Element: StringProtocol {
        let encodings = encodings.map { $0.lowercased() }

        guard !encodings.contains("identity") else {
            throw HTTPClientError.identityCodingIncorrectlyPresent
        }

        // If `Transfer-Encoding` is specified, `chunked` needs to be the last encoding and should not be specified multiple times
        // https://datatracker.ietf.org/doc/html/rfc7230#section-3.3.1
        let chunkedEncodingCount = encodings.lazy.filter { $0 == "chunked" }.count
        switch chunkedEncodingCount {
        case 0:
            if !encodings.isEmpty {
                throw HTTPClientError.transferEncodingSpecifiedButChunkedIsNotTheFinalEncoding
            }
        case 1:
            guard encodings.last == "chunked" else {
                throw HTTPClientError.transferEncodingSpecifiedButChunkedIsNotTheFinalEncoding
            }
        case 2...:
            throw HTTPClientError.chunkedSpecifiedMultipleTimes
        default:
            // unreachable because `chunkedEncodingCount` is guaranteed to be positive
            preconditionFailure()
        }
    }
}
