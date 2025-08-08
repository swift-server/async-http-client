//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2018-2021 Apple Inc. and the AsyncHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore

/// An ``HTTPClientResponseDelegate`` that wraps a callback.
///
/// ``HTTPClientCopyingDelegate`` discards most parts of a HTTP response, but streams the body
/// to the `chunkHandler` provided on ``init(chunkHandler:)``. This is mostly useful for testing.
public final class HTTPClientCopyingDelegate: HTTPClientResponseDelegate, Sendable {
    public typealias Response = Void

    let chunkHandler: @Sendable (ByteBuffer) -> EventLoopFuture<Void>

    @preconcurrency
    public init(chunkHandler: @Sendable @escaping (ByteBuffer) -> EventLoopFuture<Void>) {
        self.chunkHandler = chunkHandler
    }

    public func didReceiveBodyPart(task: HTTPClient.Task<Void>, _ buffer: ByteBuffer) -> EventLoopFuture<Void> {
        self.chunkHandler(buffer)
    }

    public func didFinishRequest(task: HTTPClient.Task<Void>) throws {
        ()
    }
}

/// A utility function that runs the body code only in debug builds, without
/// emitting compiler warnings.
///
/// This is currently the only way to do this in Swift: see
/// https://forums.swift.org/t/support-debug-only-code/11037 for a discussion.
@inlinable
internal func debugOnly(_ body: () -> Void) {
    assert(
        {
            body()
            return true
        }()
    )
}

extension BidirectionalCollection where Element: Equatable {
    /// Returns a Boolean value indicating whether the collection ends with the specified suffix.
    ///
    /// If `suffix` is empty, this function returns `true`.
    /// If all elements of the collections are equal, this function also returns `true`.
    func hasSuffix<Suffix>(_ suffix: Suffix) -> Bool where Suffix: BidirectionalCollection, Suffix.Element == Element {
        var ourIdx = self.endIndex
        var suffixIdx = suffix.endIndex
        while ourIdx > self.startIndex, suffixIdx > suffix.startIndex {
            self.formIndex(before: &ourIdx)
            suffix.formIndex(before: &suffixIdx)
            guard self[ourIdx] == suffix[suffixIdx] else { return false }
        }
        guard suffixIdx == suffix.startIndex else {
            return false  // Exhausted self, but 'suffix' has elements remaining.
        }
        return true  // Exhausted 'other' without finding a mismatch.
    }
}
