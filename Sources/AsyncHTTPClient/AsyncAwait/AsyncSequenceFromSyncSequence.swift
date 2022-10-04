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

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
@usableFromInline
struct AsyncSequenceFromSyncSequence<Wrapped: Sequence & Sendable>: AsyncSequence, Sendable {
    @usableFromInline typealias Element = Wrapped.Element
    @usableFromInline struct AsyncIterator: AsyncIteratorProtocol {
        @usableFromInline var iterator: Wrapped.Iterator
        @inlinable init(iterator: Wrapped.Iterator) {
            self.iterator = iterator
        }
        @inlinable mutating func next() async throws -> Wrapped.Element? {
            self.iterator.next()
        }
    }

    @usableFromInline var wrapped: Wrapped
    
    @inlinable init(wrapped: Wrapped) {
        self.wrapped = wrapped
    }
    
    @inlinable func makeAsyncIterator() -> AsyncIterator {
        .init(iterator: self.wrapped.makeIterator())
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension Sequence where Self: Sendable {
    /// Turns `self` into an `AsyncSequence` by wending each element of `self` asynchronously.
    @inlinable func asAsyncSequence() -> AsyncSequenceFromSyncSequence<Self> {
        .init(wrapped: self)
    }
}
