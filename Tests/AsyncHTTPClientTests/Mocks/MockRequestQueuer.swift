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

import Logging
import NIOCore
import NIOHTTP1

@testable import AsyncHTTPClient

/// A mock request queue (not creating any timers) that is used to validate
/// request actions returned by the `HTTPConnectionPool.StateMachine`.
struct MockRequestQueuer {
    enum Errors: Error {
        case requestIDNotFound
        case requestIDAlreadyUsed
        case requestIDDoesNotMatchTask
    }

    typealias RequestID = HTTPConnectionPool.Request.ID

    private struct QueuedRequest {
        let id: RequestID
        let request: HTTPSchedulableRequest
    }

    init() {
        self.waiters = [:]
    }

    private var waiters: [RequestID: QueuedRequest]

    var count: Int {
        self.waiters.count
    }

    var isEmpty: Bool {
        self.waiters.isEmpty
    }

    mutating func queue(_ request: HTTPSchedulableRequest, id: RequestID) throws {
        guard self.waiters[id] == nil else {
            throw Errors.requestIDAlreadyUsed
        }

        self.waiters[id] = QueuedRequest(id: id, request: request)
    }

    mutating func fail(_ id: RequestID, request: HTTPSchedulableRequest) throws {
        guard let waiter = self.waiters.removeValue(forKey: id) else {
            throw Errors.requestIDNotFound
        }
        guard waiter.request === request else {
            throw Errors.requestIDDoesNotMatchTask
        }
    }

    mutating func get(_ id: RequestID, request: HTTPSchedulableRequest) throws -> HTTPSchedulableRequest {
        guard let waiter = self.waiters.removeValue(forKey: id) else {
            throw Errors.requestIDNotFound
        }
        guard waiter.request === request else {
            throw Errors.requestIDDoesNotMatchTask
        }
        return waiter.request
    }

    @discardableResult
    mutating func cancel(_ id: RequestID) throws -> HTTPSchedulableRequest {
        guard let waiter = self.waiters.removeValue(forKey: id) else {
            throw Errors.requestIDNotFound
        }
        return waiter.request
    }

    mutating func timeoutRandomRequest() -> (RequestID, HTTPSchedulableRequest)? {
        guard let waiter = self.waiters.randomElement() else {
            return nil
        }
        self.waiters.removeValue(forKey: waiter.key)
        return (waiter.key, waiter.value.request)
    }
}
