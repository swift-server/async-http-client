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
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOPosix
import XCTest

#if compiler(>=5.5) && canImport(_Concurrency)
@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
typealias PreparedRequest = HTTPClientRequest.Prepared
#endif

final class AsyncRequestTests: XCTestCase {
    func testCancelAsyncRequest() {
        #if compiler(>=5.5) && canImport(_Concurrency)
        guard #available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *) else { return }
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
            let (requestBag, responseTask) = AsyncRequestBag.makeWithResultTask(
                request: preparedRequest,
                preferredEventLoop: embeddedEventLoop
            )

            Task.detached {
                try await Task.sleep(nanoseconds: 5 * 1000 * 1000)
                requestBag.cancel()
            }

            do {
                _ = try await responseTask.result.get()
                XCTFail("Expected to throw error")
            } catch {
                XCTAssertEqual(error as? HTTPClientError, .cancelled)
            }
        }
        #endif
    }

    func testResponseStreamingWorks() {
        #if compiler(>=5.5) && canImport(_Concurrency)
        guard #available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *) else { return }
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
            let (requestBag, responseTask) = AsyncRequestBag.makeWithResultTask(
                request: preparedRequest,
                preferredEventLoop: embeddedEventLoop
            )

            let executor = MockRequestExecutor(
                pauseRequestBodyPartStreamAfterASingleWrite: true,
                eventLoop: embeddedEventLoop
            )

            requestBag.willExecuteRequest(executor)
            requestBag.requestHeadSent()

            let responseHead = HTTPResponseHead(version: .http1_1, status: .ok, headers: ["foo": "bar"])
            XCTAssertFalse(executor.signalledDemandForResponseBody)
            requestBag.receiveResponseHead(responseHead)

            do {
                let response = try await responseTask.result.get()
                XCTAssertEqual(response.status, responseHead.status)
                XCTAssertEqual(response.headers, responseHead.headers)
                XCTAssertEqual(response.version, responseHead.version)

                let iterator = SharedIterator(response.body.filter { $0.readableBytes > 0 }.makeAsyncIterator())

                for i in 0..<100 {
                    XCTAssertFalse(executor.signalledDemandForResponseBody, "Demand was not signalled yet.")

                    async let part = iterator.next()

                    try await Task.sleep(nanoseconds: 1000 * 1000)

                    XCTAssertTrue(executor.signalledDemandForResponseBody, "Iterator caused new demand")
                    executor.resetDemandSignal()
                    requestBag.receiveResponseBodyParts([ByteBuffer(integer: i)])

                    let result = try await part
                    XCTAssertEqual(result, ByteBuffer(integer: i))
                }

                XCTAssertFalse(executor.signalledDemandForResponseBody, "Demand was not signalled yet.")
                async let part = iterator.next()
                try await Task.sleep(nanoseconds: 1000 * 1000)
                XCTAssertTrue(executor.signalledDemandForResponseBody, "Iterator caused new demand")
                executor.resetDemandSignal()
                requestBag.succeedRequest([])
                let result = try await part
                XCTAssertNil(result)

            } catch {
                XCTFail("Failing tests are bad: \(error)")
            }
        }
        #endif
    }

    func testWriteBackpressureWorks() {
        #if compiler(>=5.5) && canImport(_Concurrency)
        guard #available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *) else { return }
        XCTAsyncTest {
            let embeddedEventLoop = EmbeddedEventLoop()
            defer { XCTAssertNoThrow(try embeddedEventLoop.syncShutdownGracefully()) }

            let streamWriter = AsyncSequenceWriter()
            if await streamWriter.hasDemand { XCTFail("Did not expect to have a demand at this point") }

            var request = HTTPClientRequest(url: "https://localhost/")
            request.method = .POST
            request.body = .stream(streamWriter)

            var maybePreparedRequest: PreparedRequest?
            XCTAssertNoThrow(maybePreparedRequest = try PreparedRequest(request))
            guard let preparedRequest = maybePreparedRequest else {
                return
            }
            let (requestBag, responseTask) = AsyncRequestBag.makeWithResultTask(
                request: preparedRequest,
                preferredEventLoop: embeddedEventLoop
            )

            let executor = MockRequestExecutor(eventLoop: embeddedEventLoop)

            requestBag.willExecuteRequest(executor)
            requestBag.requestHeadSent()

            do {
                // we need to yield here to ensure, will execute and request head can trigger
                await Task.yield()

                for i in 0..<100 {
                    if await streamWriter.hasDemand {
                        XCTFail("Did not expect to have demand yet")
                    }

                    requestBag.resumeRequestBodyStream()
                    try await streamWriter.demand() // wait's for the stream writer to signal demand
                    requestBag.pauseRequestBodyStream()

                    await Task.yield()

                    let part = ByteBuffer(integer: i)
                    await streamWriter.write(part)

                    // wait for the executor to be readable again
                    try await executor.readable().get()
                    let next = executor.nextBodyPart()
                    XCTAssertEqual(next, .body(.byteBuffer(part)))
                }

                requestBag.resumeRequestBodyStream()
                try await streamWriter.demand()

                await streamWriter.end()
                try await executor.readable().get()

                let next = executor.nextBodyPart()
                XCTAssertEqual(next, .endOfStream)

                // write response!

                let responseHead = HTTPResponseHead(version: .http1_1, status: .ok, headers: ["foo": "bar"])
                XCTAssertFalse(executor.signalledDemandForResponseBody)
                requestBag.receiveResponseHead(responseHead)

                let response = try await responseTask.result.get()
                XCTAssertEqual(response.status, responseHead.status)
                XCTAssertEqual(response.headers, responseHead.headers)
                XCTAssertEqual(response.version, responseHead.version)

                let iterator = SharedIterator(response.body.makeAsyncIterator())

                XCTAssertFalse(executor.signalledDemandForResponseBody, "Demand was not signalled yet.")
                async let part = iterator.next()
                try await Task.sleep(nanoseconds: 1000 * 1000)
                XCTAssertTrue(executor.signalledDemandForResponseBody, "Iterator caused new demand")
                executor.resetDemandSignal()
                requestBag.succeedRequest([])
                let result = try await part
                XCTAssertNil(result)
            } catch {
                XCTFail("Failing tests are bad: \(error)")
            }
        }
        #endif
    }

    func testSimpleGetRequest() {
        #if compiler(>=5.5) && canImport(_Concurrency)
        guard #available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *) else { return }
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

            do {
                var request = HTTPClientRequest(url: "https://localhost:\(httpBin.port)/")
                request.headers = ["host": "localhost:\(httpBin.port)"]

                var maybePreparedRequest: PreparedRequest?
                XCTAssertNoThrow(maybePreparedRequest = try PreparedRequest(request))
                guard let preparedRequest = maybePreparedRequest else {
                    return
                }
                let (requestBag, responseTask) = AsyncRequestBag.makeWithResultTask(
                    request: preparedRequest,
                    preferredEventLoop: eventLoopGroup.next()
                )

                http2Connection.executeRequest(requestBag)

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
            } catch {
                XCTFail("We don't like errors in tests: \(error)")
            }
        }
        #endif
    }

    func testBiDirectionalStreamingHTTP2() {
        #if compiler(>=5.5) && canImport(_Concurrency)
        guard #available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *) else { return }
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

            do {
                let streamWriter = AsyncSequenceWriter()
                if await streamWriter.hasDemand { XCTFail("Did not expect to have a demand at this point") }

                var request = HTTPClientRequest(url: "https://localhost:\(httpBin.port)/")
                request.method = .POST
                request.headers = ["host": "localhost:\(httpBin.port)"]
                request.body = .stream(length: 800, streamWriter)

                var maybePreparedRequest: PreparedRequest?
                XCTAssertNoThrow(maybePreparedRequest = try PreparedRequest(request))
                guard let preparedRequest = maybePreparedRequest else {
                    return
                }
                let (requestBag, responseTask) = AsyncRequestBag.makeWithResultTask(
                    request: preparedRequest,
                    preferredEventLoop: eventLoopGroup.next()
                )

                http2Connection.executeRequest(requestBag)

                XCTAssertEqual(delegate.hitStreamClosed, 0)

                let response = try await responseTask.result.get()

                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(response.version, .http2)
                XCTAssertEqual(delegate.hitStreamClosed, 0)

                let iterator = SharedIterator(response.body.filter { $0.readableBytes > 0 }.makeAsyncIterator())

                // at this point we can start to write to the stream and wait for the results

                for i in 0..<100 {
                    let buffer = ByteBuffer(integer: i)
                    await streamWriter.write(buffer)
                    var echoedBuffer = try await iterator.next()
                    guard let echoedInt = echoedBuffer?.readInteger(as: Int.self) else {
                        XCTFail("Expected to not be finished at this point")
                        break
                    }
                    XCTAssertEqual(i, echoedInt)
                }

                XCTAssertEqual(delegate.hitStreamClosed, 0)
                await streamWriter.end()
                let final = try await iterator.next()
                XCTAssertNil(final)
                XCTAssertEqual(delegate.hitStreamClosed, 1)

            } catch {
                print(error)
                XCTFail("We don't like errors in tests: \(error)")
            }
        }
        #endif
    }
}

#if compiler(>=5.5) && canImport(_Concurrency)

// This needs a small explanation. If an iterator is a struct, it can't be used across multiple
// tasks. Since we want to wait for things to happen in tests, we need to `async let`, which creates
// implicit tasks. Therefore we need to wrap our iterator struct.
@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
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

@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
actor AsyncSequenceWriter: AsyncSequence {
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

    nonisolated func makeAsyncIterator() -> Iterator {
        return Iterator(self)
    }

    enum State {
        case buffering(CircularBuffer<ByteBuffer?>, CheckedContinuation<Void, Error>?)
        case finished
        case waiting(UnsafeContinuation<ByteBuffer?, Error>)
        case failed(Error)
    }

    private var state: State = .buffering(.init(), nil)

    public var hasDemand: Bool {
        switch self.state {
        case .failed, .finished, .buffering:
            return false
        case .waiting:
            return true
        }
    }

    public func demand() async throws {
        switch self.state {
        case .buffering(let buffer, .none):
            try await withCheckedThrowingContinuation { continuation in
                self.state = .buffering(buffer, continuation)
            }

        case .waiting:
            return

        case .buffering(_, .some):
            preconditionFailure("Already waiting for demand")

        case .finished, .failed:
            preconditionFailure("Invalid state: \(self.state)")
        }
    }

    private func next() async throws -> ByteBuffer? {
        switch self.state {
        case .buffering(let buffer, let demandContinuation) where buffer.isEmpty:
            return try await withUnsafeThrowingContinuation { continuation in
                self.state = .waiting(continuation)

                demandContinuation?.resume(returning: ())
            }

        case .buffering(var buffer, let demandContinuation):
            let first = buffer.popFirst()!
            if first != nil {
                self.state = .buffering(buffer, demandContinuation)
            } else {
                self.state = .finished
            }
            return first

        case .failed(let error):
            self.state = .finished
            throw error

        case .finished:
            return nil

        case .waiting:
            preconditionFailure("How can this be called twice?!")
        }
    }

    public func write(_ byteBuffer: ByteBuffer) {
        switch self.state {
        case .buffering(var buffer, let continuation):
            buffer.append(byteBuffer)
            self.state = .buffering(buffer, continuation)

        case .waiting(let continuation):
            self.state = .buffering(.init(), nil)
            continuation.resume(returning: byteBuffer)

        case .finished, .failed:
            preconditionFailure("Invalid state: \(self.state)")
        }
    }

    public func end() {
        switch self.state {
        case .buffering(var buffer, let continuation):
            buffer.append(nil)
            self.state = .buffering(buffer, continuation)

        case .waiting(let continuation):
            self.state = .finished
            continuation.resume(returning: nil)

        case .finished, .failed:
            preconditionFailure("Invalid state: \(self.state)")
        }
    }

    public func fail(_ error: Error) {
        switch self.state {
        case .buffering:
            self.state = .failed(error)

        case .failed, .finished:
            return

        case .waiting(let continuation):
            self.state = .finished
            continuation.resume(throwing: error)
        }
    }
}

@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
extension AsyncRequestBag {
    fileprivate static func makeWithResultTask(
        request: PreparedRequest,
        requestOptions: RequestOptions = .forTests(),
        logger: Logger = Logger(label: "test"),
        connectionDeadline: NIODeadline = .distantFuture,
        preferredEventLoop: EventLoop
    ) -> (AsyncRequestBag, _Concurrency.Task<HTTPClientResponse, Error>) {
        let requestBagPromise = preferredEventLoop.makePromise(of: AsyncRequestBag.self)
        let result = Task {
            try await withUnsafeThrowingContinuation { (continuation: UnsafeContinuation<HTTPClientResponse, Error>) in
                let requestBag = AsyncRequestBag(
                    request: request,
                    requestOptions: requestOptions,
                    logger: logger,
                    connectionDeadline: connectionDeadline,
                    preferredEventLoop: preferredEventLoop,
                    responseContinuation: continuation
                )
                requestBagPromise.succeed(requestBag)
            }
        }
        // the promise can never fail and it is therefore safe to force unwrap
        let requestBag = try! requestBagPromise.futureResult.wait()

        return (requestBag, result)
    }
}
#endif
