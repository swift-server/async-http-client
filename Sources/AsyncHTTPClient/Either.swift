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

@usableFromInline enum Either<A, B> {
    case a(A)
    case b(B)
}

extension Either: Sendable where A: Sendable, B: Sendable {}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension Either: AsyncSequence where A: AsyncSequence, B: AsyncSequence, A.Element == B.Element {
    @usableFromInline typealias Element = A.Element
    
    @inlinable func makeAsyncIterator() -> Either<A.AsyncIterator, B.AsyncIterator> {
        switch self {
        case .a(let a):
            return .a(a.makeAsyncIterator())
        case .b(let b):
            return .b(b.makeAsyncIterator())
        }
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension Either: AsyncIteratorProtocol where A: AsyncIteratorProtocol, B: AsyncIteratorProtocol, A.Element == B.Element {
    @inlinable mutating func next() async throws -> A.Element? {
        switch self {
        case .a(var a):
            defer { self = .a(a) }
            return try await a.next()
        case .b(var b):
            defer { self = .b(b) }
            return try await b.next()
        }
    }
}
