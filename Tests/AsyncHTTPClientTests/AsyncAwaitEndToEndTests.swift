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
import NIOPosix
import XCTest

private func makeDefaultHTTPClient(
    eventLoopGroupProvider: HTTPClient.EventLoopGroupProvider = .createNew
) -> HTTPClient {
    var config = HTTPClient.Configuration()
    config.tlsConfiguration = .clientDefault
    config.tlsConfiguration?.certificateVerification = .none
    config.httpVersion = .automatic
    return HTTPClient(
        eventLoopGroupProvider: eventLoopGroupProvider,
        configuration: config,
        backgroundActivityLogger: Logger(label: "HTTPClient", factory: StreamLogHandler.standardOutput(label:))
    )
}

final class AsyncAwaitEndToEndTests: XCTestCase {
    func testSimpleGet() {
        #if compiler(>=5.5) && canImport(_Concurrency)
        guard #available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *) else { return }
        XCTAsyncTest {
            let bin = HTTPBin(.http2(compress: false))
            defer { XCTAssertNoThrow(try bin.shutdown()) }
            let client = makeDefaultHTTPClient()
            defer { XCTAssertNoThrow(try client.syncShutdown()) }
            let logger = Logger(label: "HTTPClient", factory: StreamLogHandler.standardOutput(label:))
            let request = HTTPClientRequest(url: "https://localhost:\(bin.port)/get")

            guard let response = await XCTAssertNoThrowWithResult(
                try await client.execute(request, deadline: .now() + .seconds(10), logger: logger)
            ) else {
                return
            }

            XCTAssertEqual(response.status, .ok)
            XCTAssertEqual(response.version, .http2)
        }
        #endif
    }

    func testSimplePost() {
        #if compiler(>=5.5) && canImport(_Concurrency)
        guard #available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *) else { return }
        XCTAsyncTest {
            let bin = HTTPBin(.http2(compress: false))
            defer { XCTAssertNoThrow(try bin.shutdown()) }
            let client = makeDefaultHTTPClient()
            defer { XCTAssertNoThrow(try client.syncShutdown()) }
            let logger = Logger(label: "HTTPClient", factory: StreamLogHandler.standardOutput(label:))
            let request = HTTPClientRequest(url: "https://localhost:\(bin.port)/get")

            guard let response = await XCTAssertNoThrowWithResult(
                try await client.execute(request, deadline: .now() + .seconds(10), logger: logger)
            ) else {
                return
            }

            XCTAssertEqual(response.status, .ok)
            XCTAssertEqual(response.version, .http2)
        }
        #endif
    }

    func testPostWithByteBuffer() {
        #if compiler(>=5.5) && canImport(_Concurrency)
        guard #available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *) else { return }
        XCTAsyncTest {
            let bin = HTTPBin(.http2(compress: false)) { _ in HTTPEchoHandler() }
            defer { XCTAssertNoThrow(try bin.shutdown()) }
            let client = makeDefaultHTTPClient()
            defer { XCTAssertNoThrow(try client.syncShutdown()) }
            let logger = Logger(label: "HTTPClient", factory: StreamLogHandler.standardOutput(label:))
            var request = HTTPClientRequest(url: "https://localhost:\(bin.port)/")
            request.method = .POST
            request.body = .byteBuffer(ByteBuffer(string: "1234"))

            guard let response = await XCTAssertNoThrowWithResult(
                try await client.execute(request, deadline: .now() + .seconds(10), logger: logger)
            ) else { return }
            XCTAssertEqual(response.headers["content-length"], ["4"])
            guard let body = await XCTAssertNoThrowWithResult(
                try await response.body.collect()
            ) else { return }
            XCTAssertEqual(body, ByteBuffer(string: "1234"))
        }
        #endif
    }

    func testPostWithSequenceOfUInt8() {
        #if compiler(>=5.5) && canImport(_Concurrency)
        guard #available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *) else { return }
        XCTAsyncTest {
            let bin = HTTPBin(.http2(compress: false)) { _ in HTTPEchoHandler() }
            defer { XCTAssertNoThrow(try bin.shutdown()) }
            let client = makeDefaultHTTPClient()
            defer { XCTAssertNoThrow(try client.syncShutdown()) }
            let logger = Logger(label: "HTTPClient", factory: StreamLogHandler.standardOutput(label:))
            var request = HTTPClientRequest(url: "https://localhost:\(bin.port)/")
            request.method = .POST
            request.body = .bytes(length: nil, AnySequence("1234".utf8))

            guard let response = await XCTAssertNoThrowWithResult(
                try await client.execute(request, deadline: .now() + .seconds(10), logger: logger)
            ) else { return }
            XCTAssertEqual(response.headers["content-length"], [])
            guard let body = await XCTAssertNoThrowWithResult(
                try await response.body.collect()
            ) else { return }
            XCTAssertEqual(body, ByteBuffer(string: "1234"))
        }
        #endif
    }

    func testPostWithCollectionOfUInt8() {
        #if compiler(>=5.5) && canImport(_Concurrency)
        guard #available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *) else { return }
        XCTAsyncTest {
            let bin = HTTPBin(.http2(compress: false)) { _ in HTTPEchoHandler() }
            defer { XCTAssertNoThrow(try bin.shutdown()) }
            let client = makeDefaultHTTPClient()
            defer { XCTAssertNoThrow(try client.syncShutdown()) }
            let logger = Logger(label: "HTTPClient", factory: StreamLogHandler.standardOutput(label:))
            var request = HTTPClientRequest(url: "https://localhost:\(bin.port)/")
            request.method = .POST
            request.body = .bytes(length: nil, AnyCollection("1234".utf8))

            guard let response = await XCTAssertNoThrowWithResult(
                try await client.execute(request, deadline: .now() + .seconds(10), logger: logger)
            ) else { return }
            XCTAssertEqual(response.headers["content-length"], [])
            guard let body = await XCTAssertNoThrowWithResult(
                try await response.body.collect()
            ) else { return }
            XCTAssertEqual(body, ByteBuffer(string: "1234"))
        }
        #endif
    }

    func testPostWithRandomAccessCollectionOfUInt8() {
        #if compiler(>=5.5) && canImport(_Concurrency)
        guard #available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *) else { return }
        XCTAsyncTest {
            let bin = HTTPBin(.http2(compress: false)) { _ in HTTPEchoHandler() }
            defer { XCTAssertNoThrow(try bin.shutdown()) }
            let client = makeDefaultHTTPClient()
            defer { XCTAssertNoThrow(try client.syncShutdown()) }
            let logger = Logger(label: "HTTPClient", factory: StreamLogHandler.standardOutput(label:))
            var request = HTTPClientRequest(url: "https://localhost:\(bin.port)/")
            request.method = .POST
            request.body = .bytes(ByteBuffer(string: "1234").readableBytesView)

            guard let response = await XCTAssertNoThrowWithResult(
                try await client.execute(request, deadline: .now() + .seconds(10), logger: logger)
            ) else { return }
            XCTAssertEqual(response.headers["content-length"], ["4"])
            guard let body = await XCTAssertNoThrowWithResult(
                try await response.body.collect()
            ) else { return }
            XCTAssertEqual(body, ByteBuffer(string: "1234"))
        }
        #endif
    }

    func testPostWithAsyncSequenceOfByteBuffers() {
        #if compiler(>=5.5) && canImport(_Concurrency)
        guard #available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *) else { return }
        XCTAsyncTest {
            let bin = HTTPBin(.http2(compress: false)) { _ in HTTPEchoHandler() }
            defer { XCTAssertNoThrow(try bin.shutdown()) }
            let client = makeDefaultHTTPClient()
            defer { XCTAssertNoThrow(try client.syncShutdown()) }
            let logger = Logger(label: "HTTPClient", factory: StreamLogHandler.standardOutput(label:))
            var request = HTTPClientRequest(url: "https://localhost:\(bin.port)/")
            request.method = .POST
            request.body = .stream(length: nil, [
                ByteBuffer(string: "1"),
                ByteBuffer(string: "2"),
                ByteBuffer(string: "34"),
            ].asAsyncSequence())

            guard let response = await XCTAssertNoThrowWithResult(
                try await client.execute(request, deadline: .now() + .seconds(10), logger: logger)
            ) else { return }
            XCTAssertEqual(response.headers["content-length"], [])
            guard let body = await XCTAssertNoThrowWithResult(
                try await response.body.collect()
            ) else { return }
            XCTAssertEqual(body, ByteBuffer(string: "1234"))
        }
        #endif
    }

    func testPostWithAsyncSequenceOfUInt8() {
        #if compiler(>=5.5) && canImport(_Concurrency)
        guard #available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *) else { return }
        XCTAsyncTest {
            let bin = HTTPBin(.http2(compress: false)) { _ in HTTPEchoHandler() }
            defer { XCTAssertNoThrow(try bin.shutdown()) }
            let client = makeDefaultHTTPClient()
            defer { XCTAssertNoThrow(try client.syncShutdown()) }
            let logger = Logger(label: "HTTPClient", factory: StreamLogHandler.standardOutput(label:))
            var request = HTTPClientRequest(url: "https://localhost:\(bin.port)/")
            request.method = .POST
            request.body = .stream(length: nil, "1234".utf8.asAsyncSequence())

            guard let response = await XCTAssertNoThrowWithResult(
                try await client.execute(request, deadline: .now() + .seconds(10), logger: logger)
            ) else { return }
            XCTAssertEqual(response.headers["content-length"], [])
            guard let body = await XCTAssertNoThrowWithResult(
                try await response.body.collect()
            ) else { return }
            XCTAssertEqual(body, ByteBuffer(string: "1234"))
        }
        #endif
    }

    func testPostWithFragmentedAsyncSequenceOfByteBuffers() {
        #if compiler(>=5.5) && canImport(_Concurrency)
        guard #available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *) else { return }
        XCTAsyncTest {
            let bin = HTTPBin(.http2(compress: false)) { _ in HTTPEchoHandler() }
            defer { XCTAssertNoThrow(try bin.shutdown()) }
            let client = makeDefaultHTTPClient()
            defer { XCTAssertNoThrow(try client.syncShutdown()) }
            let logger = Logger(label: "HTTPClient", factory: StreamLogHandler.standardOutput(label:))
            var request = HTTPClientRequest(url: "https://localhost:\(bin.port)/")
            request.method = .POST
            let streamWriter = AsyncSequenceWriter<ByteBuffer>()
            request.body = .stream(length: nil, streamWriter)

            guard let response = await XCTAssertNoThrowWithResult(
                try await client.execute(request, deadline: .now() + .seconds(10), logger: logger)
            ) else { return }
            XCTAssertEqual(response.headers["content-length"], [])

            let fragments = [
                ByteBuffer(string: "1"),
                ByteBuffer(string: "2"),
                ByteBuffer(string: "34"),
            ]
            let bodyIterator = response.body.makeAsyncIterator()
            for expectedFragment in fragments {
                streamWriter.write(expectedFragment)
                guard let actualFragment = await XCTAssertNoThrowWithResult(
                    try await bodyIterator.next()
                ) else { return }
                XCTAssertEqual(expectedFragment, actualFragment)
            }

            streamWriter.end()
            guard let lastResult = await XCTAssertNoThrowWithResult(
                try await bodyIterator.next()
            ) else { return }
            XCTAssertEqual(lastResult, nil)
        }
        #endif
    }

    func testPostWithFragmentedAsyncSequenceOfLargeByteBuffers() {
        #if compiler(>=5.5) && canImport(_Concurrency)
        guard #available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *) else { return }
        XCTAsyncTest {
            let bin = HTTPBin(.http2(compress: false)) { _ in HTTPEchoHandler() }
            defer { XCTAssertNoThrow(try bin.shutdown()) }
            let client = makeDefaultHTTPClient()
            defer { XCTAssertNoThrow(try client.syncShutdown()) }
            let logger = Logger(label: "HTTPClient", factory: StreamLogHandler.standardOutput(label:))
            var request = HTTPClientRequest(url: "https://localhost:\(bin.port)/")
            request.method = .POST
            let streamWriter = AsyncSequenceWriter<ByteBuffer>()
            request.body = .stream(length: nil, streamWriter)

            guard let response = await XCTAssertNoThrowWithResult(
                try await client.execute(request, deadline: .now() + .seconds(10), logger: logger)
            ) else { return }
            XCTAssertEqual(response.headers["content-length"], [])

            let fragments = [
                ByteBuffer(string: String(repeating: "a", count: 4000)),
                ByteBuffer(string: String(repeating: "b", count: 4000)),
                ByteBuffer(string: String(repeating: "c", count: 4000)),
                ByteBuffer(string: String(repeating: "d", count: 4000)),
            ]
            let bodyIterator = response.body.makeAsyncIterator()
            for expectedFragment in fragments {
                streamWriter.write(expectedFragment)
                guard let actualFragment = await XCTAssertNoThrowWithResult(
                    try await bodyIterator.next()
                ) else { return }
                XCTAssertEqual(expectedFragment, actualFragment)
            }

            streamWriter.end()
            guard let lastResult = await XCTAssertNoThrowWithResult(
                try await bodyIterator.next()
            ) else { return }
            XCTAssertEqual(lastResult, nil)
        }
        #endif
    }

    func testCanceling() {
        #if compiler(>=5.5) && canImport(_Concurrency)
        guard #available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *) else { return }
        XCTAsyncTest(timeout: 5) {
            let bin = HTTPBin()
            defer { XCTAssertNoThrow(try bin.shutdown()) }
            let client = makeDefaultHTTPClient()
            defer { XCTAssertNoThrow(try client.syncShutdown()) }
            let logger = Logger(label: "HTTPClient", factory: StreamLogHandler.standardOutput(label:))
            var request = HTTPClientRequest(url: "http://localhost:\(bin.port)/offline")
            request.method = .POST
            let streamWriter = AsyncSequenceWriter<ByteBuffer>()
            request.body = .stream(length: nil, streamWriter)

            let task = Task<HTTPClientResponse, Error> { [request] in
                try await client.execute(request, deadline: .now() + .seconds(2), logger: logger)
            }
            task.cancel()
            await XCTAssertThrowsError(try await task.value) { error in
                XCTAssertEqual(error as? HTTPClientError, .cancelled)
            }
        }
        #endif
    }

    func testDeadline() {
        #if compiler(>=5.5) && canImport(_Concurrency)
        guard #available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *) else { return }
        XCTAsyncTest(timeout: 5) {
            let bin = HTTPBin(.http2(compress: false))
            defer { XCTAssertNoThrow(try bin.shutdown()) }
            let client = makeDefaultHTTPClient()
            defer { XCTAssertNoThrow(try client.syncShutdown()) }
            let logger = Logger(label: "HTTPClient", factory: StreamLogHandler.standardOutput(label:))
            let request = HTTPClientRequest(url: "https://localhost:\(bin.port)/wait")

            let task = Task<HTTPClientResponse, Error> { [request] in
                try await client.execute(request, deadline: .now() + .milliseconds(100), logger: logger)
            }
            await XCTAssertThrowsError(try await task.value) {
                XCTAssertEqual($0 as? HTTPClientError, HTTPClientError.deadlineExceeded)
            }
        }
        #endif
    }

    func testImmediateDeadline() {
        #if compiler(>=5.5) && canImport(_Concurrency)
        guard #available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *) else { return }
        XCTAsyncTest(timeout: 5) {
            let bin = HTTPBin()
            defer { XCTAssertNoThrow(try bin.shutdown()) }
            let client = makeDefaultHTTPClient()
            defer { XCTAssertNoThrow(try client.syncShutdown()) }
            let logger = Logger(label: "HTTPClient", factory: StreamLogHandler.standardOutput(label:))
            let request = HTTPClientRequest(url: "http://localhost:\(bin.port)/wait")

            let task = Task<HTTPClientResponse, Error> { [request] in
                try await client.execute(request, deadline: .now(), logger: logger)
            }
            await XCTAssertThrowsError(try await task.value) {
                XCTAssertEqual($0 as? HTTPClientError, HTTPClientError.deadlineExceeded)
            }
            print("done")
        }
        #endif
    }

    func testInvalidURL() {
        #if compiler(>=5.5) && canImport(_Concurrency)
        guard #available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *) else { return }
        XCTAsyncTest(timeout: 5) {
            let client = makeDefaultHTTPClient()
            defer { XCTAssertNoThrow(try client.syncShutdown()) }
            let logger = Logger(label: "HTTPClient", factory: StreamLogHandler.standardOutput(label:))
            let request = HTTPClientRequest(url: "") // invalid URL

            await XCTAssertThrowsError(try await client.execute(request, deadline: .now() + .seconds(2), logger: logger)) {
                XCTAssertEqual($0 as? HTTPClientError, .invalidURL)
            }
        }
        #endif
    }
}

#if compiler(>=5.5) && canImport(_Concurrency)
extension AsyncSequence where Element == ByteBuffer {
    func collect() async rethrows -> ByteBuffer {
        try await self.reduce(into: ByteBuffer()) { accumulatingBuffer, nextBuffer in
            var nextBuffer = nextBuffer
            accumulatingBuffer.writeBuffer(&nextBuffer)
        }
    }
}
#endif
