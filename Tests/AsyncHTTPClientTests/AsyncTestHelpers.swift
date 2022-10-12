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

import NIOConcurrencyHelpers
import NIOCore

/// ``AsyncSequenceWriter`` is `Sendable` because its state is protected by a Lock
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
final class AsyncSequenceWriter<Element>: AsyncSequence, @unchecked Sendable {
    typealias AsyncIterator = Iterator

    struct Iterator: AsyncIteratorProtocol {
        private let writer: AsyncSequenceWriter<Element>

        init(_ writer: AsyncSequenceWriter<Element>) {
            self.writer = writer
        }

        mutating func next() async throws -> Element? {
            try await self.writer.next()
        }
    }

    func makeAsyncIterator() -> Iterator {
        return Iterator(self)
    }

    private enum State {
        case buffering(CircularBuffer<Element?>, CheckedContinuation<Void, Never>?)
        case finished
        case waiting(CheckedContinuation<Element?, Error>)
        case failed(Error, CheckedContinuation<Void, Never>?)
    }

    private var _state = State.buffering(.init(), nil)
    private let lock = NIOLock()

    public var hasDemand: Bool {
        self.lock.withLock {
            switch self._state {
            case .failed, .finished, .buffering:
                return false
            case .waiting:
                return true
            }
        }
    }

    /// Wait until a downstream consumer has issued more demand by calling `next`.
    public func demand() async {
        self.lock.lock()

        switch self._state {
        case .buffering(let buffer, .none):
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self._state = .buffering(buffer, continuation)
                self.lock.unlock()
            }

        case .waiting:
            self.lock.unlock()
            return

        case .buffering(_, .some), .failed(_, .some):
            let state = self._state
            self.lock.unlock()
            preconditionFailure("Already waiting for demand. Invalid state: \(state)")

        case .finished, .failed:
            let state = self._state
            self.lock.unlock()
            preconditionFailure("Invalid state: \(state)")
        }
    }

    private func next() async throws -> Element? {
        self.lock.lock()
        switch self._state {
        case .buffering(let buffer, let demandContinuation) where buffer.isEmpty:
            return try await withCheckedThrowingContinuation { continuation in
                self._state = .waiting(continuation)
                self.lock.unlock()
                demandContinuation?.resume(returning: ())
            }

        case .buffering(var buffer, let demandContinuation):
            let first = buffer.removeFirst()
            if first != nil {
                self._state = .buffering(buffer, demandContinuation)
            } else {
                self._state = .finished
            }
            self.lock.unlock()
            return first

        case .failed(let error, let demandContinuation):
            self._state = .finished
            self.lock.unlock()
            demandContinuation?.resume()
            throw error

        case .finished:
            self.lock.unlock()
            return nil

        case .waiting:
            let state = self._state
            self.lock.unlock()
            preconditionFailure("Expected that there is always only one concurrent call to next. Invalid state: \(state)")
        }
    }

    public func write(_ element: Element) {
        self.writeBufferOrEnd(element)
    }

    public func end() {
        self.writeBufferOrEnd(nil)
    }

    private enum WriteAction {
        case succeedContinuation(CheckedContinuation<Element?, Error>, Element?)
        case none
    }

    private func writeBufferOrEnd(_ element: Element?) {
        let writeAction = self.lock.withLock { () -> WriteAction in
            switch self._state {
            case .buffering(var buffer, let continuation):
                buffer.append(element)
                self._state = .buffering(buffer, continuation)
                return .none

            case .waiting(let continuation):
                self._state = .buffering(.init(), nil)
                return .succeedContinuation(continuation, element)

            case .finished, .failed:
                preconditionFailure("Invalid state: \(self._state)")
            }
        }

        switch writeAction {
        case .succeedContinuation(let continuation, let element):
            continuation.resume(returning: element)

        case .none:
            break
        }
    }

    private enum ErrorAction {
        case failContinuation(CheckedContinuation<Element?, Error>, Error)
        case none
    }

    /// Drops all buffered writes and emits an error on the waiting `next`. If there is no call to `next`
    /// waiting, will emit the error on the next call to `next`.
    public func fail(_ error: Error) {
        let errorAction = self.lock.withLock { () -> ErrorAction in
            switch self._state {
            case .buffering(_, let demandContinuation):
                self._state = .failed(error, demandContinuation)
                return .none

            case .failed, .finished:
                return .none

            case .waiting(let continuation):
                self._state = .finished
                return .failContinuation(continuation, error)
            }
        }

        switch errorAction {
        case .failContinuation(let checkedContinuation, let error):
            checkedContinuation.resume(throwing: error)
        case .none:
            break
        }
    }
}
