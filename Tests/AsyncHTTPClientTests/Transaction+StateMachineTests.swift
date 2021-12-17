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
import NIOHTTP1
import XCTest

final class Transaction_StateMachineTests: XCTestCase {
    func testRequestWasQueuedAfterWillExecuteRequestWasCalled() {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        let eventLoop = EmbeddedEventLoop()
        XCTAsyncTest {
            func workaround(_ continuation: CheckedContinuation<HTTPClientResponse, Error>) {
                var state = Transaction.StateMachine(continuation)
                let executor = MockRequestExecutor(eventLoop: eventLoop)
                let queuer = MockTaskQueuer()

                XCTAssertEqual(state.willExecuteRequest(executor), .none)
                state.requestWasQueued(queuer)

                let failAction = state.fail(HTTPClientError.cancelled)
                guard case .failResponseHead(_, let error, let scheduler, let rexecutor, let bodyStreamContinuation) = failAction else {
                    return XCTFail("Unexpected fail action: \(failAction)")
                }
                XCTAssertEqual(error as? HTTPClientError, .cancelled)
                XCTAssertNil(scheduler)
                XCTAssertNil(bodyStreamContinuation)
                XCTAssert((rexecutor as? MockRequestExecutor) === executor)

                continuation.resume(throwing: HTTPClientError.cancelled)
            }

            await XCTAssertThrowsError(try await withCheckedThrowingContinuation(workaround))
        }
        #endif
    }

    func testRequestBodyStreamWasPaused() {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        let eventLoop = EmbeddedEventLoop()
        XCTAsyncTest {
            func workaround(_ continuation: CheckedContinuation<HTTPClientResponse, Error>) {
                var state = Transaction.StateMachine(continuation)
                let executor = MockRequestExecutor(eventLoop: eventLoop)

                XCTAssertEqual(state.willExecuteRequest(executor), .none)
                XCTAssertEqual(state.resumeRequestBodyStream(), .startStream(ByteBufferAllocator()))
                XCTAssertEqual(state.writeNextRequestPart(), .writeAndContinue(executor))
                state.pauseRequestBodyStream()
                XCTAssertEqual(state.writeNextRequestPart(), .writeAndWait(executor))

                continuation.resume(throwing: HTTPClientError.cancelled)
            }

            await XCTAssertThrowsError(try await withCheckedThrowingContinuation(workaround))
        }
        #endif
    }

    func testQueuedRequestGetsRemovedWhenDeadlineExceeded() {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest {
            func workaround(_ continuation: CheckedContinuation<HTTPClientResponse, Error>) {
                var state = Transaction.StateMachine(continuation)
                let queuer = MockTaskQueuer()

                state.requestWasQueued(queuer)

                let failAction = state.deadlineExceeded()
                guard case .cancel(let continuation, let scheduler, nil, nil) = failAction else {
                    return XCTFail("Unexpected fail action: \(failAction)")
                }
                XCTAssertIdentical(scheduler as? MockTaskQueuer, queuer)

                continuation.resume(throwing: HTTPClientError.deadlineExceeded)
            }

            await XCTAssertThrowsError(try await withCheckedThrowingContinuation(workaround))
        }
        #endif
    }

    func testScheduledRequestGetsRemovedWhenDeadlineExceeded() {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        let eventLoop = EmbeddedEventLoop()
        XCTAsyncTest {
            func workaround(_ continuation: CheckedContinuation<HTTPClientResponse, Error>) {
                var state = Transaction.StateMachine(continuation)
                let executor = MockRequestExecutor(eventLoop: eventLoop)
                let queuer = MockTaskQueuer()

                XCTAssertEqual(state.willExecuteRequest(executor), .none)
                state.requestWasQueued(queuer)

                let failAction = state.deadlineExceeded()
                guard case .cancel(let continuation, nil, let rexecutor, nil) = failAction else {
                    return XCTFail("Unexpected fail action: \(failAction)")
                }
                XCTAssertIdentical(rexecutor as? MockRequestExecutor, executor)

                continuation.resume(throwing: HTTPClientError.deadlineExceeded)
            }

            await XCTAssertThrowsError(try await withCheckedThrowingContinuation(workaround))
        }
        #endif
    }

    func testRequestWithHeadReceivedGetNotCancelledWhenDeadlineExceeded() {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        let eventLoop = EmbeddedEventLoop()
        XCTAsyncTest {
            func workaround(_ continuation: CheckedContinuation<HTTPClientResponse, Error>) {
                var state = Transaction.StateMachine(continuation)
                let executor = MockRequestExecutor(eventLoop: eventLoop)
                let queuer = MockTaskQueuer()

                XCTAssertEqual(state.willExecuteRequest(executor), .none)
                state.requestWasQueued(queuer)
                let head = HTTPResponseHead(version: .http1_1, status: .ok)
                let receiveResponseHeadAction = state.receiveResponseHead(head)
                guard case .succeedResponseHead(head, let continuation) = receiveResponseHeadAction else {
                    return XCTFail("Unexpected action: \(receiveResponseHeadAction)")
                }

                let failAction = state.deadlineExceeded()
                guard case .none = failAction else {
                    return XCTFail("Unexpected fail action: \(failAction)")
                }
                continuation.resume(throwing: HTTPClientError.deadlineExceeded)
            }

            await XCTAssertThrowsError(try await withCheckedThrowingContinuation(workaround))
        }
        #endif
    }
}

#if compiler(>=5.5.2) && canImport(_Concurrency)
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
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

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension Transaction.StateMachine.ResumeProducingAction: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none):
            return true
        case (.resumeStream, .resumeStream):
            return true
        case (.startStream, .startStream):
            return true
        default:
            return false
        }
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension Transaction.StateMachine.NextWriteAction: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.writeAndWait(let lhsEx), .writeAndWait(let rhsEx)),
             (.writeAndContinue(let lhsEx), .writeAndContinue(let rhsEx)):
            if let lhsMock = lhsEx as? MockRequestExecutor, let rhsMock = rhsEx as? MockRequestExecutor {
                return lhsMock === rhsMock
            }
            return false
        case (.fail, .fail):
            return true
        default:
            return false
        }
    }
}
#endif
