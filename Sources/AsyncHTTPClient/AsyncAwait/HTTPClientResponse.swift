//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2021 Apple Inc. and the AsyncHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if compiler(>=5.5.2) && canImport(_Concurrency)
import NIOCore
import NIOHTTP1

/// A representation of an HTTP response for the Swift Concurrency HTTPClient API.
///
/// This object is similar to ``HTTPClient/Response``, but used for the Swift Concurrency API.
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
public struct HTTPClientResponse: Sendable {
    /// The HTTP version on which the response was received.
    public var version: HTTPVersion

    /// The HTTP status for this response.
    public var status: HTTPResponseStatus

    /// The HTTP headers of this response.
    public var headers: HTTPHeaders

    /// The body of this HTTP response.
    public var body: Body

    init(
        bag: Transaction,
        version: HTTPVersion,
        status: HTTPResponseStatus,
        headers: HTTPHeaders
    ) {
        self.version = version
        self.status = status
        self.headers = headers
        self.body = Body(TransactionBody(bag))
    }
    
    @inlinable public init(){
        self.version = .http1_1
        self.status = .ok
        self.headers = [:]
        self.body = Body()
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension HTTPClientResponse {
    /// A representation of the response body for an HTTP response.
    ///
    /// The body is streamed as an `AsyncSequence` of `ByteBuffer`, where each `ByteBuffer` contains
    /// an arbitrarily large chunk of data. The boundaries between `ByteBuffer` objects in the sequence
    /// are entirely synthetic and have no semantic meaning.
    public struct Body: AsyncSequence, Sendable {
        public typealias Element = ByteBuffer
        @usableFromInline typealias Storage = Either<TransactionBody, AnyAsyncSequence<ByteBuffer>>
        public struct AsyncIterator: AsyncIteratorProtocol {
            @usableFromInline var storage: Storage.AsyncIterator
            
            @inlinable init(storage: Storage.AsyncIterator) {
                self.storage = storage
            }
            
            @inlinable public mutating func next() async throws -> ByteBuffer? {
                try await storage.next()
            }
        }
        
        @usableFromInline var storage: Storage

        @inlinable public func makeAsyncIterator() -> AsyncIterator {
            .init(storage: storage.makeAsyncIterator())
        }
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension HTTPClientResponse.Body {
    @inlinable init(_ body: TransactionBody) {
        self.storage = .a(body)
    }
    
    @inlinable public init<SequenceOfBytes>(
        _ sequenceOfBytes: SequenceOfBytes
    ) where SequenceOfBytes: AsyncSequence & Sendable, SequenceOfBytes.Element == ByteBuffer {
        self.storage = .b(AnyAsyncSequence(sequenceOfBytes))
    }
    
    public init() {
        self.init(EmptyCollection().asAsyncSequence())
    }
    
    public init(_ byteBuffer: ByteBuffer) {
        self.init(CollectionOfOne(byteBuffer).asAsyncSequence())
    }
}

#endif
