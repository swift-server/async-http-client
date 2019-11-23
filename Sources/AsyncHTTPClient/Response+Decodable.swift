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
import NIO


extension EventLoopFuture where Value == HTTPClient.Response {
    
    public enum BodyError : Swift.Error {
        case noBodyData
    }
    
    /// Decode the response body as T using the given decoder.
    ///
    /// - parameters:
    ///     - type: The type to decode.  Must conform to Decoable.
    ///     - decoder: The decoder used to decode the reponse body.  Defaults to JSONDecoder.
    /// - returns: A future decoded type.
    /// - throws: BodyError.noBodyData when no body is found in reponse.
    public func decode<T : Decodable>(as type: T.Type, decoder: Decoder = JSONDecoder()) -> EventLoopFuture<T> {
        flatMapThrowing { response -> T in
            
            guard let bodyData = response.bodyData else {
                throw BodyError.noBodyData
            }
            
            return try decoder.decode(type, from: bodyData)
        }
    }
    
    /// Decode the response body as T using the given decoder.
    ///
    /// - parameters:
    ///     - type: The type to decode.  Must conform to Decoable.
    ///     - decoder: The decoder used to decode the reponse body.  Defaults to JSONDecoder.
    /// - returns: A future optional decoded type.  The future value will be nil when no body is present in the response.
    public func decode<T : Decodable>(as type: T.Type, decoder: Decoder = JSONDecoder()) -> EventLoopFuture<T?> {
        flatMapThrowing { response -> T? in
            
            guard let bodyData = response.bodyData else {
                return nil
            }
            
            return try decoder.decode(type, from: bodyData)
        }
    }
    
}

extension HTTPClient.Response {
    
    public var bodyData : Data? {
        guard let bodyBuffer = body,
            let bodyBytes = bodyBuffer.getBytes(at: bodyBuffer.readerIndex, length: bodyBuffer.readableBytes) else {
            return nil
        }
        
        return Data(bodyBytes)
    }
    
}

public protocol Decoder {
    func decode<T>(_ type: T.Type, from: Data) throws -> T where T : Decodable
}

extension JSONDecoder : Decoder {}
extension PropertyListDecoder : Decoder {}
