//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the AsyncHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

@testable import AsyncHTTPClient
import NIO
import XCTest

class ConnectionTests: XCTestCase {
    var eventLoop: EmbeddedEventLoop!
    var http1ConnectionProvider: HTTP1ConnectionProvider!
    var pool: ConnectionPool!

    func buildState(connection: Connection, release: Bool) {
        XCTAssertTrue(self.http1ConnectionProvider.state.enqueue())
        let action = self.http1ConnectionProvider.state.acquire(waiter: .init(promise: self.eventLoop.makePromise(), setupComplete: self.eventLoop.makeSucceededFuture(()), preference: .indifferent))

        switch action {
        case .create(let waiter):
            waiter.promise.succeed(connection)
        default:
            XCTFail("Unexpected action: \(action)")
        }

        // We offer the connection to the pool so that it can be tracked
        _ = self.http1ConnectionProvider.state.offer(connection: connection)

        if release {
            _ = self.http1ConnectionProvider.state.release(connection: connection, closing: false)
        }
    }

    // MARK: - Connection Tests

    func testConnectionReleaseActive() throws {
        let channel = ActiveChannel(eventLoop: self.eventLoop)
        let connection = Connection(channel: channel, provider: self.http1ConnectionProvider)

        self.buildState(connection: connection, release: false)

        XCTAssertState(self.http1ConnectionProvider.state, available: 0, leased: 1, waiters: 0, pending: 0, opened: 1)

        connection.release(closing: false, logger: HTTPClient.loggingDisabled)

        // XCTAssertFalse(connection.isInUse)
        XCTAssertState(self.http1ConnectionProvider.state, available: 1, leased: 0, waiters: 0, pending: 0, opened: 1)

        // cleanup
        // this cleanup code needs to go and use HTTP1ConnectionProvider's API instead
        // (https://github.com/swift-server/async-http-client/issues/234)
        connection.remoteClosed(logger: HTTPClient.loggingDisabled)
    }

    func testConnectionReleaseInactive() throws {
        let channel = EmbeddedChannel()
        let connection = Connection(channel: channel, provider: self.http1ConnectionProvider)

        self.buildState(connection: connection, release: false)

        XCTAssertState(self.http1ConnectionProvider.state, available: 0, leased: 1, waiters: 0, pending: 0, opened: 1)

        connection.release(closing: true, logger: HTTPClient.loggingDisabled)
        XCTAssertState(self.http1ConnectionProvider.state, available: 0, leased: 0, waiters: 0, pending: 0, opened: 0)
    }

    func testConnectionRemoteCloseRelease() throws {
        let channel = ActiveChannel(eventLoop: self.eventLoop)
        let connection = Connection(channel: channel, provider: self.http1ConnectionProvider)

        self.buildState(connection: connection, release: true)

        XCTAssertState(self.http1ConnectionProvider.state, available: 1, leased: 0, waiters: 0, pending: 0, opened: 1)

        connection.remoteClosed(logger: HTTPClient.loggingDisabled)

        XCTAssertState(self.http1ConnectionProvider.state, available: 0, leased: 0, waiters: 0, pending: 0, opened: 0)
    }

    func testConnectionTimeoutRelease() throws {
        let channel = ActiveChannel(eventLoop: self.eventLoop)
        let connection = Connection(channel: channel, provider: self.http1ConnectionProvider)

        self.buildState(connection: connection, release: true)

        XCTAssertState(self.http1ConnectionProvider.state, available: 1, leased: 0, waiters: 0, pending: 0, opened: 1)

        connection.timeout(logger: HTTPClient.loggingDisabled)

        XCTAssertState(self.http1ConnectionProvider.state, available: 0, leased: 0, waiters: 0, pending: 0, opened: 0)
    }

    func testAcquireAvailableBecomesUnavailable() throws {
        let channel = ActiveChannel(eventLoop: self.eventLoop)
        let connection = Connection(channel: channel, provider: self.http1ConnectionProvider)

        self.buildState(connection: connection, release: true)

        XCTAssertState(self.http1ConnectionProvider.state, available: 1, leased: 0, waiters: 0, pending: 0, opened: 1)

        XCTAssertTrue(self.http1ConnectionProvider.enqueue())
        let action = self.http1ConnectionProvider.state.acquire(waiter: .init(promise: self.eventLoop.makePromise(), setupComplete: self.eventLoop.makeSucceededFuture(()), preference: .indifferent))
        switch action {
        case .lease(let connection, let waiter):
            // Since this connection is already in use, this should be a no-op and state should not have changed from normal lease
            connection.timeout(logger: HTTPClient.loggingDisabled)

            XCTAssertTrue(connection.isActiveEstimation)
            XCTAssertState(self.http1ConnectionProvider.state, available: 0, leased: 1, waiters: 0, pending: 0, opened: 1, isLeased: connection)

            // This is unrecoverable, but in this case we create a new connection, so state again should not change, even though release will be called
            // This is important to preventself.http1ConnectionProvider deletion since connection is released and there could be 0 waiters
            connection.remoteClosed(logger: HTTPClient.loggingDisabled)

            XCTAssertState(self.http1ConnectionProvider.state, available: 0, leased: 1, waiters: 0, pending: 0, opened: 1, isLeased: connection)

            // cleanup
            waiter.promise.fail(TempError())
            connection.release(closing: true, logger: HTTPClient.loggingDisabled)
        default:
            XCTFail("Unexpected action: \(action)")
        }
    }

    override func setUp() {
        XCTAssertNil(self.pool)
        XCTAssertNil(self.eventLoop)
        XCTAssertNil(self.http1ConnectionProvider)
        self.eventLoop = EmbeddedEventLoop()
        self.pool = ConnectionPool(configuration: .init(),
                                   backgroundActivityLogger: HTTPClient.loggingDisabled)
        XCTAssertNoThrow(self.http1ConnectionProvider =
            try HTTP1ConnectionProvider(key: .init(.init(url: "http://some.test")),
                                        eventLoop: self.eventLoop,
                                        configuration: .init(),
                                        tlsConfiguration: nil,
                                        pool: self.pool,
                                        sslContextCache: .init(),
                                        backgroundActivityLogger: HTTPClient.loggingDisabled))
    }

    override func tearDown() {
        XCTAssertNotNil(self.pool)
        XCTAssertNotNil(self.eventLoop)
        XCTAssertNotNil(self.http1ConnectionProvider)
        XCTAssertNoThrow(try self.http1ConnectionProvider.close().wait())
        XCTAssertNoThrow(try self.eventLoop.syncShutdownGracefully())
        self.http1ConnectionProvider = nil
        XCTAssertTrue(try self.pool.close(on: self.eventLoop).wait())
        self.eventLoop = nil
        self.pool = nil
    }
}

class ActiveChannel: Channel, ChannelCore {
    struct NotImplementedError: Error {}

    func localAddress0() throws -> SocketAddress {
        throw NotImplementedError()
    }

    func remoteAddress0() throws -> SocketAddress {
        throw NotImplementedError()
    }

    func register0(promise: EventLoopPromise<Void>?) {
        promise?.fail(NotImplementedError())
    }

    func bind0(to: SocketAddress, promise: EventLoopPromise<Void>?) {
        promise?.fail(NotImplementedError())
    }

    func connect0(to: SocketAddress, promise: EventLoopPromise<Void>?) {
        promise?.fail(NotImplementedError())
    }

    func write0(_ data: NIOAny, promise: EventLoopPromise<Void>?) {
        promise?.fail(NotImplementedError())
    }

    func flush0() {}

    func read0() {}

    func close0(error: Error, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        promise?.succeed(())
    }

    func triggerUserOutboundEvent0(_ event: Any, promise: EventLoopPromise<Void>?) {
        promise?.fail(NotImplementedError())
    }

    func channelRead0(_: NIOAny) {}

    func errorCaught0(error: Error) {}

    var allocator: ByteBufferAllocator
    var closeFuture: EventLoopFuture<Void>
    var eventLoop: EventLoop

    var localAddress: SocketAddress?
    var remoteAddress: SocketAddress?
    var parent: Channel?
    var isWritable: Bool = true
    var isActive: Bool = true

    init(eventLoop: EmbeddedEventLoop) {
        self.allocator = ByteBufferAllocator()
        self.eventLoop = eventLoop
        self.closeFuture = self.eventLoop.makeSucceededFuture(())
    }

    var _channelCore: ChannelCore {
        return self
    }

    var pipeline: ChannelPipeline {
        return ChannelPipeline(channel: self)
    }

    func setOption<Option>(_ option: Option, value: Option.Value) -> EventLoopFuture<Void> where Option: ChannelOption {
        preconditionFailure("Not implemented")
    }

    func getOption<Option>(_: Option) -> EventLoopFuture<Option.Value> where Option: ChannelOption {
        preconditionFailure("Not implemented")
    }
}
