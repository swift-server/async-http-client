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
import XCTest

#if compiler(>=5.5.2) && canImport(_Concurrency)
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
typealias PreparedRequest = HTTPClientRequest.Prepared
#endif

final class TransactionTests: XCTestCase {
    func testCancelAsyncRequest() {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest {
            let embeddedEventLoop = EmbeddedEventLoop()
            defer { XCTAssertNoThrow(try embeddedEventLoop.syncShutdownGracefully()) }

            var request = HTTPClientRequest(url: "https://localhost/")
            request.method = .GET
            var maybePreparedRequest: PreparedRequest?
            XCTAssertNoThrow(maybePreparedRequest = try PreparedRequest(request))
            guard let preparedRequest = maybePreparedRequest else {
                return XCTFail("Expected to have a request here.")
            }
            let (transaction, responseTask) = await Transaction.makeWithResultTask(
                request: preparedRequest,
                preferredEventLoop: embeddedEventLoop
            )

            let queuer = MockTaskQueuer()
            transaction.requestWasQueued(queuer)

            Task.detached {
                try await Task.sleep(nanoseconds: 5 * 1000 * 1000)
                transaction.cancel()
            }

            XCTAssertEqual(queuer.hitCancelCount, 0)
            await XCTAssertThrowsError(try await responseTask.value) {
                XCTAssertEqual($0 as? HTTPClientError, .cancelled)
            }
            XCTAssertEqual(queuer.hitCancelCount, 1)
        }
        #endif
    }

    func testResponseStreamingWorks() {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest {
            let embeddedEventLoop = EmbeddedEventLoop()
            defer { XCTAssertNoThrow(try embeddedEventLoop.syncShutdownGracefully()) }

            var request = HTTPClientRequest(url: "https://localhost/")
            request.method = .GET

            var maybePreparedRequest: PreparedRequest?
            XCTAssertNoThrow(maybePreparedRequest = try PreparedRequest(request))
            guard let preparedRequest = maybePreparedRequest else {
                return
            }
            let (transaction, responseTask) = await Transaction.makeWithResultTask(
                request: preparedRequest,
                preferredEventLoop: embeddedEventLoop
            )

            let executor = MockRequestExecutor(
                pauseRequestBodyPartStreamAfterASingleWrite: true,
                eventLoop: embeddedEventLoop
            )

            transaction.willExecuteRequest(executor)
            transaction.requestHeadSent()

            let responseHead = HTTPResponseHead(version: .http1_1, status: .ok, headers: ["foo": "bar"])
            XCTAssertFalse(executor.signalledDemandForResponseBody)
            transaction.receiveResponseHead(responseHead)

            let response = try await responseTask.value
            XCTAssertEqual(response.status, responseHead.status)
            XCTAssertEqual(response.headers, responseHead.headers)
            XCTAssertEqual(response.version, responseHead.version)

            let iterator = SharedIterator(response.body.filter { $0.readableBytes > 0 }.makeAsyncIterator())

            for i in 0..<100 {
                XCTAssertFalse(executor.signalledDemandForResponseBody, "Demand was not signalled yet.")

                async let part = iterator.next()

                XCTAssertNoThrow(try executor.receiveResponseDemand())
                executor.resetResponseStreamDemandSignal()
                transaction.receiveResponseBodyParts([ByteBuffer(integer: i)])

                let result = try await part
                XCTAssertEqual(result, ByteBuffer(integer: i))
            }

            XCTAssertFalse(executor.signalledDemandForResponseBody, "Demand was not signalled yet.")
            async let part = iterator.next()
            XCTAssertNoThrow(try executor.receiveResponseDemand())
            executor.resetResponseStreamDemandSignal()
            transaction.succeedRequest([])
            let result = try await part
            XCTAssertNil(result)
        }
        #endif
    }

    func testIgnoringResponseBodyWorks() {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest {
            let embeddedEventLoop = EmbeddedEventLoop()
            defer { XCTAssertNoThrow(try embeddedEventLoop.syncShutdownGracefully()) }

            var request = HTTPClientRequest(url: "https://localhost/")
            request.method = .GET

            var maybePreparedRequest: PreparedRequest?
            XCTAssertNoThrow(maybePreparedRequest = try PreparedRequest(request))
            guard let preparedRequest = maybePreparedRequest else {
                return
            }
            var tuple: (Transaction, Task<HTTPClientResponse, Error>)! = await Transaction.makeWithResultTask(
                request: preparedRequest,
                preferredEventLoop: embeddedEventLoop
            )

            let transaction = tuple.0
            var responseTask: Task<HTTPClientResponse, Error>! = tuple.1
            tuple = nil

            let executor = MockRequestExecutor(
                pauseRequestBodyPartStreamAfterASingleWrite: true,
                eventLoop: embeddedEventLoop
            )
            executor.runRequest(transaction)

            let responseHead = HTTPResponseHead(version: .http1_1, status: .ok, headers: ["foo": "bar"])
            XCTAssertFalse(executor.signalledDemandForResponseBody)
            transaction.receiveResponseHead(responseHead)

            var response: HTTPClientResponse? = try await responseTask.value
            responseTask = nil
            XCTAssertEqual(response?.status, responseHead.status)
            XCTAssertEqual(response?.headers, responseHead.headers)
            XCTAssertEqual(response?.version, responseHead.version)
            response = nil

            XCTAssertFalse(executor.signalledDemandForResponseBody)
            XCTAssertNoThrow(try executor.receiveCancellation())

            // doesn't crash if receives more data because of race
            transaction.receiveResponseBodyParts([ByteBuffer(string: "foo bar")])
            transaction.succeedRequest(nil)
        }
        #endif
    }

    func testWriteBackpressureWorks() {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest {
            let embeddedEventLoop = EmbeddedEventLoop()
            defer { XCTAssertNoThrow(try embeddedEventLoop.syncShutdownGracefully()) }

            let streamWriter = AsyncSequenceWriter<ByteBuffer>()
            XCTAssertFalse(streamWriter.hasDemand, "Did not expect to have a demand at this point")

            var request = HTTPClientRequest(url: "https://localhost/")
            request.method = .POST
            request.body = .stream(streamWriter, length: .unknown)

            var maybePreparedRequest: PreparedRequest?
            XCTAssertNoThrow(maybePreparedRequest = try PreparedRequest(request))
            guard let preparedRequest = maybePreparedRequest else {
                return XCTFail("Expected to have a request here.")
            }
            let (transaction, responseTask) = await Transaction.makeWithResultTask(
                request: preparedRequest,
                preferredEventLoop: embeddedEventLoop
            )

            let executor = MockRequestExecutor(eventLoop: embeddedEventLoop)

            executor.runRequest(transaction)

            for i in 0..<100 {
                XCTAssertFalse(streamWriter.hasDemand, "Did not expect to have demand yet")

                transaction.resumeRequestBodyStream()
                await streamWriter.demand() // wait's for the stream writer to signal demand
                transaction.pauseRequestBodyStream()

                let part = ByteBuffer(integer: i)
                streamWriter.write(part)

                XCTAssertNoThrow(try executor.receiveRequestBody {
                    XCTAssertEqual($0, part)
                })
            }

            transaction.resumeRequestBodyStream()
            await streamWriter.demand()

            streamWriter.end()
            XCTAssertNoThrow(try executor.receiveEndOfStream())

            // write response!

            let responseHead = HTTPResponseHead(version: .http1_1, status: .ok, headers: ["foo": "bar"])
            XCTAssertFalse(executor.signalledDemandForResponseBody)
            transaction.receiveResponseHead(responseHead)

            let response = try await responseTask.result.get()
            XCTAssertEqual(response.status, responseHead.status)
            XCTAssertEqual(response.headers, responseHead.headers)
            XCTAssertEqual(response.version, responseHead.version)

            let iterator = SharedIterator(response.body.makeAsyncIterator())

            XCTAssertFalse(executor.signalledDemandForResponseBody, "Demand was not signalled yet.")
            async let part = iterator.next()

            XCTAssertNoThrow(try executor.receiveResponseDemand())
            executor.resetResponseStreamDemandSignal()
            transaction.succeedRequest([])
            let result = try await part
            XCTAssertNil(result)
        }
        #endif
    }

    func testSimpleGetRequest() {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest {
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

            var request = HTTPClientRequest(url: "https://localhost:\(httpBin.port)/")
            request.headers = ["host": "localhost:\(httpBin.port)"]

            var maybePreparedRequest: PreparedRequest?
            XCTAssertNoThrow(maybePreparedRequest = try PreparedRequest(request))
            guard let preparedRequest = maybePreparedRequest else {
                return XCTFail("Expected to have a request here.")
            }
            let (transaction, responseTask) = await Transaction.makeWithResultTask(
                request: preparedRequest,
                preferredEventLoop: eventLoopGroup.next()
            )

            http2Connection.executeRequest(transaction)

            XCTAssertEqual(delegate.hitStreamClosed, 0)

            let response = try await responseTask.result.get()

            XCTAssertEqual(response.status, .ok)
            XCTAssertEqual(response.version, .http2)
            XCTAssertEqual(delegate.hitStreamClosed, 1)

            var body = try await response.body.reduce(into: ByteBuffer()) { partialResult, next in
                var next = next
                partialResult.writeBuffer(&next)
            }
            XCTAssertEqual(
                try body.readJSONDecodable(RequestInfo.self, length: body.readableBytes),
                RequestInfo(data: "", requestNumber: 1, connectionNumber: 0)
            )
        }
        #endif
    }

    func testSimplePostRequest() {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest {
            let embeddedEventLoop = EmbeddedEventLoop()
            defer { XCTAssertNoThrow(try embeddedEventLoop.syncShutdownGracefully()) }

            var request = HTTPClientRequest(url: "https://localhost/")
            request.method = .POST
            request.body = .bytes("Hello world!".utf8, length: .unknown)
            var maybePreparedRequest: PreparedRequest?
            XCTAssertNoThrow(maybePreparedRequest = try PreparedRequest(request))
            guard let preparedRequest = maybePreparedRequest else {
                return XCTFail("Expected to have a request here.")
            }
            let (transaction, responseTask) = await Transaction.makeWithResultTask(
                request: preparedRequest,
                preferredEventLoop: embeddedEventLoop
            )

            let executor = MockRequestExecutor(eventLoop: embeddedEventLoop)
            executor.runRequest(transaction)
            executor.resumeRequestBodyStream()
            XCTAssertNoThrow(try executor.receiveRequestBody {
                XCTAssertEqual($0.getString(at: 0, length: $0.readableBytes), "Hello world!")
            })
            XCTAssertNoThrow(try executor.receiveEndOfStream())

            let responseHead = HTTPResponseHead(version: .http1_1, status: .ok, headers: ["foo": "bar"])
            transaction.receiveResponseHead(responseHead)
            transaction.succeedRequest(nil)

            let response = try await responseTask.value
            XCTAssertEqual(response.status, .ok)
            XCTAssertEqual(response.version, .http1_1)
            XCTAssertEqual(response.headers, ["foo": "bar"])
        }
        #endif
    }

    func testPostStreamFails() {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest {
            let embeddedEventLoop = EmbeddedEventLoop()
            defer { XCTAssertNoThrow(try embeddedEventLoop.syncShutdownGracefully()) }

            let writer = AsyncSequenceWriter<ByteBuffer>()

            var request = HTTPClientRequest(url: "https://localhost/")
            request.method = .POST
            request.body = .stream(writer, length: .unknown)
            var maybePreparedRequest: PreparedRequest?
            XCTAssertNoThrow(maybePreparedRequest = try PreparedRequest(request))
            guard let preparedRequest = maybePreparedRequest else {
                return XCTFail("Expected to have a request here.")
            }
            let (transaction, responseTask) = await Transaction.makeWithResultTask(
                request: preparedRequest,
                preferredEventLoop: embeddedEventLoop
            )

            let executor = MockRequestExecutor(eventLoop: embeddedEventLoop)
            executor.runRequest(transaction)
            executor.resumeRequestBodyStream()

            await writer.demand()
            writer.write(.init(string: "Hello world!"))

            XCTAssertNoThrow(try executor.receiveRequestBody {
                XCTAssertEqual($0.getString(at: 0, length: $0.readableBytes), "Hello world!")
            })

            XCTAssertFalse(executor.isCancelled)
            struct WriteError: Error, Equatable {}
            writer.fail(WriteError())

            await XCTAssertThrowsError(try await responseTask.value) {
                XCTAssertEqual($0 as? WriteError, .init())
            }
            XCTAssertNoThrow(try executor.receiveCancellation())
        }
        #endif
    }

    func testResponseStreamFails() {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest(timeout: 30) {
            let embeddedEventLoop = EmbeddedEventLoop()
            defer { XCTAssertNoThrow(try embeddedEventLoop.syncShutdownGracefully()) }

            var request = HTTPClientRequest(url: "https://localhost/")
            request.method = .GET

            var maybePreparedRequest: PreparedRequest?
            XCTAssertNoThrow(maybePreparedRequest = try PreparedRequest(request))
            guard let preparedRequest = maybePreparedRequest else {
                return
            }
            let (transaction, responseTask) = await Transaction.makeWithResultTask(
                request: preparedRequest,
                preferredEventLoop: embeddedEventLoop
            )

            let executor = MockRequestExecutor(
                pauseRequestBodyPartStreamAfterASingleWrite: true,
                eventLoop: embeddedEventLoop
            )

            transaction.willExecuteRequest(executor)
            transaction.requestHeadSent()

            let responseHead = HTTPResponseHead(version: .http1_1, status: .ok, headers: ["foo": "bar"])
            XCTAssertFalse(executor.signalledDemandForResponseBody)
            transaction.receiveResponseHead(responseHead)

            let response = try await responseTask.value

            XCTAssertEqual(response.status, responseHead.status)
            XCTAssertEqual(response.headers, responseHead.headers)
            XCTAssertEqual(response.version, responseHead.version)

            XCTAssertFalse(executor.signalledDemandForResponseBody, "Demand was not signalled yet.")
            let iterator = SharedIterator(response.body.filter { $0.readableBytes > 0 }.makeAsyncIterator())

            async let part1 = iterator.next()
            XCTAssertNoThrow(try executor.receiveResponseDemand())
            executor.resetResponseStreamDemandSignal()
            transaction.receiveResponseBodyParts([ByteBuffer(integer: 123)])

            let result = try await part1
            XCTAssertEqual(result, ByteBuffer(integer: 123))

            let responsePartTask = Task {
                try await iterator.next()
            }
            XCTAssertNoThrow(try executor.receiveResponseDemand())
            executor.resetResponseStreamDemandSignal()
            transaction.fail(HTTPClientError.readTimeout)

            // can't use XCTAssertThrowsError() here, since capturing async let variables is
            // not allowed.
            await XCTAssertThrowsError(try await responsePartTask.value) {
                XCTAssertEqual($0 as? HTTPClientError, .readTimeout)
            }
        }
        #endif
    }

    func testBiDirectionalStreamingHTTP2() {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest {
            let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            let eventLoop = eventLoopGroup.next()
            defer { XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully()) }

            let httpBin = HTTPBin(.http2(compress: false)) { _ in HTTPEchoHandler() }
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

            let streamWriter = AsyncSequenceWriter<ByteBuffer>()
            XCTAssertFalse(streamWriter.hasDemand, "Did not expect to have a demand at this point")

            var request = HTTPClientRequest(url: "https://localhost:\(httpBin.port)/")
            request.method = .POST
            request.headers = ["host": "localhost:\(httpBin.port)"]
            request.body = .stream(streamWriter, length: .known(800))

            var maybePreparedRequest: PreparedRequest?
            XCTAssertNoThrow(maybePreparedRequest = try PreparedRequest(request))
            guard let preparedRequest = maybePreparedRequest else {
                return
            }
            let (transaction, responseTask) = await Transaction.makeWithResultTask(
                request: preparedRequest,
                preferredEventLoop: eventLoopGroup.next()
            )

            http2Connection.executeRequest(transaction)

            XCTAssertEqual(delegate.hitStreamClosed, 0)

            let response = try await responseTask.result.get()

            XCTAssertEqual(response.status, .ok)
            XCTAssertEqual(response.version, .http2)
            XCTAssertEqual(delegate.hitStreamClosed, 0)

            let iterator = SharedIterator(response.body.filter { $0.readableBytes > 0 }.makeAsyncIterator())

            // at this point we can start to write to the stream and wait for the results

            for i in 0..<100 {
                let buffer = ByteBuffer(integer: i)
                streamWriter.write(buffer)
                var echoedBuffer = try await iterator.next()
                guard let echoedInt = echoedBuffer?.readInteger(as: Int.self) else {
                    XCTFail("Expected to not be finished at this point")
                    break
                }
                XCTAssertEqual(i, echoedInt)
            }

            XCTAssertEqual(delegate.hitStreamClosed, 0)
            streamWriter.end()
            let final = try await iterator.next()
            XCTAssertNil(final)
            XCTAssertEqual(delegate.hitStreamClosed, 1)
        }
        #endif
    }
}

#if compiler(>=5.5.2) && canImport(_Concurrency)

// This needs a small explanation. If an iterator is a struct, it can't be used across multiple
// tasks. Since we want to wait for things to happen in tests, we need to `async let`, which creates
// implicit tasks. Therefore we need to wrap our iterator struct.
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
actor SharedIterator<Iterator: AsyncIteratorProtocol> {
    private var iterator: Iterator

    init(_ iterator: Iterator) {
        self.iterator = iterator
    }

    func next() async throws -> Iterator.Element? {
        var iter = self.iterator
        defer { self.iterator = iter }
        return try await iter.next()
    }
}

/// non fail-able promise that only supports one observer
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
fileprivate actor Promise<Value> {
    private enum State {
        case initialised
        case fulfilled(Value)
    }

    private var state: State = .initialised

    private var observer: CheckedContinuation<Value, Never>?

    init() {}

    func fulfil(_ value: Value) {
        switch self.state {
        case .initialised:
            self.state = .fulfilled(value)
            self.observer?.resume(returning: value)
        case .fulfilled:
            preconditionFailure("\(Self.self) over fulfilled")
        }
    }

    var value: Value {
        get async {
            switch self.state {
            case .initialised:
                return await withCheckedContinuation { (continuation: CheckedContinuation<Value, Never>) in
                    precondition(self.observer == nil, "\(Self.self) supports only one observer")
                    self.observer = continuation
                }
            case .fulfilled(let value):
                return value
            }
        }
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension Transaction {
    fileprivate static func makeWithResultTask(
        request: PreparedRequest,
        requestOptions: RequestOptions = .forTests(),
        logger: Logger = Logger(label: "test"),
        connectionDeadline: NIODeadline = .distantFuture,
        preferredEventLoop: EventLoop
    ) async -> (Transaction, _Concurrency.Task<HTTPClientResponse, Error>) {
        let transactionPromise = Promise<Transaction>()
        let task = Task {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPClientResponse, Error>) in
                let transaction = Transaction(
                    request: request,
                    requestOptions: requestOptions,
                    logger: logger,
                    connectionDeadline: connectionDeadline,
                    preferredEventLoop: preferredEventLoop,
                    responseContinuation: continuation
                )
                Task {
                    await transactionPromise.fulfil(transaction)
                }
            }
        }

        return (await transactionPromise.value, task)
    }
}
#endif
