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
final class AsyncSequenceWriter<Element: Sendable>: AsyncSequence, @unchecked Sendable {
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
        Iterator(self)
    }

    private enum State {
        case buffering(CircularBuffer<Element?>, CheckedContinuation<Void, Never>?)
        case finished
        case waiting(CheckedContinuation<Element?, Error>)
        case failed(Error, CheckedContinuation<Void, Never>?)
    }

    private let state = NIOLockedValueBox<State>(.buffering([], nil))

    public var hasDemand: Bool {
        self.state.withLockedValue { state in
            switch state {
            case .failed, .finished, .buffering:
                return false
            case .waiting:
                return true
            }
        }
    }

    /// Wait until a downstream consumer has issued more demand by calling `next`.
    public func demand() async {
        let shouldBuffer = self.state.withLockedValue { state in
            switch state {
            case .buffering(_, .none):
                return true
            case .waiting:
                return false
            case .buffering(_, .some), .failed(_, .some):
                preconditionFailure("Already waiting for demand. Invalid state: \(state)")
            case .finished, .failed:
                preconditionFailure("Invalid state: \(state)")
            }
        }

        if shouldBuffer {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let shouldResumeContinuation = self.state.withLockedValue { state in
                    switch state {
                    case .buffering(let buffer, .none):
                        state = .buffering(buffer, continuation)
                        return false
                    case .waiting:
                        return true
                    case .buffering(_, .some), .failed(_, .some):
                        preconditionFailure("Already waiting for demand. Invalid state: \(state)")
                    case .finished, .failed:
                        preconditionFailure("Invalid state: \(state)")
                    }
                }

                if shouldResumeContinuation {
                    continuation.resume()
                }
            }
        }
    }

    private enum NextAction {
        /// Resume the continuation if present, and return the result if present.
        case resumeAndReturn(CheckedContinuation<Void, Never>?, Result<Element?, Error>?)
        /// Suspend the current task and wait for the next value.
        case suspend
    }

    private func next() async throws -> Element? {
        let action: NextAction = self.state.withLockedValue { state in
            switch state {
            case .buffering(var buffer, let demandContinuation):
                if buffer.isEmpty {
                    return .suspend
                } else {
                    let first = buffer.removeFirst()
                    if first != nil {
                        state = .buffering(buffer, demandContinuation)
                    } else {
                        state = .finished
                    }
                    return .resumeAndReturn(nil, .success(first))
                }

            case .failed(let error, let demandContinuation):
                state = .finished
                return .resumeAndReturn(demandContinuation, .failure(error))

            case .finished:
                return .resumeAndReturn(nil, .success(nil))

            case .waiting:
                preconditionFailure(
                    "Expected that there is always only one concurrent call to next. Invalid state: \(state)"
                )
            }
        }

        switch action {
        case .resumeAndReturn(let demandContinuation, let result):
            demandContinuation?.resume()
            return try result?.get()

        case .suspend:
            // Holding the lock here *should* be safe but because of a bug in the runtime
            // it isn't, so drop the lock, create the continuation and then try again.
            //
            // See https://github.com/swiftlang/swift/issues/85668
            return try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Element?, any Error>) in
                let action: NextAction = self.state.withLockedValue { state in
                    switch state {
                    case .buffering(var buffer, let demandContinuation):
                        if buffer.isEmpty {
                            state = .waiting(continuation)
                            return .resumeAndReturn(demandContinuation, nil)
                        } else {
                            let first = buffer.removeFirst()
                            if first != nil {
                                state = .buffering(buffer, demandContinuation)
                            } else {
                                state = .finished
                            }
                            return .resumeAndReturn(nil, .success(first))
                        }

                    case .failed(let error, let demandContinuation):
                        state = .finished
                        return .resumeAndReturn(demandContinuation, .failure(error))

                    case .finished:
                        return .resumeAndReturn(nil, .success(nil))

                    case .waiting:
                        preconditionFailure(
                            "Expected that there is always only one concurrent call to next. Invalid state: \(state)"
                        )
                    }
                }

                switch action {
                case .resumeAndReturn(let demandContinuation, let result):
                    demandContinuation?.resume()
                    // Resume the continuation rather than returning th result.
                    if let result {
                        continuation.resume(with: result)
                    }
                case .suspend:
                    preconditionFailure()  // Not returned from the code above.
                }
            }
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
        let writeAction = self.state.withLockedValue { state -> WriteAction in
            switch state {
            case .buffering(var buffer, let continuation):
                buffer.append(element)
                state = .buffering(buffer, continuation)
                return .none

            case .waiting(let continuation):
                state = .buffering(.init(), nil)
                return .succeedContinuation(continuation, element)

            case .finished, .failed:
                preconditionFailure("Invalid state: \(state)")
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
        let errorAction = self.state.withLockedValue { state -> ErrorAction in
            switch state {
            case .buffering(_, let demandContinuation):
                state = .failed(error, demandContinuation)
                return .none

            case .failed, .finished:
                return .none

            case .waiting(let continuation):
                state = .finished
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
