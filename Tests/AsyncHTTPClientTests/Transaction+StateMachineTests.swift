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
import NIOCore
import NIOEmbedded
import XCTest

final class Transaction_StateMachineTests: XCTestCase {
    func testRequestWasQueuedAfterWillExecuteRequestWasCalled() {
        #if compiler(>=5.5) && canImport(_Concurrency)
        guard #available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *) else { return }
        let eventLoop = EmbeddedEventLoop()
        XCTAsyncTest {
            func workaround(_ continuation: CheckedContinuation<HTTPClientResponse, Error>) {
                var state = Transaction.StateMachine(continuation)
                let executor = MockRequestExecutor(eventLoop: eventLoop)
                let queuer = MockTaskQueuer()

                XCTAssertEqual(state.willExecuteRequest(executor), .none)
                state.requestWasQueued(queuer)

                let failAction = state.fail(HTTPClientError.cancelled)
                guard case .failResponseHead(_, let error, let scheduler, let rexecutor) = failAction else {
                    return XCTFail("Unexpected fail action: \(failAction)")
                }
                XCTAssertEqual(error as? HTTPClientError, .cancelled)
                XCTAssertNil(scheduler)
                XCTAssert((rexecutor as? MockRequestExecutor) === executor)

                continuation.resume(throwing: HTTPClientError.cancelled)
            }

            await XCTAssertThrowsError(try await withCheckedThrowingContinuation(workaround))
        }
        #endif
    }

    func testRequestBodyStreamWasPaused() {
        #if compiler(>=5.5) && canImport(_Concurrency)
        guard #available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *) else { return }
        let eventLoop = EmbeddedEventLoop()
        XCTAsyncTest {
            func workaround(_ continuation: CheckedContinuation<HTTPClientResponse, Error>) {
                var state = Transaction.StateMachine(continuation)
                let executor = MockRequestExecutor(eventLoop: eventLoop)

                XCTAssertEqual(state.willExecuteRequest(executor), .none)
                XCTAssertEqual(state.resumeRequestBodyStream(), .resumeStream(ByteBufferAllocator()))
                let part1 = ByteBuffer(string: "foo")
                XCTAssertEqual(state.producedNextRequestPart(part1), .write(part1, executor, continue: true))
                state.pauseRequestBodyStream()
                let part2 = ByteBuffer(string: "foo")
                XCTAssertEqual(state.producedNextRequestPart(part1), .write(part2, executor, continue: false))

                continuation.resume(throwing: HTTPClientError.cancelled)
            }

            await XCTAssertThrowsError(try await withCheckedThrowingContinuation(workaround))
        }
        #endif
    }
}

#if compiler(>=5.5) && canImport(_Concurrency)
@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
extension Transaction.StateMachine.StartExecutionAction: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none):
            return true
        case (.cancel(let lhsEx), .cancel(let rhsEx)):
            if let lhsMock = lhsEx as? MockRequestExecutor, let rhsMock = rhsEx as? MockRequestExecutor {
                return lhsMock === rhsMock
            }
            return false
        default:
            return false
        }
    }
}

@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
extension Transaction.StateMachine.ResumeProducingAction: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none):
            return true
        case (.resumeStream, .resumeStream):
            return true
        default:
            return false
        }
    }
}

@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
extension Transaction.StateMachine.NextWriteAction: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none):
            return true
        case (.write(let lhsBuffer, let lhsEx, let lhsCont), .write(let rhsBuffer, let rhsEx, let rhsCont)):
            guard lhsBuffer == rhsBuffer && lhsCont == rhsCont else {
                return false
            }
            if let lhsMock = lhsEx as? MockRequestExecutor, let rhsMock = rhsEx as? MockRequestExecutor {
                return lhsMock === rhsMock
            }
            return false
        default:
            return false
        }
    }
}
#endif
