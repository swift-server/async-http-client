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

extension HTTPConnectionPool {
    /// A struct to store all queued requests.
    struct RequestQueue {
        private(set) var generalPurposeQueue: CircularBuffer<Request>
        private var eventLoopQueues: [EventLoopID: CircularBuffer<Request>]

        init() {
            self.generalPurposeQueue = CircularBuffer(initialCapacity: 32)
            self.eventLoopQueues = [:]
        }

        var count: Int {
            self.generalPurposeQueue.count + self.eventLoopQueues.reduce(0) { $0 + $1.value.count }
        }

        var isEmpty: Bool {
            self.count == 0
        }

        var generalPurposeCount: Int {
            self.generalPurposeQueue.count
        }

        func count(for eventLoop: EventLoop) -> Int {
            self.withEventLoopQueueIfAvailable(for: eventLoop.id) { $0.count } ?? 0
        }

        func isEmpty(for eventLoop: EventLoop?) -> Bool {
            if let eventLoop = eventLoop {
                return self.withEventLoopQueueIfAvailable(for: eventLoop.id) { $0.isEmpty } ?? true
            }
            return self.generalPurposeQueue.isEmpty
        }

        @discardableResult
        mutating func push(_ request: Request) -> Request.ID {
            if let eventLoop = request.requiredEventLoop {
                self.withEventLoopQueue(for: eventLoop.id) { queue in
                    queue.append(request)
                }
            } else {
                self.generalPurposeQueue.append(request)
            }
            return request.id
        }

        mutating func popFirst(for eventLoop: EventLoop? = nil) -> Request? {
            if let eventLoop = eventLoop {
                return self.withEventLoopQueue(for: eventLoop.id) { queue in
                    queue.popFirst()
                }
            } else {
                return self.generalPurposeQueue.popFirst()
            }
        }

        /// removes up to `max` requests from the queue for the given `eventLoop` and returns them.
        /// - Parameters:
        ///   - max: maximum number of requests to pop
        ///   - eventLoop: required event loop of the request
        /// - Returns: requests for the given `eventLoop`
        mutating func popFirst(max: Int, for eventLoop: EventLoop? = nil) -> [Request] {
            if let eventLoop = eventLoop {
                return self.withEventLoopQueue(for: eventLoop.id) { queue in
                    queue.popFirst(max: max)
                }
            } else {
                return self.generalPurposeQueue.popFirst(max: max)
            }
        }

        mutating func remove(_ requestID: Request.ID) -> Request? {
            if let eventLoopID = requestID.eventLoopID {
                return self.withEventLoopQueue(for: eventLoopID) { queue in
                    guard let index = queue.firstIndex(where: { $0.id == requestID }) else {
                        return nil
                    }
                    return queue.remove(at: index)
                }
            } else {
                if let index = self.generalPurposeQueue.firstIndex(where: { $0.id == requestID }) {
                    // TBD: This is slow. Do we maybe want something more sophisticated here?
                    return self.generalPurposeQueue.remove(at: index)
                }
                return nil
            }
        }

        mutating func removeAll() -> [Request] {
            var result = [Request]()
            result = self.eventLoopQueues.flatMap { $0.value }
            result.append(contentsOf: self.generalPurposeQueue)

            self.eventLoopQueues.removeAll()
            self.generalPurposeQueue.removeAll()
            return result
        }

        private mutating func withEventLoopQueue<Result>(
            for eventLoopID: EventLoopID,
            _ closure: (inout CircularBuffer<Request>) -> Result
        ) -> Result {
            if self.eventLoopQueues[eventLoopID] == nil {
                self.eventLoopQueues[eventLoopID] = CircularBuffer(initialCapacity: 32)
            }
            return closure(&self.eventLoopQueues[eventLoopID]!)
        }

        private func withEventLoopQueueIfAvailable<Result>(
            for eventLoopID: EventLoopID,
            _ closure: (CircularBuffer<Request>) -> Result
        ) -> Result? {
            if let queue = self.eventLoopQueues[eventLoopID] {
                return closure(queue)
            }
            return nil
        }

        func eventLoopsWithPendingRequests() -> [EventLoop] {
            self.eventLoopQueues.compactMap { $0.value.first?.requiredEventLoop }
        }
    }
}

extension CircularBuffer {
    /// Removes up to `max` elements from the beginning of the
    /// `CircularBuffer` and returns them.
    ///
    /// Calling this method may invalidate any existing indices for use with this
    /// `CircularBuffer`.
    ///
    /// - Parameter max: The number of elements to remove.
    ///   `max` must be greater than or equal to zero.
    /// - Returns: removed elements
    ///
    /// - Complexity: O(*k*), where *k* is the number of elements removed.
    fileprivate mutating func popFirst(max: Int) -> [Element] {
        precondition(max >= 0)
        let elementCountToRemove = Swift.min(max, self.count)
        let array = Array(self[self.startIndex..<self.index(self.startIndex, offsetBy: elementCountToRemove)])
        self.removeFirst(elementCountToRemove)
        return array
    }
}
