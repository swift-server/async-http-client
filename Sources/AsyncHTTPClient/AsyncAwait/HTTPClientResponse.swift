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

import struct Foundation.URL

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

    /// The history of all requests and responses in redirect order.
    public var history: [HTTPClientRequestResponse]

    /// The target URL (after redirects) of the response.
    public var url: URL? {
        guard let lastRequestURL = self.history.last?.request.url else {
            return nil
        }

        return URL(string: lastRequestURL)
    }

    @inlinable public init(
        version: HTTPVersion = .http1_1,
        status: HTTPResponseStatus = .ok,
        headers: HTTPHeaders = [:],
        body: Body = Body()
    ) {
        self.version = version
        self.status = status
        self.headers = headers
        self.body = body
        self.history = []
    }

    @inlinable public init(
        version: HTTPVersion = .http1_1,
        status: HTTPResponseStatus = .ok,
        headers: HTTPHeaders = [:],
        body: Body = Body(),
        history: [HTTPClientRequestResponse] = []
    ) {
        self.version = version
        self.status = status
        self.headers = headers
        self.body = body
        self.history = history
    }

    init(
        requestMethod: HTTPMethod,
        version: HTTPVersion,
        status: HTTPResponseStatus,
        headers: HTTPHeaders,
        body: TransactionBody,
        history: [HTTPClientRequestResponse]
    ) {
        self.init(
            version: version,
            status: status,
            headers: headers,
            body: .init(
                .transaction(
                    body,
                    expectedContentLength: HTTPClientResponse.expectedContentLength(
                        requestMethod: requestMethod,
                        headers: headers,
                        status: status
                    )
                )
            ),
            history: history
        )
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
public struct HTTPClientRequestResponse: Sendable {
    public var request: HTTPClientRequest
    public var responseHead: HTTPResponseHead

    public init(request: HTTPClientRequest, responseHead: HTTPResponseHead) {
        self.request = request
        self.responseHead = responseHead
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

        @inlinable init(storage: Storage) {
            self.storage = storage
        }

        /// Accumulates `Body` of `ByteBuffer`s into a single `ByteBuffer`.
        /// - Parameters:
        ///   - maxBytes: The maximum number of bytes this method is allowed to accumulate
        /// - Throws: `NIOTooManyBytesError` if the the sequence contains more than `maxBytes`.
        /// - Returns: the number of bytes collected over time
        @inlinable public func collect(upTo maxBytes: Int) async throws -> ByteBuffer {
            switch self.storage {
            case .transaction(_, let expectedContentLength):
                if let contentLength = expectedContentLength {
                    if contentLength > maxBytes {
                        throw NIOTooManyBytesError(maxBytes: maxBytes)
                    }
                }
            case .anyAsyncSequence:
                break
            }

            /// calling collect function within here in order to ensure the correct nested type
            func collect<Body: AsyncSequence>(_ body: Body, maxBytes: Int) async throws -> ByteBuffer
            where Body.Element == ByteBuffer {
                try await body.collect(upTo: maxBytes)
            }
            return try await collect(self, maxBytes: maxBytes)
        }
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension HTTPClientResponse {
    static func expectedContentLength(
        requestMethod: HTTPMethod,
        headers: HTTPHeaders,
        status: HTTPResponseStatus
    ) -> Int? {
        if status == .notModified {
            return 0
        } else if requestMethod == .HEAD {
            return 0
        } else {
            let contentLength = headers["content-length"].first.flatMap { Int($0, radix: 10) }
            return contentLength
        }
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
@usableFromInline
typealias TransactionBody = NIOThrowingAsyncSequenceProducer<
    ByteBuffer,
    Error,
    NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark,
    AnyAsyncSequenceProducerDelegate
>

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension HTTPClientResponse.Body {
    @usableFromInline enum Storage: Sendable {
        case transaction(TransactionBody, expectedContentLength: Int?)
        case anyAsyncSequence(AnyAsyncSequence<ByteBuffer>)
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension HTTPClientResponse.Body.Storage: AsyncSequence {
    @usableFromInline typealias Element = ByteBuffer

    @inlinable func makeAsyncIterator() -> AsyncIterator {
        switch self {
        case .transaction(let transaction, _):
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
    @inlinable init(_ storage: Storage) {
        self.storage = storage
    }

    public init() {
        self = .stream(EmptyCollection<ByteBuffer>().async)
    }

    @inlinable public static func stream<SequenceOfBytes>(
        _ sequenceOfBytes: SequenceOfBytes
    ) -> Self where SequenceOfBytes: AsyncSequence & Sendable, SequenceOfBytes.Element == ByteBuffer {
        Self(storage: .anyAsyncSequence(AnyAsyncSequence(sequenceOfBytes.singleIteratorPrecondition)))
    }

    public static func bytes(_ byteBuffer: ByteBuffer) -> Self {
        .stream(CollectionOfOne(byteBuffer).async)
    }
}

@available(*, unavailable)
extension HTTPClientResponse.Body.AsyncIterator: Sendable {}

@available(*, unavailable)
extension HTTPClientResponse.Body.Storage.AsyncIterator: Sendable {}
