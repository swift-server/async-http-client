//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2021-2022 Apple Inc. and the AsyncHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore

/// This is a class because we need to inform the transaction about the response body being deinitialized.
/// If the users has not called `makeAsyncIterator` on the body, before it is deinited, the http
/// request needs to be cancelled.
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
@usableFromInline final class TransactionBody: Sendable {
    @usableFromInline let transaction: Transaction
    @usableFromInline let expectedContentLength: Int?

    init(_ transaction: Transaction, expextedContentLength: Int?) {
        self.transaction = transaction
        self.expectedContentLength = expextedContentLength
    }

    deinit {
        self.transaction.responseBodyDeinited()
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension TransactionBody: AsyncSequence {
    @usableFromInline typealias Element = AsyncIterator.Element

    @usableFromInline final class AsyncIterator: AsyncIteratorProtocol {
        @usableFromInline struct ID: Hashable {
            private let objectID: ObjectIdentifier

            init(_ object: AsyncIterator) {
                self.objectID = ObjectIdentifier(object)
            }
        }

        @usableFromInline var id: ID { ID(self) }
        @usableFromInline let transaction: Transaction

        @inlinable init(transaction: Transaction) {
            self.transaction = transaction
        }

        deinit {
            self.transaction.responseBodyIteratorDeinited(streamID: self.id)
        }

        // TODO: this should be @inlinable
        @usableFromInline func next() async throws -> ByteBuffer? {
            try await self.transaction.nextResponsePart(streamID: self.id)
        }
    }

    @inlinable func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(transaction: self.transaction)
    }
}
