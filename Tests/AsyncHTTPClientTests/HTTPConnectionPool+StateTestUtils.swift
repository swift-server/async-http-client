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

@testable import AsyncHTTPClient
import Dispatch
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded

/// An `EventLoopGroup` of `EmbeddedEventLoop`s.
final class EmbeddedEventLoopGroup: EventLoopGroup {
    private let loops: [EmbeddedEventLoop]
    private let index = NIOAtomic<Int>.makeAtomic(value: 0)

    internal init(loops: Int) {
        self.loops = (0..<loops).map { _ in EmbeddedEventLoop() }
    }

    internal func next() -> EventLoop {
        let index: Int = self.index.add(1)
        return self.loops[index % self.loops.count]
    }

    internal func makeIterator() -> EventLoopIterator {
        return EventLoopIterator(self.loops)
    }

    internal func shutdownGracefully(queue: DispatchQueue, _ callback: @escaping (Error?) -> Void) {
        var shutdownError: Error?

        for loop in self.loops {
            loop.shutdownGracefully(queue: queue) { error in
                if let error = error {
                    shutdownError = error
                }
            }
        }

        queue.sync {
            callback(shutdownError)
        }
    }
}

extension HTTPConnectionPool.HTTP1Connections.ConnectionUse: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.eventLoop(let lhsEventLoop), .eventLoop(let rhsEventLoop)):
            return lhsEventLoop === rhsEventLoop
        case (.generalPurpose, .generalPurpose):
            return true
        default:
            return false
        }
    }
}
