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

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
public struct HTTPClientResponse {
    public var version: HTTPVersion
    public var status: HTTPResponseStatus
    public var headers: HTTPHeaders
    public var body: Body

    public struct Body {
        private let bag: Transaction
        private let reference: ResponseRef

        fileprivate init(_ transaction: Transaction) {
            self.bag = transaction
            self.reference = ResponseRef(transaction: transaction)
        }
    }

    init(
        bag: Transaction,
        version: HTTPVersion,
        status: HTTPResponseStatus,
        headers: HTTPHeaders
    ) {
        self.body = Body(bag)
        self.version = version
        self.status = status
        self.headers = headers
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension HTTPClientResponse.Body: AsyncSequence {
    public typealias Element = AsyncIterator.Element

    public struct AsyncIterator: AsyncIteratorProtocol {
        private let stream: IteratorStream

        fileprivate init(stream: IteratorStream) {
            self.stream = stream
        }

        public mutating func next() async throws -> ByteBuffer? {
            try await self.stream.next()
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(stream: IteratorStream(bag: self.bag))
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension HTTPClientResponse.Body {
    /// The purpose of this object is to inform the transaction about the response body being deinitialized.
    /// If the users has not called `makeAsyncIterator` on the body, before it is deinited, the http
    /// request needs to be cancelled.
    fileprivate class ResponseRef {
        private let transaction: Transaction

        init(transaction: Transaction) {
            self.transaction = transaction
        }

        deinit {
            self.transaction.responseBodyDeinited()
        }
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension HTTPClientResponse.Body {
    internal class IteratorStream {
        struct ID: Hashable {
            private let objectID: ObjectIdentifier

            init(_ object: IteratorStream) {
                self.objectID = ObjectIdentifier(object)
            }
        }

        private var id: ID { ID(self) }
        private let bag: Transaction

        init(bag: Transaction) {
            self.bag = bag
        }

        deinit {
            self.bag.responseBodyIteratorDeinited(streamID: self.id)
        }

        func next() async throws -> ByteBuffer? {
            try await self.bag.nextResponsePart(streamID: self.id)
        }
    }
}

#endif
