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
    mutating func validateAndSetTransportFraming(
        method: HTTPMethod,
        bodyLength: RequestBodyLength
    ) throws -> RequestFramingMetadata {
        try self.validateFieldNames()

        if case .TRACE = method {
            switch bodyLength {
            case .fixed(length: 0):
                break
            case .dynamic, .fixed:
                // A client MUST NOT send a message body in a TRACE request.
                // https://tools.ietf.org/html/rfc7230#section-4.3.8
                throw HTTPClientError.traceRequestWithBody
            }
        }

        self.setTransportFraming(method: method, bodyLength: bodyLength)

        let connectionClose = self[canonicalForm: "connection"].lazy.map { $0.lowercased() }.contains("close")
        switch bodyLength {
        case .dynamic:
            return .init(connectionClose: connectionClose, body: .stream)
        case .fixed(let length):
            return .init(connectionClose: connectionClose, body: .fixedSize(length))
        }
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

    private mutating func setTransportFraming(
        method: HTTPMethod,
        bodyLength: RequestBodyLength
    ) {
        self.remove(name: "Content-Length")
        self.remove(name: "Transfer-Encoding")

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
        case .fixed(let length):
            self.add(name: "Content-Length", value: String(length))
        case .dynamic:
            self.add(name: "Transfer-Encoding", value: "chunked")
        }
    }
}
