//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2018-2019 Swift Server Working Group and the AsyncHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//


import Foundation

extension HTTPClient.Body {
    
    public static func encodable<T : Encodable>(_ encodable: T, encoder: Encoder = JSONEncoder()) throws -> HTTPClient.Body {
        return HTTPClient.Body.data(try encoder.encode(encodable))
    }
    
}

public protocol Encoder {
    func encode<T>(_ value: T) throws -> Data where T : Encodable
}

extension JSONEncoder : Encoder {}
extension PropertyListEncoder : Encoder {}
