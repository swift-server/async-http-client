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
    @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
    private typealias Request = HTTPClientRequest

    @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
    private typealias PreparedRequest = HTTPClientRequest.Prepared

    func testCustomHeadersAreRespected() {
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
    }

    func testUnixScheme() {
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
    }

    func testHTTPUnixScheme() {
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
    }

    func testHTTPSUnixScheme() {
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
    }

    func testGetWithoutBody() {
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
    }

    func testPostWithoutBody() {
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
    }

    func testPostWithEmptyByteBuffer() {
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
    }

    func testPostWithByteBuffer() {
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
    }

    func testPostWithSequenceOfUnknownLength() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest {
            var request = Request(url: "http://example.com/post")
            request.method = .POST
            let sequence = AnySendableSequence(ByteBuffer(string: "post body").readableBytesView)
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
    }

    func testPostWithSequenceWithFixedLength() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest {
            var request = Request(url: "http://example.com/post")
            request.method = .POST

            let sequence = AnySendableSequence(ByteBuffer(string: "post body").readableBytesView)
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
    }

    func testPostWithRandomAccessCollection() {
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
    }

    func testPostWithAsyncSequenceOfUnknownLength() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest {
            var request = Request(url: "http://example.com/post")
            request.method = .POST
            let asyncSequence = ByteBuffer(string: "post body")
                .readableBytesView
                .chunked(maxChunkSize: 2)
                .async
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
    }

    func testPostWithAsyncSequenceWithKnownLength() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest {
            var request = Request(url: "http://example.com/post")
            request.method = .POST
            let asyncSequence = ByteBuffer(string: "post body")
                .readableBytesView
                .chunked(maxChunkSize: 2)
                .async
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
    }
}

private struct LengthMismatch: Error {
    var announcedLength: Int
    var actualLength: Int
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension Optional where Wrapped == HTTPClientRequest.Prepared.Body {
    /// Accumulates all data from `self` into a single `ByteBuffer` and checks that the user specified length matches
    /// the length of the accumulated data.
    fileprivate func read() async throws -> ByteBuffer {
        switch self {
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

extension ChunkedSequence: Sendable where Wrapped: Sendable {}

extension Collection {
    /// Lazily splits `self` into `SubSequence`s with `maxChunkSize` elements.
    /// - Parameter maxChunkSize: size of each chunk except the last one which can be smaller if not enough elements are remaining.
    func chunked(maxChunkSize: Int) -> ChunkedSequence<Self> {
        .init(wrapped: self, maxChunkSize: maxChunkSize)
    }
}
