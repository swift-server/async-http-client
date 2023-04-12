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
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOPosix
import NIOSSL
import NIOTestUtils
import XCTest

class HTTP2ConnectionTests: XCTestCase {
    func testCreateNewConnectionFailureClosedIO() {
        let embedded = EmbeddedChannel()

        XCTAssertNoThrow(try embedded.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 3000)).wait())
        XCTAssertNoThrow(try embedded.close().wait())
        // to really destroy the channel we need to tick once
        embedded.embeddedEventLoop.run()
        let logger = Logger(label: "test.http2.connection")

        XCTAssertThrowsError(try HTTP2Connection.start(
            channel: embedded,
            connectionID: 0,
            delegate: TestHTTP2ConnectionDelegate(),
            decompression: .disabled,
            maximumConnectionUses: nil,
            logger: logger
        ).wait())
    }

    func testConnectionToleratesShutdownEventsAfterAlreadyClosed() {
        let embedded = EmbeddedChannel()
        XCTAssertNoThrow(try embedded.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 3000)).wait())

        let logger = Logger(label: "test.http2.connection")
        let connection = HTTP2Connection(
            channel: embedded,
            connectionID: 0,
            decompression: .disabled,
            maximumConnectionUses: nil,
            delegate: TestHTTP2ConnectionDelegate(),
            logger: logger
        )
        let startFuture = connection._start0()

        XCTAssertNoThrow(try embedded.close().wait())
        // to really destroy the channel we need to tick once
        embedded.embeddedEventLoop.run()

        XCTAssertThrowsError(try startFuture.wait())

        // should not crash
        connection.shutdown()
    }

    func testSimpleGetRequest() {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = eventLoopGroup.next()
        defer { XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully()) }

        let httpBin = HTTPBin(.http2(compress: false))
        defer { XCTAssertNoThrow(try httpBin.shutdown()) }

        let connectionCreator = TestConnectionCreator()
        let delegate = TestHTTP2ConnectionDelegate()
        var maybeHTTP2Connection: HTTP2Connection?
        XCTAssertNoThrow(maybeHTTP2Connection = try connectionCreator.createHTTP2Connection(
            to: httpBin.port,
            delegate: delegate,
            on: eventLoop
        )
        )
        guard let http2Connection = maybeHTTP2Connection else {
            return XCTFail("Expected to have an HTTP2 connection here.")
        }

        var maybeRequest: HTTPClient.Request?
        var maybeRequestBag: RequestBag<ResponseAccumulator>?
        XCTAssertNoThrow(maybeRequest = try HTTPClient.Request(url: "https://localhost:\(httpBin.port)"))
        XCTAssertNoThrow(maybeRequestBag = try RequestBag(
            request: XCTUnwrap(maybeRequest),
            eventLoopPreference: .indifferent,
            task: .init(eventLoop: eventLoop, logger: .init(label: "test")),
            redirectHandler: nil,
            connectionDeadline: .distantFuture,
            requestOptions: .forTests(),
            delegate: ResponseAccumulator(request: XCTUnwrap(maybeRequest))
        ))
        guard let requestBag = maybeRequestBag else {
            return XCTFail("Expected to have a request bag at this point")
        }

        http2Connection.executeRequest(requestBag)

        XCTAssertEqual(delegate.hitStreamClosed, 0)
        var maybeResponse: HTTPClient.Response?
        XCTAssertNoThrow(maybeResponse = try requestBag.task.futureResult.wait())
        XCTAssertEqual(maybeResponse?.status, .ok)
        XCTAssertEqual(maybeResponse?.version, .http2)
        XCTAssertEqual(delegate.hitStreamClosed, 1)
    }

    func testEveryDoneRequestLeadsToAStreamAvailableCall() {
        class NeverRespondChannelHandler: ChannelInboundHandler {
            typealias InboundIn = HTTPServerRequestPart
            typealias OutboundOut = HTTPServerResponsePart

            init() {}

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {}
        }

        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = eventLoopGroup.next()
        defer { XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully()) }

        let httpBin = HTTPBin(.http2(compress: false))
        defer { XCTAssertNoThrow(try httpBin.shutdown()) }

        let connectionCreator = TestConnectionCreator()
        let delegate = TestHTTP2ConnectionDelegate()
        var maybeHTTP2Connection: HTTP2Connection?
        XCTAssertNoThrow(maybeHTTP2Connection = try connectionCreator.createHTTP2Connection(
            to: httpBin.port,
            delegate: delegate,
            on: eventLoop
        ))
        guard let http2Connection = maybeHTTP2Connection else {
            return XCTFail("Expected to have an HTTP2 connection here.")
        }
        defer { XCTAssertNoThrow(try http2Connection.close().wait()) }

        var futures = [EventLoopFuture<HTTPClient.Response>]()

        XCTAssertEqual(delegate.hitStreamClosed, 0)

        for _ in 0..<100 {
            var maybeRequest: HTTPClient.Request?
            var maybeRequestBag: RequestBag<ResponseAccumulator>?
            XCTAssertNoThrow(maybeRequest = try HTTPClient.Request(url: "https://localhost:\(httpBin.port)"))
            XCTAssertNoThrow(maybeRequestBag = try RequestBag(
                request: XCTUnwrap(maybeRequest),
                eventLoopPreference: .indifferent,
                task: .init(eventLoop: eventLoop, logger: .init(label: "test")),
                redirectHandler: nil,
                connectionDeadline: .distantFuture,
                requestOptions: .forTests(),
                delegate: ResponseAccumulator(request: XCTUnwrap(maybeRequest))
            ))
            guard let requestBag = maybeRequestBag else {
                return XCTFail("Expected to have a request bag at this point")
            }

            http2Connection.executeRequest(requestBag)

            futures.append(requestBag.task.futureResult)
        }

        for future in futures {
            XCTAssertNoThrow(try future.wait())
        }

        XCTAssertEqual(delegate.hitStreamClosed, 100)
        XCTAssertTrue(http2Connection.channel.isActive)
    }

    func testCancelAllRunningRequests() {
        class NeverRespondChannelHandler: ChannelInboundHandler {
            typealias InboundIn = HTTPServerRequestPart
            typealias OutboundOut = HTTPServerResponsePart

            init() {}

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {}
        }

        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = eventLoopGroup.next()
        defer { XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully()) }

        let httpBin = HTTPBin(.http2(compress: false), handlerFactory: { _ in NeverRespondChannelHandler() })
        defer { XCTAssertNoThrow(try httpBin.shutdown()) }

        let connectionCreator = TestConnectionCreator()
        let delegate = TestHTTP2ConnectionDelegate()
        var maybeHTTP2Connection: HTTP2Connection?
        XCTAssertNoThrow(maybeHTTP2Connection = try connectionCreator.createHTTP2Connection(
            to: httpBin.port,
            delegate: delegate,
            on: eventLoop
        )
        )
        guard let http2Connection = maybeHTTP2Connection else {
            return XCTFail("Expected to have an HTTP2 connection here.")
        }

        var futures = [EventLoopFuture<HTTPClient.Response>]()

        for _ in 0..<100 {
            var maybeRequest: HTTPClient.Request?
            var maybeRequestBag: RequestBag<ResponseAccumulator>?
            XCTAssertNoThrow(maybeRequest = try HTTPClient.Request(url: "https://localhost:\(httpBin.port)"))
            XCTAssertNoThrow(maybeRequestBag = try RequestBag(
                request: XCTUnwrap(maybeRequest),
                eventLoopPreference: .indifferent,
                task: .init(eventLoop: eventLoop, logger: .init(label: "test")),
                redirectHandler: nil,
                connectionDeadline: .distantFuture,
                requestOptions: .forTests(),
                delegate: ResponseAccumulator(request: XCTUnwrap(maybeRequest))
            ))
            guard let requestBag = maybeRequestBag else {
                return XCTFail("Expected to have a request bag at this point")
            }

            http2Connection.executeRequest(requestBag)

            XCTAssertEqual(delegate.hitStreamClosed, 0)

            futures.append(requestBag.task.futureResult)
        }

        http2Connection.shutdown()

        for future in futures {
            XCTAssertThrowsError(try future.wait()) {
                XCTAssertEqual($0 as? HTTPClientError, .cancelled)
            }
        }

        XCTAssertNoThrow(try http2Connection.closeFuture.wait())
    }

    func testChildStreamsAreRemovedFromTheOpenChannelListOnceTheRequestIsDone() {
        class SucceedPromiseOnRequestHandler: ChannelInboundHandler {
            typealias InboundIn = HTTPServerRequestPart
            typealias OutboundOut = HTTPServerResponsePart

            let dataArrivedPromise: EventLoopPromise<Void>
            let triggerResponseFuture: EventLoopFuture<Void>

            init(dataArrivedPromise: EventLoopPromise<Void>, triggerResponseFuture: EventLoopFuture<Void>) {
                self.dataArrivedPromise = dataArrivedPromise
                self.triggerResponseFuture = triggerResponseFuture
            }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                self.dataArrivedPromise.succeed(())

                self.triggerResponseFuture.hop(to: context.eventLoop).whenSuccess {
                    switch self.unwrapInboundIn(data) {
                    case .head:
                        context.write(self.wrapOutboundOut(.head(.init(version: .http2, status: .ok))), promise: nil)
                        context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
                    case .body, .end:
                        break
                    }
                }
            }
        }

        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = eventLoopGroup.next()
        defer { XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully()) }

        let serverReceivedRequestPromise = eventLoop.makePromise(of: Void.self)
        let triggerResponsePromise = eventLoop.makePromise(of: Void.self)
        let httpBin = HTTPBin(.http2(compress: false)) { _ in
            SucceedPromiseOnRequestHandler(
                dataArrivedPromise: serverReceivedRequestPromise,
                triggerResponseFuture: triggerResponsePromise.futureResult
            )
        }
        defer { XCTAssertNoThrow(try httpBin.shutdown()) }

        let connectionCreator = TestConnectionCreator()
        let delegate = TestHTTP2ConnectionDelegate()
        var maybeHTTP2Connection: HTTP2Connection?
        XCTAssertNoThrow(maybeHTTP2Connection = try connectionCreator.createHTTP2Connection(
            to: httpBin.port,
            delegate: delegate,
            on: eventLoop
        ))
        guard let http2Connection = maybeHTTP2Connection else {
            return XCTFail("Expected to have an HTTP2 connection here.")
        }

        var maybeRequest: HTTPClient.Request?
        var maybeRequestBag: RequestBag<ResponseAccumulator>?
        XCTAssertNoThrow(maybeRequest = try HTTPClient.Request(url: "https://localhost:\(httpBin.port)"))
        XCTAssertNoThrow(maybeRequestBag = try RequestBag(
            request: XCTUnwrap(maybeRequest),
            eventLoopPreference: .indifferent,
            task: .init(eventLoop: eventLoop, logger: .init(label: "test")),
            redirectHandler: nil,
            connectionDeadline: .distantFuture,
            requestOptions: .forTests(),
            delegate: ResponseAccumulator(request: XCTUnwrap(maybeRequest))
        ))
        guard let requestBag = maybeRequestBag else {
            return XCTFail("Expected to have a request bag at this point")
        }

        http2Connection.executeRequest(requestBag)

        XCTAssertNoThrow(try serverReceivedRequestPromise.futureResult.wait())
        var channelCount: Int?
        XCTAssertNoThrow(channelCount = try eventLoop.submit { http2Connection.__forTesting_getStreamChannels().count }.wait())
        XCTAssertEqual(channelCount, 1)
        triggerResponsePromise.succeed(())

        XCTAssertNoThrow(try requestBag.task.futureResult.wait())

        // this is racy. for this reason we allow a couple of tries
        var retryCount = 0
        let maxRetries = 1000
        while retryCount < maxRetries {
            XCTAssertNoThrow(channelCount = try eventLoop.submit { http2Connection.__forTesting_getStreamChannels().count }.wait())
            if channelCount == 0 {
                break
            }
            retryCount += 1
        }
        XCTAssertLessThan(retryCount, maxRetries)
    }
}

class TestConnectionCreator {
    enum Error: Swift.Error {
        case alreadyCreatingAnotherConnection
        case wantedHTTP2ConnectionButGotHTTP1
        case wantedHTTP1ConnectionButGotHTTP2
    }

    enum State {
        case idle
        case waitingForHTTP1Connection(EventLoopPromise<HTTP1Connection>)
        case waitingForHTTP2Connection(EventLoopPromise<HTTP2Connection>)
    }

    private var state: State = .idle
    private let lock = NIOLock()

    init() {}

    func createHTTP1Connection(
        to port: Int,
        delegate: HTTP1ConnectionDelegate,
        connectionID: HTTPConnectionPool.Connection.ID = 0,
        on eventLoop: EventLoop,
        logger: Logger = .init(label: "test")
    ) throws -> HTTP1Connection {
        let request = try! HTTPClient.Request(url: "https://localhost:\(port)")

        var tlsConfiguration = TLSConfiguration.makeClientConfiguration()
        tlsConfiguration.certificateVerification = .none
        var config = HTTPClient.Configuration()
        config.httpVersion = .automatic
        let factory = HTTPConnectionPool.ConnectionFactory(
            key: .init(request),
            tlsConfiguration: tlsConfiguration,
            clientConfiguration: config,
            sslContextCache: .init()
        )

        let promise = try self.lock.withLock { () -> EventLoopPromise<HTTP1Connection> in
            guard case .idle = self.state else {
                throw Error.alreadyCreatingAnotherConnection
            }

            let promise = eventLoop.makePromise(of: HTTP1Connection.self)
            self.state = .waitingForHTTP1Connection(promise)
            return promise
        }

        factory.makeConnection(
            for: self,
            connectionID: connectionID,
            http1ConnectionDelegate: delegate,
            http2ConnectionDelegate: EmptyHTTP2ConnectionDelegate(),
            deadline: .now() + .seconds(2),
            eventLoop: eventLoop,
            logger: logger
        )

        return try promise.futureResult.wait()
    }

    func createHTTP2Connection(
        to port: Int,
        delegate: HTTP2ConnectionDelegate,
        connectionID: HTTPConnectionPool.Connection.ID = 0,
        on eventLoop: EventLoop,
        logger: Logger = .init(label: "test")
    ) throws -> HTTP2Connection {
        let request = try! HTTPClient.Request(url: "https://localhost:\(port)")

        var tlsConfiguration = TLSConfiguration.makeClientConfiguration()
        tlsConfiguration.certificateVerification = .none
        var config = HTTPClient.Configuration()
        config.httpVersion = .automatic
        let factory = HTTPConnectionPool.ConnectionFactory(
            key: .init(request),
            tlsConfiguration: tlsConfiguration,
            clientConfiguration: config,
            sslContextCache: .init()
        )

        let promise = try self.lock.withLock { () -> EventLoopPromise<HTTP2Connection> in
            guard case .idle = self.state else {
                throw Error.alreadyCreatingAnotherConnection
            }

            let promise = eventLoop.makePromise(of: HTTP2Connection.self)
            self.state = .waitingForHTTP2Connection(promise)
            return promise
        }

        factory.makeConnection(
            for: self,
            connectionID: connectionID,
            http1ConnectionDelegate: EmptyHTTP1ConnectionDelegate(),
            http2ConnectionDelegate: delegate,
            deadline: .now() + .seconds(2),
            eventLoop: eventLoop,
            logger: logger
        )

        return try promise.futureResult.wait()
    }
}

extension TestConnectionCreator: HTTPConnectionRequester {
    enum EitherPromiseWrapper<SucceedType, FailType> {
        case succeed(EventLoopPromise<SucceedType>, SucceedType)
        case fail(EventLoopPromise<FailType>, Error)

        func complete() {
            switch self {
            case .succeed(let promise, let success):
                promise.succeed(success)
            case .fail(let promise, let error):
                promise.fail(error)
            }
        }
    }

    func http1ConnectionCreated(_ connection: HTTP1Connection) {
        let wrapper = self.lock.withLock { () -> (EitherPromiseWrapper<HTTP1Connection, HTTP2Connection>) in

            switch self.state {
            case .waitingForHTTP1Connection(let promise):
                return .succeed(promise, connection)

            case .waitingForHTTP2Connection(let promise):
                return .fail(promise, Error.wantedHTTP2ConnectionButGotHTTP1)

            case .idle:
                preconditionFailure("Invalid state: \(self.state)")
            }
        }
        wrapper.complete()
    }

    func http2ConnectionCreated(_ connection: HTTP2Connection, maximumStreams: Int) {
        let wrapper = self.lock.withLock { () -> (EitherPromiseWrapper<HTTP2Connection, HTTP1Connection>) in

            switch self.state {
            case .waitingForHTTP1Connection(let promise):
                return .fail(promise, Error.wantedHTTP1ConnectionButGotHTTP2)

            case .waitingForHTTP2Connection(let promise):
                return .succeed(promise, connection)

            case .idle:
                preconditionFailure("Invalid state: \(self.state)")
            }
        }
        wrapper.complete()
    }

    enum FailPromiseWrapper<Type1, Type2> {
        case type1(EventLoopPromise<Type1>)
        case type2(EventLoopPromise<Type2>)

        func fail(_ error: Swift.Error) {
            switch self {
            case .type1(let eventLoopPromise):
                eventLoopPromise.fail(error)
            case .type2(let eventLoopPromise):
                eventLoopPromise.fail(error)
            }
        }
    }

    func failedToCreateHTTPConnection(_: HTTPConnectionPool.Connection.ID, error: Swift.Error) {
        let wrapper = self.lock.withLock { () -> (FailPromiseWrapper<HTTP1Connection, HTTP2Connection>) in

            switch self.state {
            case .waitingForHTTP1Connection(let promise):
                return .type1(promise)

            case .waitingForHTTP2Connection(let promise):
                return .type2(promise)

            case .idle:
                preconditionFailure("Invalid state: \(self.state)")
            }
        }
        wrapper.fail(error)
    }

    func waitingForConnectivity(_: HTTPConnectionPool.Connection.ID, error: Swift.Error) {
        preconditionFailure("TODO")
    }
}

class TestHTTP2ConnectionDelegate: HTTP2ConnectionDelegate {
    var hitStreamClosed: Int {
        self.lock.withLock { self._hitStreamClosed }
    }

    var hitGoAwayReceived: Int {
        self.lock.withLock { self._hitGoAwayReceived }
    }

    var hitConnectionClosed: Int {
        self.lock.withLock { self._hitConnectionClosed }
    }

    var maxStreamSetting: Int {
        self.lock.withLock { self._maxStreamSetting }
    }

    private let lock = NIOLock()
    private var _hitStreamClosed: Int = 0
    private var _hitGoAwayReceived: Int = 0
    private var _hitConnectionClosed: Int = 0
    private var _maxStreamSetting: Int = 100

    init() {}

    func http2Connection(_: HTTP2Connection, newMaxStreamSetting: Int) {}

    func http2ConnectionStreamClosed(_: HTTP2Connection, availableStreams: Int) {
        self.lock.withLock {
            self._hitStreamClosed += 1
        }
    }

    func http2ConnectionGoAwayReceived(_: HTTP2Connection) {
        self.lock.withLock {
            self._hitGoAwayReceived += 1
        }
    }

    func http2ConnectionClosed(_: HTTP2Connection) {
        self.lock.withLock {
            self._hitConnectionClosed += 1
        }
    }
}

final class EmptyHTTP2ConnectionDelegate: HTTP2ConnectionDelegate {
    func http2Connection(_: HTTP2Connection, newMaxStreamSetting: Int) {
        preconditionFailure("Unimplemented")
    }

    func http2ConnectionStreamClosed(_: HTTP2Connection, availableStreams: Int) {
        preconditionFailure("Unimplemented")
    }

    func http2ConnectionGoAwayReceived(_: HTTP2Connection) {
        preconditionFailure("Unimplemented")
    }

    func http2ConnectionClosed(_: HTTP2Connection) {
        preconditionFailure("Unimplemented")
    }
}

final class EmptyHTTP1ConnectionDelegate: HTTP1ConnectionDelegate {
    func http1ConnectionReleased(_: HTTP1Connection) {
        preconditionFailure("Unimplemented")
    }

    func http1ConnectionClosed(_: HTTP1Connection) {
        preconditionFailure("Unimplemented")
    }
}
