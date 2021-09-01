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
        private var generalPurposeQueue: CircularBuffer<Request>
        private var eventLoopQueues: [EventLoopID: CircularBuffer<Request>]

        init() {
            self.generalPurposeQueue = CircularBuffer(initialCapacity: 32)
            self.eventLoopQueues = [:]
            self.count = 0
        }

        private(set) var count: Int

        var isEmpty: Bool {
            self.count == 0
        }

        func count(for eventLoop: EventLoop?) -> Int {
            if let eventLoop = eventLoop {
                return self.withEventLoopQueueIfAvailable(for: eventLoop.id) { $0.count } ?? 0
            }
            return self.generalPurposeQueue.count
        }

        func isEmpty(for eventLoop: EventLoop?) -> Bool {
            if let eventLoop = eventLoop {
                return self.withEventLoopQueueIfAvailable(for: eventLoop.id) { $0.isEmpty } ?? true
            }
            return self.generalPurposeQueue.isEmpty
        }

        @discardableResult
        mutating func push(_ request: Request) -> Request.ID {
            self.count += 1
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
            let request: Request?
            if let eventLoop = eventLoop {
                request = self.withEventLoopQueue(for: eventLoop.id) { queue in
                    queue.popFirst()
                }
            } else {
                request = self.generalPurposeQueue.popFirst()
            }
            if request != nil {
                self.count -= 1
            }
            return request
        }

        mutating func remove(_ requestID: Request.ID) -> Request? {
            let request: Request?
            if let eventLoopID = requestID.eventLoopID {
                request = self.withEventLoopQueue(for: eventLoopID) { queue in
                    guard let index = queue.firstIndex(where: { $0.id == requestID }) else {
                        return nil
                    }
                    return queue.remove(at: index)
                }
            } else {
                if let index = self.generalPurposeQueue.firstIndex(where: { $0.id == requestID }) {
                    // TBD: This is slow. Do we maybe want something more sophisticated here?
                    request = self.generalPurposeQueue.remove(at: index)
                } else {
                    request = nil
                }
            }
            if request != nil {
                self.count -= 1
            }
            return request
        }

        mutating func removeAll() -> [Request] {
            var result = [Request]()
            result = self.eventLoopQueues.flatMap { $0.value }
            result.append(contentsOf: self.generalPurposeQueue)

            self.eventLoopQueues.removeAll()
            self.generalPurposeQueue.removeAll()
            self.count = 0
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
            if self.eventLoopQueues[eventLoopID] != nil {
                return closure(self.eventLoopQueues[eventLoopID]!)
            }
            return nil
        }
    }
}
