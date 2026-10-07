//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2026 Apple Inc. and the AsyncHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore
import NIOEmbedded
import XCTest

@testable import AsyncHTTPClient

final class HTTPConnectionPool_HTTP2SoftLimitTests: XCTestCase {
    private typealias State = HTTPConnectionPool.StateMachine
    private typealias Connection = HTTPConnectionPool.Connection

    private func makeState(limit: Int = 2, preferHTTP1: Bool = false, http1Limit: Int = 8) -> State {
        State(
            idGenerator: .init(),
            maximumConcurrentHTTP1Connections: http1Limit,
            maximumConcurrentHTTP2Connections: limit,
            retryConnectionEstablishment: true,
            preferHTTP1: preferHTTP1,
            maximumConnectionUses: nil,
            preWarmedHTTP1ConnectionCount: 0
        )
    }

    private func request(on eventLoop: EventLoop, required: Bool = false) -> HTTPConnectionPool.Request {
        HTTPConnectionPool.Request(
            MockHTTPScheduableRequest(eventLoop: eventLoop, requiresEventLoopForChannel: required)
        )
    }

    private func createdConnection(
        _ action: State.Action,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Connection {
        guard case .createConnection(let id, let eventLoop) = action.connection else {
            XCTFail("Expected connection creation, got \(action.connection)", file: file, line: line)
            throw HTTPClientError.connectTimeout
        }
        return .__testOnly_connection(id: id, eventLoop: eventLoop)
    }

    func testSaturatedConnectionExpandsButRespectsSoftLimit() throws {
        let eventLoop = EmbeddedEventLoop()
        var state = self.makeState()
        let first = try self.createdConnection(state.executeRequest(self.request(on: eventLoop)))
        _ = state.newHTTP2ConnectionCreated(first, maxConcurrentStreams: 1)

        let secondRequest = self.request(on: eventLoop)
        let second = try self.createdConnection(state.executeRequest(secondRequest))
        XCTAssertEqual(state.executeRequest(self.request(on: eventLoop)).connection, .none)
        XCTAssertEqual(
            state.newHTTP2ConnectionCreated(second, maxConcurrentStreams: 1).request,
            .executeRequestsAndCancelTimeouts([secondRequest], second)
        )
        XCTAssertEqual(state.executeRequest(self.request(on: eventLoop)).connection, .none)
    }

    func testInitialQueuedBurstExpandsAfterSettingsAndReusesAvailableStreams() throws {
        let eventLoop = EmbeddedEventLoop()
        var state = self.makeState()
        let first = try self.createdConnection(state.executeRequest(self.request(on: eventLoop)))
        let queued = (0..<4).map { _ in self.request(on: eventLoop) }
        for request in queued {
            XCTAssertEqual(state.executeRequest(request).connection, .none)
        }

        let established = state.newHTTP2ConnectionCreated(first, maxConcurrentStreams: 2)
        let second = try self.createdConnection(established)
        XCTAssertEqual(
            state.newHTTP2ConnectionCreated(second, maxConcurrentStreams: 4).request,
            .executeRequestsAndCancelTimeouts(Array(queued.suffix(3)), second)
        )
        let nextRequest = self.request(on: eventLoop)
        XCTAssertEqual(
            state.executeRequest(nextRequest).request,
            .executeRequest(nextRequest, second, cancelTimeout: false)
        )
        XCTAssertEqual(state.executeRequest(self.request(on: eventLoop)).connection, .none)
    }

    func testLimitIsSharedAcrossPreferredEventLoopsAndRequiredLoopsCanOverflow() throws {
        let loops = (0..<3).map { _ in EmbeddedEventLoop() }
        var state = self.makeState()
        let first = try self.createdConnection(state.executeRequest(self.request(on: loops[0])))
        _ = state.newHTTP2ConnectionCreated(first, maxConcurrentStreams: 1)
        let second = try self.createdConnection(state.executeRequest(self.request(on: loops[1])))
        _ = state.newHTTP2ConnectionCreated(second, maxConcurrentStreams: 1)
        XCTAssertEqual(state.executeRequest(self.request(on: loops[2])).connection, .none)

        let required = self.request(on: loops[2], required: true)
        let overflow = try self.createdConnection(state.executeRequest(required))
        XCTAssertTrue(overflow.eventLoop === loops[2])
        XCTAssertEqual(
            state.newHTTP2ConnectionCreated(overflow, maxConcurrentStreams: 1).request,
            .executeRequestsAndCancelTimeouts([required], overflow)
        )
        XCTAssertEqual(state.executeRequest(self.request(on: loops[2], required: true)).connection, .none)
    }

    func testRequiredLoopCanExpandWithinLimitWithoutUsingOtherLoopsStreams() throws {
        let firstLoop = EmbeddedEventLoop()
        let requiredLoop = EmbeddedEventLoop()
        var state = self.makeState(limit: 3)
        let first = try self.createdConnection(state.executeRequest(self.request(on: firstLoop)))
        _ = state.newHTTP2ConnectionCreated(first, maxConcurrentStreams: 100)
        let second = try self.createdConnection(state.executeRequest(self.request(on: requiredLoop, required: true)))
        _ = state.newHTTP2ConnectionCreated(second, maxConcurrentStreams: 1)
        let third = try self.createdConnection(state.executeRequest(self.request(on: requiredLoop, required: true)))
        XCTAssertTrue(third.eventLoop === requiredLoop)
        XCTAssertEqual(state.executeRequest(self.request(on: requiredLoop, required: true)).connection, .none)
    }

    func testFailedExpansionRetriesOnlyWhileDemandRemains() throws {
        for cancelRequest in [false, true] {
            let eventLoop = EmbeddedEventLoop()
            var state = self.makeState()
            let first = try self.createdConnection(state.executeRequest(self.request(on: eventLoop)))
            _ = state.newHTTP2ConnectionCreated(first, maxConcurrentStreams: 1)
            let pending = self.request(on: eventLoop)
            let second = try self.createdConnection(state.executeRequest(pending))
            guard
                case .scheduleBackoffTimer = state.failedToCreateNewConnection(
                    HTTPClientError.connectTimeout,
                    connectionID: second.id
                ).connection
            else {
                return XCTFail("Expected a backoff timer")
            }
            if cancelRequest {
                _ = state.cancelRequest(pending.id)
                XCTAssertEqual(state.connectionCreationBackoffDone(second.id), .none)
            } else {
                let retry = try self.createdConnection(state.connectionCreationBackoffDone(second.id))
                XCTAssertNotEqual(retry.id, second.id)
                XCTAssertEqual(
                    state.newHTTP2ConnectionCreated(retry, maxConcurrentStreams: 1).request,
                    .executeRequestsAndCancelTimeouts([pending], retry)
                )
            }
        }
    }

    func testZeroStreamsCanExpandAndLaterSettingsDrainQueuedRequests() throws {
        let eventLoop = EmbeddedEventLoop()
        var state = self.makeState()
        let pending = self.request(on: eventLoop)
        let first = try self.createdConnection(state.executeRequest(pending))
        let zeroStreams = state.newHTTP2ConnectionCreated(first, maxConcurrentStreams: 0)
        guard
            case .scheduleTimeoutTimerAndCreateConnection(let timeoutID, let newID, let loop) =
                zeroStreams.connection
        else {
            return XCTFail("Expected idle timeout and another connection, got \(zeroStreams.connection)")
        }
        XCTAssertEqual(timeoutID, first.id)
        XCTAssertEqual(zeroStreams.request, .none)
        XCTAssertEqual(
            state.newHTTP2MaxConcurrentStreamsReceived(first.id, newMaxStreams: 1).request,
            .executeRequestsAndCancelTimeouts([pending], first)
        )
        let second = Connection.__testOnly_connection(id: newID, eventLoop: loop)
        let lateEstablishment = state.newHTTP2ConnectionCreated(second, maxConcurrentStreams: 1)
        XCTAssertEqual(lateEstablishment.request, .none)
        XCTAssertEqual(lateEstablishment.connection, .scheduleTimeoutTimer(second.id, on: loop))
        XCTAssertEqual(
            state.connectionIdleTimeout(second.id, on: loop).connection,
            .closeConnection(second, isShutdown: .no)
        )
    }

    func testGoAwayReplacesCapacityWithoutDuplicateCreation() throws {
        let eventLoop = EmbeddedEventLoop()
        var state = self.makeState()
        let first = try self.createdConnection(state.executeRequest(self.request(on: eventLoop)))
        _ = state.newHTTP2ConnectionCreated(first, maxConcurrentStreams: 1)
        let second = try self.createdConnection(state.executeRequest(self.request(on: eventLoop)))
        _ = state.newHTTP2ConnectionCreated(second, maxConcurrentStreams: 1)
        let pending = self.request(on: eventLoop)
        XCTAssertEqual(state.executeRequest(pending).connection, .none)
        let replacement = try self.createdConnection(state.http2ConnectionGoAwayReceived(first.id))
        XCTAssertEqual(state.http2ConnectionGoAwayReceived(first.id), .none)
        XCTAssertEqual(
            state.newHTTP2ConnectionCreated(replacement, maxConcurrentStreams: 1).request,
            .executeRequestsAndCancelTimeouts([pending], replacement)
        )
    }

    func testShutdownWaitsForActiveAndStartingConnectionsWithoutExpanding() throws {
        let eventLoop = EmbeddedEventLoop()
        var state = self.makeState(limit: 3)
        let first = try self.createdConnection(state.executeRequest(self.request(on: eventLoop)))
        _ = state.newHTTP2ConnectionCreated(first, maxConcurrentStreams: 1)
        let pending = self.request(on: eventLoop)
        let second = try self.createdConnection(state.executeRequest(pending))
        XCTAssertEqual(
            state.shutdown().request,
            .failRequestsAndCancelTimeouts([pending], HTTPClientError.cancelled)
        )
        XCTAssertEqual(
            state.newHTTP2ConnectionCreated(second, maxConcurrentStreams: 1).connection,
            .closeConnection(second, isShutdown: .no)
        )
        XCTAssertEqual(
            state.http2ConnectionStreamClosed(first.id).connection,
            .closeConnection(first, isShutdown: .yes(unclean: true))
        )
    }

    func testHTTP1MigrationCanKeepMoreThanOneHTTP2ConnectionUpToLimit() throws {
        let eventLoop = EmbeddedEventLoop()
        var state = self.makeState(preferHTTP1: true)
        let first = try self.createdConnection(state.executeRequest(self.request(on: eventLoop)))
        let second = try self.createdConnection(state.executeRequest(self.request(on: eventLoop)))
        let third = try self.createdConnection(state.executeRequest(self.request(on: eventLoop)))
        _ = state.newHTTP2ConnectionCreated(first, maxConcurrentStreams: 1)
        let secondEstablished = state.newHTTP2ConnectionCreated(second, maxConcurrentStreams: 1)
        XCTAssertEqual(secondEstablished.connection, .none)
        guard case .executeRequestsAndCancelTimeouts = secondEstablished.request else {
            return XCTFail("Expected requests on the second connection")
        }
        XCTAssertEqual(
            state.newHTTP2ConnectionCreated(third, maxConcurrentStreams: 1).connection,
            .closeConnection(third, isShutdown: .no)
        )
    }

    func testHTTP1MigrationPreservesExpansionForQueuedBurst() throws {
        let eventLoop = EmbeddedEventLoop()
        var state = self.makeState(preferHTTP1: true, http1Limit: 1)
        let first = try self.createdConnection(state.executeRequest(self.request(on: eventLoop)))
        let pending = self.request(on: eventLoop)
        XCTAssertEqual(state.executeRequest(pending).connection, .none)
        let migration = state.newHTTP2ConnectionCreated(first, maxConcurrentStreams: 1)
        guard case .migration(let created, let closed, let timeout) = migration.connection else {
            return XCTFail("Expected migration, got \(migration.connection)")
        }
        XCTAssertEqual(created.count, 1)
        XCTAssertTrue(closed.isEmpty)
        XCTAssertNil(timeout)
        let creation = try XCTUnwrap(created.first)
        let second = Connection.__testOnly_connection(id: creation.0, eventLoop: creation.1)
        XCTAssertEqual(
            state.newHTTP2ConnectionCreated(second, maxConcurrentStreams: 1).request,
            .executeRequestsAndCancelTimeouts([pending], second)
        )
    }

    func testDefaultLimitRetriesWithoutWaitingForOtherMigrationBackoffs() throws {
        let eventLoop = EmbeddedEventLoop()
        var state = self.makeState(limit: 1, preferHTTP1: true)
        let first = try self.createdConnection(state.executeRequest(self.request(on: eventLoop)))
        let second = try self.createdConnection(state.executeRequest(self.request(on: eventLoop)))
        let third = try self.createdConnection(state.executeRequest(self.request(on: eventLoop)))
        _ = state.failedToCreateNewConnection(HTTPClientError.connectTimeout, connectionID: second.id)
        _ = state.failedToCreateNewConnection(HTTPClientError.connectTimeout, connectionID: third.id)
        _ = state.newHTTP2ConnectionCreated(first, maxConcurrentStreams: 1)

        // A backing-off attempt cannot serve the queued requests. Losing the only active
        // connection should therefore start a replacement immediately, as with the default pool.
        let replacement = try self.createdConnection(state.http2ConnectionClosed(first.id))
        XCTAssertNotEqual(replacement.id, first.id)
        // Other timers must not create duplicate attempts while that replacement is starting.
        XCTAssertEqual(state.connectionCreationBackoffDone(second.id), .none)
        XCTAssertEqual(state.connectionCreationBackoffDone(third.id), .none)
    }

    func testSettingsDecreaseDoesNotInvalidateLeasedStreamsOrExceedLimit() throws {
        let eventLoop = EmbeddedEventLoop()
        var state = self.makeState()
        let first = try self.createdConnection(state.executeRequest(self.request(on: eventLoop)))
        _ = state.newHTTP2ConnectionCreated(first, maxConcurrentStreams: 2)
        _ = state.executeRequest(self.request(on: eventLoop))
        XCTAssertEqual(state.newHTTP2MaxConcurrentStreamsReceived(first.id, newMaxStreams: 0), .none)
        let second = try self.createdConnection(state.executeRequest(self.request(on: eventLoop)))
        _ = state.newHTTP2ConnectionCreated(second, maxConcurrentStreams: 1)
        let pending = self.request(on: eventLoop)
        XCTAssertEqual(state.executeRequest(pending).connection, .none)
        XCTAssertEqual(state.http2ConnectionStreamClosed(first.id), .none)
        XCTAssertEqual(
            state.newHTTP2MaxConcurrentStreamsReceived(first.id, newMaxStreams: 2).request,
            .executeRequestsAndCancelTimeouts([pending], first)
        )
    }

    func testDefaultLimitPreservesSingleConnectionAndRequiredLoopException() throws {
        XCTAssertEqual(HTTPClient.Configuration.ConnectionPool().concurrentHTTP2ConnectionsPerHostSoftLimit, 1)
        let firstLoop = EmbeddedEventLoop()
        let otherLoop = EmbeddedEventLoop()
        var state = self.makeState(limit: 1)
        let first = try self.createdConnection(state.executeRequest(self.request(on: firstLoop)))
        _ = state.newHTTP2ConnectionCreated(first, maxConcurrentStreams: 1)
        XCTAssertEqual(state.executeRequest(self.request(on: otherLoop)).connection, .none)
        let required = self.request(on: otherLoop, required: true)
        let overflow = try self.createdConnection(state.executeRequest(required))
        XCTAssertEqual(
            state.newHTTP2ConnectionCreated(overflow, maxConcurrentStreams: 1).request,
            .executeRequestsAndCancelTimeouts([required], overflow)
        )
    }

    func testIdleTimeoutExpandsForQueuedRequestsOnAnotherRequiredEventLoop() throws {
        let idleLoop = EmbeddedEventLoop()
        let busyLoop = EmbeddedEventLoop()
        var state = self.makeState()
        let idle = try self.createdConnection(state.executeRequest(self.request(on: idleLoop)))
        _ = state.newHTTP2ConnectionCreated(idle, maxConcurrentStreams: 1)
        _ = state.http2ConnectionStreamClosed(idle.id)
        let busy = try self.createdConnection(state.executeRequest(self.request(on: busyLoop, required: true)))
        _ = state.newHTTP2ConnectionCreated(busy, maxConcurrentStreams: 1)
        let pending = self.request(on: busyLoop, required: true)
        XCTAssertEqual(state.executeRequest(pending).connection, .none)

        let timeout = state.connectionIdleTimeout(idle.id, on: idleLoop)
        guard case .closeConnectionAndCreateConnection(let closed, let newID, let loop) = timeout.connection else {
            return XCTFail("Expected replacement on the busy event loop, got \(timeout.connection)")
        }
        XCTAssertEqual(closed, idle)
        XCTAssertTrue(loop === busyLoop)
        let additional = Connection.__testOnly_connection(id: newID, eventLoop: loop)
        XCTAssertEqual(
            state.newHTTP2ConnectionCreated(additional, maxConcurrentStreams: 1).request,
            .executeRequestsAndCancelTimeouts([pending], additional)
        )
    }

    func testUnexpectedCloseExpandsForQueuedRequestsOnAnotherRequiredEventLoop() throws {
        let closingLoop = EmbeddedEventLoop()
        let busyLoop = EmbeddedEventLoop()
        var state = self.makeState()
        let closing = try self.createdConnection(state.executeRequest(self.request(on: closingLoop)))
        _ = state.newHTTP2ConnectionCreated(closing, maxConcurrentStreams: 1)
        let busy = try self.createdConnection(state.executeRequest(self.request(on: busyLoop, required: true)))
        _ = state.newHTTP2ConnectionCreated(busy, maxConcurrentStreams: 1)
        let pending = self.request(on: busyLoop, required: true)
        XCTAssertEqual(state.executeRequest(pending).connection, .none)

        let additional = try self.createdConnection(state.http2ConnectionClosed(closing.id))
        XCTAssertTrue(additional.eventLoop === busyLoop)
        XCTAssertEqual(
            state.newHTTP2ConnectionCreated(additional, maxConcurrentStreams: 1).request,
            .executeRequestsAndCancelTimeouts([pending], additional)
        )
    }
}
