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
        }

        var count: Int {
            self.generalPurposeQueue.count
        }

        var isEmpty: Bool {
            self.generalPurposeQueue.isEmpty
        }

        mutating func count(for eventLoop: EventLoop?) -> Int {
            if let eventLoop = eventLoop {
                return self.withEventLoopQueue(for: eventLoop.id) { $0.count }
            }
            return self.generalPurposeQueue.count
        }

        mutating func isEmpty(for eventLoop: EventLoop?) -> Bool {
            if let eventLoop = eventLoop {
                return self.withEventLoopQueue(for: eventLoop.id) { $0.isEmpty }
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
            }
            return self.generalPurposeQueue.popFirst()
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
            result = self.eventLoopQueues.reduce(into: result) { partialResult, element in
                element.value.forEach { request in
                    partialResult.append(request)
                }
            }

            self.generalPurposeQueue.forEach { request in
                result.append(request)
            }

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
    }
}
