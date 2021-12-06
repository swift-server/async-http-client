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

#if swift(>=5.5) && canImport(_Concurrency)
import NIOConcurrencyHelpers
import NIOCore

@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
class AsyncSequenceWriter: AsyncSequence {
    typealias AsyncIterator = Iterator
    typealias Element = ByteBuffer

    struct Iterator: AsyncIteratorProtocol {
        typealias Element = ByteBuffer

        private let writer: AsyncSequenceWriter

        init(_ writer: AsyncSequenceWriter) {
            self.writer = writer
        }

        mutating func next() async throws -> ByteBuffer? {
            try await self.writer.next()
        }
    }

    func makeAsyncIterator() -> Iterator {
        return Iterator(self)
    }

    private enum State {
        case buffering(CircularBuffer<ByteBuffer?>, CheckedContinuation<Void, Error>?)
        case finished
        case waiting(CheckedContinuation<ByteBuffer?, Error>)
        case failed(Error)
    }

    private var _state = State.buffering(.init(), nil)
    private let lock = Lock()

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

    public func demand() async throws {
        self.lock.lock()

        switch self._state {
        case .buffering(let buffer, .none):
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self._state = .buffering(buffer, continuation)
                self.lock.unlock()
            }

        case .waiting:
            self.lock.unlock()
            return

        case .buffering(_, .some):
            self.lock.unlock()
            preconditionFailure("Already waiting for demand")

        case .finished, .failed:
            let state = self._state
            self.lock.unlock()
            preconditionFailure("Invalid state: \(state)")
        }
    }

    private func next() async throws -> ByteBuffer? {
        self.lock.lock()
        switch self._state {
        case .buffering(let buffer, let demandContinuation) where buffer.isEmpty:
            return try await withCheckedThrowingContinuation { continuation in
                self._state = .waiting(continuation)
                self.lock.unlock()
                demandContinuation?.resume(returning: ())
            }

        case .buffering(var buffer, let demandContinuation):
            let first = buffer.popFirst()!
            if first != nil {
                self._state = .buffering(buffer, demandContinuation)
            } else {
                self._state = .finished
            }
            self.lock.unlock()
            return first

        case .failed(let error):
            self._state = .finished
            self.lock.unlock()
            throw error

        case .finished:
            return nil

        case .waiting:
            preconditionFailure("How can this be called twice?!")
        }
    }

    public func write(_ byteBuffer: ByteBuffer) {
        self.writeBufferOrEnd(byteBuffer)
    }

    public func end() {
        self.writeBufferOrEnd(nil)
    }

    private func writeBufferOrEnd(_ byteBuffer: ByteBuffer?) {
        enum WriteAction {
            case succeedContinuation(CheckedContinuation<ByteBuffer?, Error>, ByteBuffer?)
            case none
        }

        let writeAction = self.lock.withLock { () -> WriteAction in
            switch self._state {
            case .buffering(var buffer, let continuation):
                buffer.append(byteBuffer)
                self._state = .buffering(buffer, continuation)
                return .none

            case .waiting(let continuation):
                self._state = .buffering(.init(), nil)
                return .succeedContinuation(continuation, byteBuffer)

            case .finished, .failed:
                preconditionFailure("Invalid state: \(self._state)")
            }
        }

        switch writeAction {
        case .succeedContinuation(let continuation, let byteBuffer):
            continuation.resume(returning: byteBuffer)

        case .none:
            break
        }
    }

    public func fail(_ error: Error) {
        enum ErrorAction {
            case failContinuation(CheckedContinuation<ByteBuffer?, Error>, Error)
            case none
        }

        let errorAction = self.lock.withLock { () -> ErrorAction in
            switch self._state {
            case .buffering:
                self._state = .failed(error)
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
#endif
