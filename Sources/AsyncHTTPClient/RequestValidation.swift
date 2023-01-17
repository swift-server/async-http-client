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
    mutating func validate(method: HTTPMethod, body: HTTPClient.Body?) throws {
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
        try self.validateFieldValues()
        
        guard let body = body else {
            self.remove(name: "Content-Length")
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
        } else if let length = contentLength {
            // A sender MUST NOT send a Content-Length header field in any message
            // that contains a Transfer-Encoding header field.
            self.add(name: "Content-Length", value: String(length))
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
    
    private func validateFieldValues() throws {
        let invalidValues = self.compactMap { _, value -> String? in
            let satisfy = value.utf8.allSatisfy { char -> Bool in
                /// Validates a byte of a given header field value against the definition in RFC 9110.
                ///
                /// The spec in [RFC 9110](https://httpwg.org/specs/rfc9110.html#fields.values) defines the valid
                /// characters as the following:
                ///
                /// ```
                /// field-value    = *field-content
                /// field-content  = field-vchar
                ///                  [ 1*( SP / HTAB / field-vchar ) field-vchar ]
                /// field-vchar    = VCHAR / obs-text
                /// obs-text       = %x80-FF
                /// ```
                ///
                /// Additionally, it makes the following note:
                ///
                /// "Field values containing CR, LF, or NUL characters are invalid and dangerous, due to the
                /// varying ways that implementations might parse and interpret those characters; a recipient
                /// of CR, LF, or NUL within a field value MUST either reject the message or replace each of
                /// those characters with SP before further processing or forwarding of that message. Field
                /// values containing other CTL characters are also invalid; however, recipients MAY retain
                /// such characters for the sake of robustness when they appear within a safe context (e.g.,
                /// an application-specific quoted string that will not be processed by any downstream HTTP
                /// parser)."
                ///
                /// As we cannot guarantee the context is safe, this code will reject all ASCII control characters
                /// directly _except_ for HTAB, which is explicitly allowed.
                switch char {
                case UInt8(ascii: "\t"):
                    // HTAB, explicitly allowed.
                    return true
                case 0...0x1f, 0x7F:
                    // ASCII control character, forbidden.
                    return false
                default:
                    // Printable or non-ASCII, allowed.
                    return true
                }
            }
            
            return satisfy ? nil : value
        }
        
        guard invalidValues.count == 0 else {
            throw HTTPClientError.invalidHeaderFieldValues(invalidValues)
        }
    }
}
