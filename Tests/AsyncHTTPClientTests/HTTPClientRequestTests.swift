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
import NIOCore
import XCTest

class HTTPClientRequestTests: XCTestCase {
    #if compiler(>=5.5.2) && canImport(_Concurrency)
    @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
    private typealias Request = HTTPClientRequest

    @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
    private typealias PreparedRequest = HTTPClientRequest.Prepared
    #endif

    func testCustomHeadersAreRespected() {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest {
            var request = Request(url: "https://example.com/get")
            request.headers = [
                "custom-header": "custom-header-value",
            ]
            var preparedRequest: PreparedRequest?
            XCTAssertNoThrow(preparedRequest = try PreparedRequest(request))
            guard let preparedRequest = preparedRequest else { return }

            XCTAssertEqual(preparedRequest.poolKey, .init(
                scheme: .https,
                connectionTarget: .domain(name: "example.com", port: 443),
                tlsConfiguration: nil
            ))
            XCTAssertEqual(preparedRequest.head, .init(
                version: .http1_1,
                method: .GET,
                uri: "/get",
                headers: [
                    "host": "example.com",
                    "custom-header": "custom-header-value",
                ]
            ))
            XCTAssertEqual(preparedRequest.requestFramingMetadata, .init(
                connectionClose: false,
                body: .fixedSize(0)
            ))
            guard let buffer = await XCTAssertNoThrowWithResult(try await preparedRequest.body.read()) else { return }
            XCTAssertEqual(buffer, ByteBuffer())
        }
        #endif
    }

    func testUnixScheme() {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest {
            var request = Request(url: "unix://%2Fexample%2Ffolder.sock/some_path")
            request.headers = ["custom-header": "custom-value"]
            var preparedRequest: PreparedRequest?
            XCTAssertNoThrow(preparedRequest = try PreparedRequest(request))
            guard let preparedRequest = preparedRequest else { return }

            XCTAssertEqual(preparedRequest.poolKey, .init(
                scheme: .unix,
                connectionTarget: .unixSocket(path: "/some_path"),
                tlsConfiguration: nil
            ))
            XCTAssertEqual(preparedRequest.head, .init(
                version: .http1_1,
                method: .GET,
                uri: "/",
                headers: ["custom-header": "custom-value"]
            ))
            XCTAssertEqual(preparedRequest.requestFramingMetadata, .init(
                connectionClose: false,
                body: .fixedSize(0)
            ))
            guard let buffer = await XCTAssertNoThrowWithResult(try await preparedRequest.body.read()) else { return }
            XCTAssertEqual(buffer, ByteBuffer())
        }
        #endif
    }

    func testHTTPUnixScheme() {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest {
            var request = Request(url: "http+unix://%2Fexample%2Ffolder.sock/some_path")
            request.headers = ["custom-header": "custom-value"]
            var preparedRequest: PreparedRequest?
            XCTAssertNoThrow(preparedRequest = try PreparedRequest(request))
            guard let preparedRequest = preparedRequest else { return }

            XCTAssertEqual(preparedRequest.poolKey, .init(
                scheme: .httpUnix,
                connectionTarget: .unixSocket(path: "/example/folder.sock"),
                tlsConfiguration: nil
            ))
            XCTAssertEqual(preparedRequest.head, .init(
                version: .http1_1,
                method: .GET,
                uri: "/some_path",
                headers: ["custom-header": "custom-value"]
            ))
            XCTAssertEqual(preparedRequest.requestFramingMetadata, .init(
                connectionClose: false,
                body: .fixedSize(0)
            ))
            guard let buffer = await XCTAssertNoThrowWithResult(try await preparedRequest.body.read()) else { return }
            XCTAssertEqual(buffer, ByteBuffer())
        }
        #endif
    }

    func testHTTPSUnixScheme() {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest {
            var request = Request(url: "https+unix://%2Fexample%2Ffolder.sock/some_path")
            request.headers = ["custom-header": "custom-value"]
            var preparedRequest: PreparedRequest?
            XCTAssertNoThrow(preparedRequest = try PreparedRequest(request))
            guard let preparedRequest = preparedRequest else { return }

            XCTAssertEqual(preparedRequest.poolKey, .init(
                scheme: .httpsUnix,
                connectionTarget: .unixSocket(path: "/example/folder.sock"),
                tlsConfiguration: nil
            ))
            XCTAssertEqual(preparedRequest.head, .init(
                version: .http1_1,
                method: .GET,
                uri: "/some_path",
                headers: ["custom-header": "custom-value"]
            ))
            XCTAssertEqual(preparedRequest.requestFramingMetadata, .init(
                connectionClose: false,
                body: .fixedSize(0)
            ))
            guard let buffer = await XCTAssertNoThrowWithResult(try await preparedRequest.body.read()) else { return }
            XCTAssertEqual(buffer, ByteBuffer())
        }
        #endif
    }

    func testGetWithoutBody() {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest {
            let request = Request(url: "https://example.com/get")
            var preparedRequest: PreparedRequest?
            XCTAssertNoThrow(preparedRequest = try PreparedRequest(request))
            guard let preparedRequest = preparedRequest else { return }

            XCTAssertEqual(preparedRequest.poolKey, .init(
                scheme: .https,
                connectionTarget: .domain(name: "example.com", port: 443),
                tlsConfiguration: nil
            ))
            XCTAssertEqual(preparedRequest.head, .init(
                version: .http1_1,
                method: .GET,
                uri: "/get",
                headers: ["host": "example.com"]
            ))
            XCTAssertEqual(preparedRequest.requestFramingMetadata, .init(
                connectionClose: false,
                body: .fixedSize(0)
            ))
            guard let buffer = await XCTAssertNoThrowWithResult(try await preparedRequest.body.read()) else { return }
            XCTAssertEqual(buffer, ByteBuffer())
        }
        #endif
    }

    func testPostWithoutBody() {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest {
            var request = Request(url: "http://example.com/post")
            request.method = .POST
            var preparedRequest: PreparedRequest?
            XCTAssertNoThrow(preparedRequest = try PreparedRequest(request))
            guard let preparedRequest = preparedRequest else { return }

            XCTAssertEqual(preparedRequest.poolKey, .init(
                scheme: .http,
                connectionTarget: .domain(name: "example.com", port: 80),
                tlsConfiguration: nil
            ))
            XCTAssertEqual(preparedRequest.head, .init(
                version: .http1_1,
                method: .POST,
                uri: "/post",
                headers: [
                    "host": "example.com",
                    "content-length": "0",
                ]
            ))
            XCTAssertEqual(preparedRequest.requestFramingMetadata, .init(
                connectionClose: false,
                body: .fixedSize(0)
            ))

            guard let buffer = await XCTAssertNoThrowWithResult(try await preparedRequest.body.read()) else { return }
            XCTAssertEqual(buffer, ByteBuffer())
        }
        #endif
    }

    func testPostWithEmptyByteBuffer() {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest {
            var request = Request(url: "http://example.com/post")
            request.method = .POST
            request.body = .bytes(ByteBuffer())
            var preparedRequest: PreparedRequest?
            XCTAssertNoThrow(preparedRequest = try PreparedRequest(request))
            guard let preparedRequest = preparedRequest else { return }

            XCTAssertEqual(preparedRequest.poolKey, .init(
                scheme: .http,
                connectionTarget: .domain(name: "example.com", port: 80),
                tlsConfiguration: nil
            ))
            XCTAssertEqual(preparedRequest.head, .init(
                version: .http1_1,
                method: .POST,
                uri: "/post",
                headers: [
                    "host": "example.com",
                    "content-length": "0",
                ]
            ))
            XCTAssertEqual(preparedRequest.requestFramingMetadata, .init(
                connectionClose: false,
                body: .fixedSize(0)
            ))

            guard let buffer = await XCTAssertNoThrowWithResult(try await preparedRequest.body.read()) else { return }
            XCTAssertEqual(buffer, ByteBuffer())
        }
        #endif
    }

    func testPostWithByteBuffer() {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest {
            var request = Request(url: "http://example.com/post")
            request.method = .POST
            request.body = .bytes(.init(string: "post body"))
            var preparedRequest: PreparedRequest?
            XCTAssertNoThrow(preparedRequest = try PreparedRequest(request))
            guard let preparedRequest = preparedRequest else { return }

            XCTAssertEqual(preparedRequest.poolKey, .init(
                scheme: .http,
                connectionTarget: .domain(name: "example.com", port: 80),
                tlsConfiguration: nil
            ))
            XCTAssertEqual(preparedRequest.head, .init(
                version: .http1_1,
                method: .POST,
                uri: "/post",
                headers: [
                    "host": "example.com",
                    "content-length": "9",
                ]
            ))
            XCTAssertEqual(preparedRequest.requestFramingMetadata, .init(
                connectionClose: false,
                body: .fixedSize(9)
            ))
            guard let buffer = await XCTAssertNoThrowWithResult(try await preparedRequest.body.read()) else { return }
            XCTAssertEqual(buffer, .init(string: "post body"))
        }
        #endif
    }

    func testPostWithSequenceOfUnknownLength() {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest {
            var request = Request(url: "http://example.com/post")
            request.method = .POST
            let sequence = AnySequence(ByteBuffer(string: "post body").readableBytesView)
            request.body = .bytes(sequence, length: .unknown)
            var preparedRequest: PreparedRequest?
            XCTAssertNoThrow(preparedRequest = try PreparedRequest(request))
            guard let preparedRequest = preparedRequest else { return }

            XCTAssertEqual(preparedRequest.poolKey, .init(
                scheme: .http,
                connectionTarget: .domain(name: "example.com", port: 80),
                tlsConfiguration: nil
            ))
            XCTAssertEqual(preparedRequest.head, .init(
                version: .http1_1,
                method: .POST,
                uri: "/post",
                headers: [
                    "host": "example.com",
                    "transfer-encoding": "chunked",
                ]
            ))
            XCTAssertEqual(preparedRequest.requestFramingMetadata, .init(
                connectionClose: false,
                body: .stream
            ))
            guard let buffer = await XCTAssertNoThrowWithResult(try await preparedRequest.body.read()) else { return }
            XCTAssertEqual(buffer, .init(string: "post body"))
        }
        #endif
    }

    func testPostWithSequenceWithFixedLength() {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest {
            var request = Request(url: "http://example.com/post")
            request.method = .POST

            let sequence = AnySequence(ByteBuffer(string: "post body").readableBytesView)
            request.body = .bytes(sequence, length: .known(9))
            var preparedRequest: PreparedRequest?
            XCTAssertNoThrow(preparedRequest = try PreparedRequest(request))
            guard let preparedRequest = preparedRequest else { return }

            XCTAssertEqual(preparedRequest.poolKey, .init(
                scheme: .http,
                connectionTarget: .domain(name: "example.com", port: 80),
                tlsConfiguration: nil
            ))
            XCTAssertEqual(preparedRequest.head, .init(
                version: .http1_1,
                method: .POST,
                uri: "/post",
                headers: [
                    "host": "example.com",
                    "content-length": "9",
                ]
            ))
            XCTAssertEqual(preparedRequest.requestFramingMetadata, .init(
                connectionClose: false,
                body: .fixedSize(9)
            ))
            guard let buffer = await XCTAssertNoThrowWithResult(try await preparedRequest.body.read()) else { return }
            XCTAssertEqual(buffer, .init(string: "post body"))
        }
        #endif
    }

    func testPostWithRandomAccessCollection() {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest {
            var request = Request(url: "http://example.com/post")
            request.method = .POST
            let collection = ByteBuffer(string: "post body").readableBytesView
            request.body = .bytes(collection)
            var preparedRequest: PreparedRequest?
            XCTAssertNoThrow(preparedRequest = try PreparedRequest(request))
            guard let preparedRequest = preparedRequest else { return }

            XCTAssertEqual(preparedRequest.poolKey, .init(
                scheme: .http,
                connectionTarget: .domain(name: "example.com", port: 80),
                tlsConfiguration: nil
            ))
            XCTAssertEqual(preparedRequest.head, .init(
                version: .http1_1,
                method: .POST,
                uri: "/post",
                headers: [
                    "host": "example.com",
                    "content-length": "9",
                ]
            ))
            XCTAssertEqual(preparedRequest.requestFramingMetadata, .init(
                connectionClose: false,
                body: .fixedSize(9)
            ))
            guard let buffer = await XCTAssertNoThrowWithResult(try await preparedRequest.body.read()) else { return }
            XCTAssertEqual(buffer, .init(string: "post body"))
        }
        #endif
    }

    func testPostWithAsyncSequenceOfUnknownLength() {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest {
            var request = Request(url: "http://example.com/post")
            request.method = .POST
            let asyncSequence = ByteBuffer(string: "post body")
                .readableBytesView
                .chunked(maxChunkSize: 2)
                .asAsyncSequence()
                .map { ByteBuffer($0) }

            request.body = .stream(asyncSequence, length: .unknown)
            var preparedRequest: PreparedRequest?
            XCTAssertNoThrow(preparedRequest = try PreparedRequest(request))
            guard let preparedRequest = preparedRequest else { return }

            XCTAssertEqual(preparedRequest.poolKey, .init(
                scheme: .http,
                connectionTarget: .domain(name: "example.com", port: 80),
                tlsConfiguration: nil
            ))
            XCTAssertEqual(preparedRequest.head, .init(
                version: .http1_1,
                method: .POST,
                uri: "/post",
                headers: [
                    "host": "example.com",
                    "transfer-encoding": "chunked",
                ]
            ))
            XCTAssertEqual(preparedRequest.requestFramingMetadata, .init(
                connectionClose: false,
                body: .stream
            ))
            guard let buffer = await XCTAssertNoThrowWithResult(try await preparedRequest.body.read()) else { return }
            XCTAssertEqual(buffer, .init(string: "post body"))
        }
        #endif
    }

    func testPostWithAsyncSequenceWithKnownLength() {
        #if compiler(>=5.5.2) && canImport(_Concurrency)
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest {
            var request = Request(url: "http://example.com/post")
            request.method = .POST
            let asyncSequence = ByteBuffer(string: "post body")
                .readableBytesView
                .chunked(maxChunkSize: 2)
                .asAsyncSequence()
                .map { ByteBuffer($0) }

            request.body = .stream(asyncSequence, length: .known(9))
            var preparedRequest: PreparedRequest?
            XCTAssertNoThrow(preparedRequest = try PreparedRequest(request))
            guard let preparedRequest = preparedRequest else { return }

            XCTAssertEqual(preparedRequest.poolKey, .init(
                scheme: .http,
                connectionTarget: .domain(name: "example.com", port: 80),
                tlsConfiguration: nil
            ))
            XCTAssertEqual(preparedRequest.head, .init(
                version: .http1_1,
                method: .POST,
                uri: "/post",
                headers: [
                    "host": "example.com",
                    "content-length": "9",
                ]
            ))
            XCTAssertEqual(preparedRequest.requestFramingMetadata, .init(
                connectionClose: false,
                body: .fixedSize(9)
            ))
            guard let buffer = await XCTAssertNoThrowWithResult(try await preparedRequest.body.read()) else { return }
            XCTAssertEqual(buffer, .init(string: "post body"))
        }
        #endif
    }
}

#if compiler(>=5.5.2) && canImport(_Concurrency)
private struct LengthMismatch: Error {
    var announcedLength: Int
    var actualLength: Int
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension Optional where Wrapped == HTTPClientRequest.Body {
    /// Accumulates all data from `self` into a single `ByteBuffer` and checks that the user specified length matches
    /// the length of the accumulated data.
    fileprivate func read() async throws -> ByteBuffer {
        switch self?.mode {
        case .none:
            return ByteBuffer()
        case .byteBuffer(let buffer):
            return buffer
        case .sequence(let announcedLength, _, let generate):
            let buffer = generate(ByteBufferAllocator())
            if case .known(let announcedLength) = announcedLength,
               announcedLength != buffer.readableBytes {
                throw LengthMismatch(announcedLength: announcedLength, actualLength: buffer.readableBytes)
            }
            return buffer
        case .asyncSequence(length: let announcedLength, let generate):
            var accumulatedBuffer = ByteBuffer()
            while var buffer = try await generate(ByteBufferAllocator()) {
                accumulatedBuffer.writeBuffer(&buffer)
            }
            if case .known(let announcedLength) = announcedLength,
               announcedLength != accumulatedBuffer.readableBytes {
                throw LengthMismatch(announcedLength: announcedLength, actualLength: accumulatedBuffer.readableBytes)
            }
            return accumulatedBuffer
        }
    }
}

struct ChunkedSequence<Wrapped: Collection>: Sequence {
    struct Iterator: IteratorProtocol {
        fileprivate var remainingElements: Wrapped.SubSequence
        fileprivate let maxChunkSize: Int
        mutating func next() -> Wrapped.SubSequence? {
            guard !self.remainingElements.isEmpty else {
                return nil
            }
            let chunk = self.remainingElements.prefix(self.maxChunkSize)
            self.remainingElements = self.remainingElements.dropFirst(self.maxChunkSize)
            return chunk
        }
    }

    fileprivate let wrapped: Wrapped
    fileprivate let maxChunkSize: Int

    func makeIterator() -> Iterator {
        .init(remainingElements: self.wrapped[...], maxChunkSize: self.maxChunkSize)
    }
}

extension Collection {
    /// Lazily splits `self` into `SubSequence`s with `maxChunkSize` elements.
    /// - Parameter maxChunkSize: size of each chunk except the last one which can be smaller if not enough elements are remaining.
    func chunked(maxChunkSize: Int) -> ChunkedSequence<Self> {
        .init(wrapped: self, maxChunkSize: maxChunkSize)
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
struct AsyncSequenceFromSyncSequence<Wrapped: Sequence>: AsyncSequence {
    typealias Element = Wrapped.Element
    struct AsyncIterator: AsyncIteratorProtocol {
        fileprivate var iterator: Wrapped.Iterator
        mutating func next() async throws -> Wrapped.Element? {
            self.iterator.next()
        }
    }

    fileprivate let wrapped: Wrapped

    func makeAsyncIterator() -> AsyncIterator {
        .init(iterator: self.wrapped.makeIterator())
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension Sequence {
    /// Turns `self` into an `AsyncSequence` by wending each element of `self` asynchronously.
    func asAsyncSequence() -> AsyncSequenceFromSyncSequence<Self> {
        .init(wrapped: self)
    }
}

#endif
