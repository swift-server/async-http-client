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

    @usableFromInline internal var requestMethod: HTTPMethod?

    @inlinable
    init(
        version: HTTPVersion = .http1_1,
        status: HTTPResponseStatus = .ok,
        headers: HTTPHeaders = [:],
        body: Body = Body(),
        requestMethod: HTTPMethod?
    ) {
        self.version = version
        self.status = status
        self.headers = headers
        self.body = body
        self.requestMethod = requestMethod
    }

    init(
        bag: Transaction,
        version: HTTPVersion,
        status: HTTPResponseStatus,
        headers: HTTPHeaders,
        requestMethod: HTTPMethod
    ) {
        self.init(version: version, status: status, headers: headers, body: .init(TransactionBody(bag)), requestMethod: requestMethod)
    }

    @inlinable public init(
        version: HTTPVersion = .http1_1,
        status: HTTPResponseStatus = .ok,
        headers: HTTPHeaders = [:],
        body: Body = Body()
    ) {
        self.init(version: version, status: status, headers: headers, body: body, requestMethod: nil)
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
        public struct AsyncIterator: AsyncIteratorProtocol {
            @usableFromInline var storage: Storage.AsyncIterator

            @inlinable init(storage: Storage.AsyncIterator) {
                self.storage = storage
            }

            @inlinable public mutating func next() async throws -> ByteBuffer? {
                try await self.storage.next()
            }
        }

        @usableFromInline var storage: Storage

        @inlinable public func makeAsyncIterator() -> AsyncIterator {
            .init(storage: self.storage.makeAsyncIterator())
        }

        /// Accumulates `Body` of ``ByteBuffer``s into a single ``ByteBuffer``.
        /// - Parameters:
        ///   - maxBytes: The maximum number of bytes this method is allowed to accumulate
        /// - Throws: `NIOTooManyBytesError` if the the sequence contains more than `maxBytes`.
        /// - Returns: the number of bytes collected over time
        func collect(maxBytes: Int) async throws -> ByteBuffer {
            return try await self.collect(upTo: maxBytes)
        }
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension HTTPClientResponse {
    /// Accumulates `Body` of ``ByteBuffer``s into a single ``ByteBuffer``.
    /// - Parameters:
    ///   - maxBytes: The maximum number of bytes this method is allowed to accumulate
    /// - Throws: `NIOTooManyBytesError` if the the sequence contains more than `maxBytes`.
    /// - Returns: the number of bytes collected over time
    @inlinable public func collect(upTo maxBytes: Int) async throws -> ByteBuffer {
        if let contentLength = expectedContentLength() {
            if contentLength > maxBytes {
                throw NIOTooManyBytesError()
            }
        }
        return try await self.body.collect(upTo: maxBytes)
    }
    @inlinable func expectedContentLength() -> Int? {
        if let requestMethod = self.requestMethod {
            if self.status == .notModified {
               return 0
           } else if requestMethod == .HEAD {
               return 0
           }
       }
        let contentLengths = headers["content-length"].first.flatMap({Int($0, radix: 10)})
        return contentLengths
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension HTTPClientResponse.Body {
    @usableFromInline enum Storage: Sendable {
        case transaction(TransactionBody)
        case anyAsyncSequence(AnyAsyncSequence<ByteBuffer>)
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension HTTPClientResponse.Body.Storage: AsyncSequence {
    @usableFromInline typealias Element = ByteBuffer

    @inlinable func makeAsyncIterator() -> AsyncIterator {
        switch self {
        case .transaction(let transaction):
            return .transaction(transaction.makeAsyncIterator())
        case .anyAsyncSequence(let anyAsyncSequence):
            return .anyAsyncSequence(anyAsyncSequence.makeAsyncIterator())
        }
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension HTTPClientResponse.Body.Storage {
    @usableFromInline enum AsyncIterator {
        case transaction(TransactionBody.AsyncIterator)
        case anyAsyncSequence(AnyAsyncSequence<ByteBuffer>.AsyncIterator)
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension HTTPClientResponse.Body.Storage.AsyncIterator: AsyncIteratorProtocol {
    @inlinable mutating func next() async throws -> ByteBuffer? {
        switch self {
        case .transaction(let iterator):
            return try await iterator.next()
        case .anyAsyncSequence(var iterator):
            defer { self = .anyAsyncSequence(iterator) }
            return try await iterator.next()
        }
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension HTTPClientResponse.Body {
    init(_ body: TransactionBody) {
        self.init(.transaction(body))
    }

    @usableFromInline init(_ storage: Storage) {
        self.storage = storage
    }

    public init() {
        self = .stream(EmptyCollection<ByteBuffer>().async)
    }

    @inlinable public static func stream<SequenceOfBytes>(
        _ sequenceOfBytes: SequenceOfBytes
    ) -> Self where SequenceOfBytes: AsyncSequence & Sendable, SequenceOfBytes.Element == ByteBuffer {
        self.init(.anyAsyncSequence(AnyAsyncSequence(sequenceOfBytes.singleIteratorPrecondition)))
    }

    public static func bytes(_ byteBuffer: ByteBuffer) -> Self {
        .stream(CollectionOfOne(byteBuffer).async)
    }
}
