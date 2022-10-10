//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2022 Apple Inc. and the AsyncHTTPClient project authors
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
struct AsyncLazySequence<Base: Sequence>: AsyncSequence {
    @usableFromInline typealias Element = Base.Element
    @usableFromInline struct AsyncIterator: AsyncIteratorProtocol {
        @usableFromInline var iterator: Base.Iterator
        @inlinable init(iterator: Base.Iterator) {
            self.iterator = iterator
        }

        @inlinable mutating func next() async throws -> Base.Element? {
            self.iterator.next()
        }
    }

    @usableFromInline var base: Base

    @inlinable init(base: Base) {
        self.base = base
    }

    @inlinable func makeAsyncIterator() -> AsyncIterator {
        .init(iterator: self.base.makeIterator())
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension AsyncLazySequence: Sendable where Base: Sendable {}
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension AsyncLazySequence.AsyncIterator: Sendable where Base.Iterator: Sendable {}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension Sequence {
    /// Turns `self` into an `AsyncSequence` by vending each element of `self` asynchronously.
    @inlinable var async: AsyncLazySequence<Self> {
        .init(base: self)
    }
}
