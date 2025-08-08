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

import Algorithms
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import XCTest

@testable import AsyncHTTPClient

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
class HTTPClientRequestTests: XCTestCase {
    private typealias Request = HTTPClientRequest

    private typealias PreparedRequest = HTTPClientRequest.Prepared

    func testCustomHeadersAreRespected() {
        XCTAsyncTest {
            var request = Request(url: "https://example.com/get")
            request.headers = [
                "custom-header": "custom-header-value"
            ]
            var preparedRequest: PreparedRequest?
            XCTAssertNoThrow(preparedRequest = try PreparedRequest(request))
            guard let preparedRequest = preparedRequest else { return }

            XCTAssertEqual(
                preparedRequest.poolKey,
                .init(
                    scheme: .https,
                    connectionTarget: .domain(name: "example.com", port: 443),
                    tlsConfiguration: nil,
                    serverNameIndicatorOverride: nil
                )
            )
            XCTAssertEqual(
                preparedRequest.head,
                .init(
                    version: .http1_1,
                    method: .GET,
                    uri: "/get",
                    headers: [
                        "host": "example.com",
                        "custom-header": "custom-header-value",
                    ]
                )
            )
            XCTAssertEqual(
                preparedRequest.requestFramingMetadata,
                .init(
                    connectionClose: false,
                    body: .fixedSize(0)
                )
            )
            guard let buffer = await XCTAssertNoThrowWithResult(try await preparedRequest.body.read()) else { return }
            XCTAssertEqual(buffer, ByteBuffer())
        }
    }

    func testBasicAuth() {
        XCTAsyncTest {
            var request = Request(url: "https://example.com/get")
            request.setBasicAuth(username: "foo", password: "bar")
            var preparedRequest: PreparedRequest?
            XCTAssertNoThrow(preparedRequest = try PreparedRequest(request))
            guard let preparedRequest = preparedRequest else { return }
            XCTAssertEqual(preparedRequest.head.headers.first(name: "Authorization")!, "Basic Zm9vOmJhcg==")
        }
    }

    func testUnixScheme() {
        XCTAsyncTest {
            var request = Request(url: "unix://%2Fexample%2Ffolder.sock/some_path")
            request.headers = ["custom-header": "custom-value"]
            var preparedRequest: PreparedRequest?
            XCTAssertNoThrow(preparedRequest = try PreparedRequest(request))
            guard let preparedRequest = preparedRequest else { return }

            XCTAssertEqual(
                preparedRequest.poolKey,
                .init(
                    scheme: .unix,
                    connectionTarget: .unixSocket(path: "/some_path"),
                    tlsConfiguration: nil,
                    serverNameIndicatorOverride: nil
                )
            )
            XCTAssertEqual(
                preparedRequest.head,
                .init(
                    version: .http1_1,
                    method: .GET,
                    uri: "/",
                    headers: ["custom-header": "custom-value"]
                )
            )
            XCTAssertEqual(
                preparedRequest.requestFramingMetadata,
                .init(
                    connectionClose: false,
                    body: .fixedSize(0)
                )
            )
            guard let buffer = await XCTAssertNoThrowWithResult(try await preparedRequest.body.read()) else { return }
            XCTAssertEqual(buffer, ByteBuffer())
        }
    }

    func testHTTPUnixScheme() {
        XCTAsyncTest {
            var request = Request(url: "http+unix://%2Fexample%2Ffolder.sock/some_path")
            request.headers = ["custom-header": "custom-value"]
            var preparedRequest: PreparedRequest?
            XCTAssertNoThrow(preparedRequest = try PreparedRequest(request))
            guard let preparedRequest = preparedRequest else { return }

            XCTAssertEqual(
                preparedRequest.poolKey,
                .init(
                    scheme: .httpUnix,
                    connectionTarget: .unixSocket(path: "/example/folder.sock"),
                    tlsConfiguration: nil,
                    serverNameIndicatorOverride: nil
                )
            )
            XCTAssertEqual(
                preparedRequest.head,
                .init(
                    version: .http1_1,
                    method: .GET,
                    uri: "/some_path",
                    headers: ["custom-header": "custom-value"]
                )
            )
            XCTAssertEqual(
                preparedRequest.requestFramingMetadata,
                .init(
                    connectionClose: false,
                    body: .fixedSize(0)
                )
            )
            guard let buffer = await XCTAssertNoThrowWithResult(try await preparedRequest.body.read()) else { return }
            XCTAssertEqual(buffer, ByteBuffer())
        }
    }

    func testHTTPSUnixScheme() {
        XCTAsyncTest {
            var request = Request(url: "https+unix://%2Fexample%2Ffolder.sock/some_path")
            request.headers = ["custom-header": "custom-value"]
            var preparedRequest: PreparedRequest?
            XCTAssertNoThrow(preparedRequest = try PreparedRequest(request))
            guard let preparedRequest = preparedRequest else { return }

            XCTAssertEqual(
                preparedRequest.poolKey,
                .init(
                    scheme: .httpsUnix,
                    connectionTarget: .unixSocket(path: "/example/folder.sock"),
                    tlsConfiguration: nil,
                    serverNameIndicatorOverride: nil
                )
            )
            XCTAssertEqual(
                preparedRequest.head,
                .init(
                    version: .http1_1,
                    method: .GET,
                    uri: "/some_path",
                    headers: ["custom-header": "custom-value"]
                )
            )
            XCTAssertEqual(
                preparedRequest.requestFramingMetadata,
                .init(
                    connectionClose: false,
                    body: .fixedSize(0)
                )
            )
            guard let buffer = await XCTAssertNoThrowWithResult(try await preparedRequest.body.read()) else { return }
            XCTAssertEqual(buffer, ByteBuffer())
        }
    }

    func testGetWithoutBody() {
        XCTAsyncTest {
            let request = Request(url: "https://example.com/get")
            var preparedRequest: PreparedRequest?
            XCTAssertNoThrow(preparedRequest = try PreparedRequest(request))
            guard let preparedRequest = preparedRequest else { return }

            XCTAssertEqual(
                preparedRequest.poolKey,
                .init(
                    scheme: .https,
                    connectionTarget: .domain(name: "example.com", port: 443),
                    tlsConfiguration: nil,
                    serverNameIndicatorOverride: nil
                )
            )
            XCTAssertEqual(
                preparedRequest.head,
                .init(
                    version: .http1_1,
                    method: .GET,
                    uri: "/get",
                    headers: ["host": "example.com"]
                )
            )
            XCTAssertEqual(
                preparedRequest.requestFramingMetadata,
                .init(
                    connectionClose: false,
                    body: .fixedSize(0)
                )
            )
            guard let buffer = await XCTAssertNoThrowWithResult(try await preparedRequest.body.read()) else { return }
            XCTAssertEqual(buffer, ByteBuffer())
        }
    }

    func testPostWithoutBody() {
        XCTAsyncTest {
            var request = Request(url: "http://example.com/post")
            request.method = .POST
            var preparedRequest: PreparedRequest?
            XCTAssertNoThrow(preparedRequest = try PreparedRequest(request))
            guard let preparedRequest = preparedRequest else { return }

            XCTAssertEqual(
                preparedRequest.poolKey,
                .init(
                    scheme: .http,
                    connectionTarget: .domain(name: "example.com", port: 80),
                    tlsConfiguration: nil,
                    serverNameIndicatorOverride: nil
                )
            )
            XCTAssertEqual(
                preparedRequest.head,
                .init(
                    version: .http1_1,
                    method: .POST,
                    uri: "/post",
                    headers: [
                        "host": "example.com",
                        "content-length": "0",
                    ]
                )
            )
            XCTAssertEqual(
                preparedRequest.requestFramingMetadata,
                .init(
                    connectionClose: false,
                    body: .fixedSize(0)
                )
            )

            guard let buffer = await XCTAssertNoThrowWithResult(try await preparedRequest.body.read()) else { return }
            XCTAssertEqual(buffer, ByteBuffer())
        }
    }

    func testPostWithEmptyByteBuffer() {
        XCTAsyncTest {
            var request = Request(url: "http://example.com/post")
            request.method = .POST
            request.body = .bytes(ByteBuffer())
            var preparedRequest: PreparedRequest?
            XCTAssertNoThrow(preparedRequest = try PreparedRequest(request))
            guard let preparedRequest = preparedRequest else { return }

            XCTAssertEqual(
                preparedRequest.poolKey,
                .init(
                    scheme: .http,
                    connectionTarget: .domain(name: "example.com", port: 80),
                    tlsConfiguration: nil,
                    serverNameIndicatorOverride: nil
                )
            )
            XCTAssertEqual(
                preparedRequest.head,
                .init(
                    version: .http1_1,
                    method: .POST,
                    uri: "/post",
                    headers: [
                        "host": "example.com",
                        "content-length": "0",
                    ]
                )
            )
            XCTAssertEqual(
                preparedRequest.requestFramingMetadata,
                .init(
                    connectionClose: false,
                    body: .fixedSize(0)
                )
            )

            guard let buffer = await XCTAssertNoThrowWithResult(try await preparedRequest.body.read()) else { return }
            XCTAssertEqual(buffer, ByteBuffer())
        }
    }

    func testPostWithByteBuffer() {
        XCTAsyncTest {
            var request = Request(url: "http://example.com/post")
            request.method = .POST
            request.body = .bytes(.init(string: "post body"))
            var preparedRequest: PreparedRequest?
            XCTAssertNoThrow(preparedRequest = try PreparedRequest(request))
            guard let preparedRequest = preparedRequest else { return }

            XCTAssertEqual(
                preparedRequest.poolKey,
                .init(
                    scheme: .http,
                    connectionTarget: .domain(name: "example.com", port: 80),
                    tlsConfiguration: nil,
                    serverNameIndicatorOverride: nil
                )
            )
            XCTAssertEqual(
                preparedRequest.head,
                .init(
                    version: .http1_1,
                    method: .POST,
                    uri: "/post",
                    headers: [
                        "host": "example.com",
                        "content-length": "9",
                    ]
                )
            )
            XCTAssertEqual(
                preparedRequest.requestFramingMetadata,
                .init(
                    connectionClose: false,
                    body: .fixedSize(9)
                )
            )
            guard let buffer = await XCTAssertNoThrowWithResult(try await preparedRequest.body.read()) else { return }
            XCTAssertEqual(buffer, .init(string: "post body"))
        }
    }

    func testPostWithSequenceOfUnknownLength() {
        XCTAsyncTest {
            var request = Request(url: "http://example.com/post")
            request.method = .POST
            let sequence = AnySendableSequence(ByteBuffer(string: "post body").readableBytesView)
            request.body = .bytes(sequence, length: .unknown)
            var preparedRequest: PreparedRequest?
            XCTAssertNoThrow(preparedRequest = try PreparedRequest(request))
            guard let preparedRequest = preparedRequest else { return }

            XCTAssertEqual(
                preparedRequest.poolKey,
                .init(
                    scheme: .http,
                    connectionTarget: .domain(name: "example.com", port: 80),
                    tlsConfiguration: nil,
                    serverNameIndicatorOverride: nil
                )
            )
            XCTAssertEqual(
                preparedRequest.head,
                .init(
                    version: .http1_1,
                    method: .POST,
                    uri: "/post",
                    headers: [
                        "host": "example.com",
                        "transfer-encoding": "chunked",
                    ]
                )
            )
            XCTAssertEqual(
                preparedRequest.requestFramingMetadata,
                .init(
                    connectionClose: false,
                    body: .stream
                )
            )
            guard let buffer = await XCTAssertNoThrowWithResult(try await preparedRequest.body.read()) else { return }
            XCTAssertEqual(buffer, .init(string: "post body"))
        }
    }

    func testPostWithSequenceWithFixedLength() {
        XCTAsyncTest {
            var request = Request(url: "http://example.com/post")
            request.method = .POST

            let sequence = AnySendableSequence(ByteBuffer(string: "post body").readableBytesView)
            request.body = .bytes(sequence, length: .known(Int64(9)))
            var preparedRequest: PreparedRequest?
            XCTAssertNoThrow(preparedRequest = try PreparedRequest(request))
            guard let preparedRequest = preparedRequest else { return }

            XCTAssertEqual(
                preparedRequest.poolKey,
                .init(
                    scheme: .http,
                    connectionTarget: .domain(name: "example.com", port: 80),
                    tlsConfiguration: nil,
                    serverNameIndicatorOverride: nil
                )
            )
            XCTAssertEqual(
                preparedRequest.head,
                .init(
                    version: .http1_1,
                    method: .POST,
                    uri: "/post",
                    headers: [
                        "host": "example.com",
                        "content-length": "9",
                    ]
                )
            )
            XCTAssertEqual(
                preparedRequest.requestFramingMetadata,
                .init(
                    connectionClose: false,
                    body: .fixedSize(9)
                )
            )
            guard let buffer = await XCTAssertNoThrowWithResult(try await preparedRequest.body.read()) else { return }
            XCTAssertEqual(buffer, .init(string: "post body"))
        }
    }

    func testPostWithRandomAccessCollection() {
        XCTAsyncTest {
            var request = Request(url: "http://example.com/post")
            request.method = .POST
            let collection = ByteBuffer(string: "post body").readableBytesView
            request.body = .bytes(collection)
            var preparedRequest: PreparedRequest?
            XCTAssertNoThrow(preparedRequest = try PreparedRequest(request))
            guard let preparedRequest = preparedRequest else { return }

            XCTAssertEqual(
                preparedRequest.poolKey,
                .init(
                    scheme: .http,
                    connectionTarget: .domain(name: "example.com", port: 80),
                    tlsConfiguration: nil,
                    serverNameIndicatorOverride: nil
                )
            )
            XCTAssertEqual(
                preparedRequest.head,
                .init(
                    version: .http1_1,
                    method: .POST,
                    uri: "/post",
                    headers: [
                        "host": "example.com",
                        "content-length": "9",
                    ]
                )
            )
            XCTAssertEqual(
                preparedRequest.requestFramingMetadata,
                .init(
                    connectionClose: false,
                    body: .fixedSize(9)
                )
            )
            guard let buffer = await XCTAssertNoThrowWithResult(try await preparedRequest.body.read()) else { return }
            XCTAssertEqual(buffer, .init(string: "post body"))
        }
    }

    func testPostWithAsyncSequenceOfUnknownLength() {
        XCTAsyncTest {
            var request = Request(url: "http://example.com/post")
            request.method = .POST
            let asyncSequence = ByteBuffer(string: "post body")
                .readableBytesView
                .uncheckedSendableChunks(ofCount: 2)
                .async
                .map { ByteBuffer($0) }

            request.body = .stream(asyncSequence, length: .unknown)
            var preparedRequest: PreparedRequest?
            XCTAssertNoThrow(preparedRequest = try PreparedRequest(request))
            guard let preparedRequest = preparedRequest else { return }

            XCTAssertEqual(
                preparedRequest.poolKey,
                .init(
                    scheme: .http,
                    connectionTarget: .domain(name: "example.com", port: 80),
                    tlsConfiguration: nil,
                    serverNameIndicatorOverride: nil
                )
            )
            XCTAssertEqual(
                preparedRequest.head,
                .init(
                    version: .http1_1,
                    method: .POST,
                    uri: "/post",
                    headers: [
                        "host": "example.com",
                        "transfer-encoding": "chunked",
                    ]
                )
            )
            XCTAssertEqual(
                preparedRequest.requestFramingMetadata,
                .init(
                    connectionClose: false,
                    body: .stream
                )
            )
            guard let buffer = await XCTAssertNoThrowWithResult(try await preparedRequest.body.read()) else { return }
            XCTAssertEqual(buffer, .init(string: "post body"))
        }
    }

    func testPostWithAsyncSequenceWithKnownLength() {
        XCTAsyncTest {
            var request = Request(url: "http://example.com/post")
            request.method = .POST
            let asyncSequence = ByteBuffer(string: "post body")
                .readableBytesView
                .uncheckedSendableChunks(ofCount: 2)
                .async
                .map { ByteBuffer($0) }

            request.body = .stream(asyncSequence, length: .known(Int64(9)))
            var preparedRequest: PreparedRequest?
            XCTAssertNoThrow(preparedRequest = try PreparedRequest(request))
            guard let preparedRequest = preparedRequest else { return }

            XCTAssertEqual(
                preparedRequest.poolKey,
                .init(
                    scheme: .http,
                    connectionTarget: .domain(name: "example.com", port: 80),
                    tlsConfiguration: nil,
                    serverNameIndicatorOverride: nil
                )
            )
            XCTAssertEqual(
                preparedRequest.head,
                .init(
                    version: .http1_1,
                    method: .POST,
                    uri: "/post",
                    headers: [
                        "host": "example.com",
                        "content-length": "9",
                    ]
                )
            )
            XCTAssertEqual(
                preparedRequest.requestFramingMetadata,
                .init(
                    connectionClose: false,
                    body: .fixedSize(9)
                )
            )
            guard let buffer = await XCTAssertNoThrowWithResult(try await preparedRequest.body.read()) else { return }
            XCTAssertEqual(buffer, .init(string: "post body"))
        }
    }

    func testChunkingRandomAccessCollection() async throws {
        let body = try await HTTPClientRequest.Body.bytes(
            Array(repeating: 0, count: bagOfBytesToByteBufferConversionChunkSize)
                + Array(repeating: 1, count: bagOfBytesToByteBufferConversionChunkSize)
                + Array(repeating: 2, count: bagOfBytesToByteBufferConversionChunkSize)
        ).collect()

        let expectedChunks = [
            ByteBuffer(repeating: 0, count: bagOfBytesToByteBufferConversionChunkSize),
            ByteBuffer(repeating: 1, count: bagOfBytesToByteBufferConversionChunkSize),
            ByteBuffer(repeating: 2, count: bagOfBytesToByteBufferConversionChunkSize),
        ]

        XCTAssertEqual(body, expectedChunks)
    }

    func testChunkingCollection() async throws {
        let body = try await HTTPClientRequest.Body.bytes(
            (String(repeating: "0", count: bagOfBytesToByteBufferConversionChunkSize)
                + String(repeating: "1", count: bagOfBytesToByteBufferConversionChunkSize)
                + String(repeating: "2", count: bagOfBytesToByteBufferConversionChunkSize)).utf8,
            length: .known(Int64(bagOfBytesToByteBufferConversionChunkSize * 3))
        ).collect()

        let expectedChunks = [
            ByteBuffer(repeating: UInt8(ascii: "0"), count: bagOfBytesToByteBufferConversionChunkSize),
            ByteBuffer(repeating: UInt8(ascii: "1"), count: bagOfBytesToByteBufferConversionChunkSize),
            ByteBuffer(repeating: UInt8(ascii: "2"), count: bagOfBytesToByteBufferConversionChunkSize),
        ]

        XCTAssertEqual(body, expectedChunks)
    }

    func testChunkingSequenceThatDoesNotImplementWithContiguousStorageIfAvailable() async throws {
        let bagOfBytesToByteBufferConversionChunkSize = 8
        let body = try await HTTPClientRequest.Body._bytes(
            AnySendableSequence(
                Array(repeating: 0, count: bagOfBytesToByteBufferConversionChunkSize)
                    + Array(repeating: 1, count: bagOfBytesToByteBufferConversionChunkSize)
            ),
            length: .known(Int64(bagOfBytesToByteBufferConversionChunkSize * 3)),
            bagOfBytesToByteBufferConversionChunkSize: bagOfBytesToByteBufferConversionChunkSize,
            byteBufferMaxSize: byteBufferMaxSize
        ).collect()

        let expectedChunks = [
            ByteBuffer(repeating: 0, count: bagOfBytesToByteBufferConversionChunkSize),
            ByteBuffer(repeating: 1, count: bagOfBytesToByteBufferConversionChunkSize),
        ]

        XCTAssertEqual(body, expectedChunks)
    }

    func testChunkingSequenceFastPath() async throws {
        func makeBytes() -> some Sequence<UInt8> & Sendable {
            Array(repeating: 0, count: bagOfBytesToByteBufferConversionChunkSize)
                + Array(repeating: 1, count: bagOfBytesToByteBufferConversionChunkSize)
                + Array(repeating: 2, count: bagOfBytesToByteBufferConversionChunkSize)
        }
        let body = try await HTTPClientRequest.Body.bytes(
            makeBytes(),
            length: .known(Int64(bagOfBytesToByteBufferConversionChunkSize * 3))
        ).collect()

        var firstChunk = ByteBuffer(repeating: 0, count: bagOfBytesToByteBufferConversionChunkSize)
        firstChunk.writeImmutableBuffer(ByteBuffer(repeating: 1, count: bagOfBytesToByteBufferConversionChunkSize))
        firstChunk.writeImmutableBuffer(ByteBuffer(repeating: 2, count: bagOfBytesToByteBufferConversionChunkSize))
        let expectedChunks = [
            firstChunk
        ]

        XCTAssertEqual(body, expectedChunks)
    }

    func testChunkingSequenceFastPathExceedingByteBufferMaxSize() async throws {
        let bagOfBytesToByteBufferConversionChunkSize = 8
        let byteBufferMaxSize = 16
        func makeBytes() -> some Sequence<UInt8> & Sendable {
            Array(repeating: 0, count: bagOfBytesToByteBufferConversionChunkSize)
                + Array(repeating: 1, count: bagOfBytesToByteBufferConversionChunkSize)
                + Array(repeating: 2, count: bagOfBytesToByteBufferConversionChunkSize)
        }
        let body = try await HTTPClientRequest.Body._bytes(
            makeBytes(),
            length: .known(Int64(bagOfBytesToByteBufferConversionChunkSize * 3)),
            bagOfBytesToByteBufferConversionChunkSize: bagOfBytesToByteBufferConversionChunkSize,
            byteBufferMaxSize: byteBufferMaxSize
        ).collect()

        var firstChunk = ByteBuffer(repeating: 0, count: bagOfBytesToByteBufferConversionChunkSize)
        firstChunk.writeImmutableBuffer(ByteBuffer(repeating: 1, count: bagOfBytesToByteBufferConversionChunkSize))
        let secondChunk = ByteBuffer(repeating: 2, count: bagOfBytesToByteBufferConversionChunkSize)
        let expectedChunks = [
            firstChunk,
            secondChunk,
        ]

        XCTAssertEqual(body, expectedChunks)
    }

    func testBodyStringChunking() throws {
        let body = try HTTPClient.Body.string(
            String(repeating: "0", count: bagOfBytesToByteBufferConversionChunkSize)
                + String(repeating: "1", count: bagOfBytesToByteBufferConversionChunkSize)
                + String(repeating: "2", count: bagOfBytesToByteBufferConversionChunkSize)
        ).collect().wait()

        let expectedChunks = [
            ByteBuffer(),  // We're currently emitting an empty chunk first.
            ByteBuffer(repeating: UInt8(ascii: "0"), count: bagOfBytesToByteBufferConversionChunkSize),
            ByteBuffer(repeating: UInt8(ascii: "1"), count: bagOfBytesToByteBufferConversionChunkSize),
            ByteBuffer(repeating: UInt8(ascii: "2"), count: bagOfBytesToByteBufferConversionChunkSize),
        ]

        XCTAssertEqual(body, expectedChunks)
    }

    func testBodyChunkingRandomAccessCollection() throws {
        let body = try HTTPClient.Body.bytes(
            Array(repeating: 0, count: bagOfBytesToByteBufferConversionChunkSize)
                + Array(repeating: 1, count: bagOfBytesToByteBufferConversionChunkSize)
                + Array(repeating: 2, count: bagOfBytesToByteBufferConversionChunkSize)
        ).collect().wait()

        let expectedChunks = [
            ByteBuffer(),  // We're currently emitting an empty chunk first.
            ByteBuffer(repeating: 0, count: bagOfBytesToByteBufferConversionChunkSize),
            ByteBuffer(repeating: 1, count: bagOfBytesToByteBufferConversionChunkSize),
            ByteBuffer(repeating: 2, count: bagOfBytesToByteBufferConversionChunkSize),
        ]

        XCTAssertEqual(body, expectedChunks)
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension AsyncSequence {
    func collect() async throws -> [Element] {
        try await self.reduce(into: []) { $0 += CollectionOfOne($1) }
    }
}

extension HTTPClient.Body {
    func collect() -> EventLoopFuture<[ByteBuffer]> {
        let eelg = EmbeddedEventLoopGroup(loops: 1)
        let el = eelg.next()
        let body = NIOLockedValueBox<[ByteBuffer]>([])
        let writer = StreamWriter {
            switch $0 {
            case .byteBuffer(let byteBuffer):
                body.withLockedValue { $0.append(byteBuffer) }
            case .fileRegion:
                fatalError("file region not supported")
            }
            return el.makeSucceededVoidFuture()
        }
        return self.stream(writer).map { _ in body.withLockedValue { $0 } }
    }
}

private struct LengthMismatch: Error {
    var announcedLength: Int64
    var actualLength: Int64
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
                announcedLength != Int64(buffer.readableBytes)
            {
                throw LengthMismatch(announcedLength: announcedLength, actualLength: Int64(buffer.readableBytes))
            }
            return buffer
        case .asyncSequence(length: let announcedLength, let makeAsyncIterator):
            var accumulatedBuffer = ByteBuffer()
            let generate = makeAsyncIterator()
            while var buffer = try await generate(ByteBufferAllocator()) {
                accumulatedBuffer.writeBuffer(&buffer)
            }
            if case .known(let announcedLength) = announcedLength,
                announcedLength != Int64(accumulatedBuffer.readableBytes)
            {
                throw LengthMismatch(
                    announcedLength: announcedLength,
                    actualLength: Int64(accumulatedBuffer.readableBytes)
                )
            }
            return accumulatedBuffer
        }
    }
}

// swift-algorithms hasn't adopted Sendable yet. By inspection ChunksOfCountCollection should be
// Sendable assuming the underlying collection is. This wrapper allows us to avoid a blanket
// preconcurrency import of the Algorithms module.
struct UncheckedSendableChunksOfCountCollection<Base: Collection>: Collection, @unchecked Sendable
where Base: Sendable {
    typealias Element = Base.SubSequence
    typealias Index = ChunksOfCountCollection<Base>.Index

    private let underlying: ChunksOfCountCollection<Base>

    init(_ underlying: ChunksOfCountCollection<Base>) {
        self.underlying = underlying
    }

    var startIndex: Index { self.underlying.startIndex }
    var endIndex: Index { self.underlying.endIndex }

    subscript(position: Index) -> Base.SubSequence {
        self.underlying[position]
    }

    func index(after i: Index) -> Index {
        self.underlying.index(after: i)
    }
}

extension Collection where Self: Sendable {
    func uncheckedSendableChunks(ofCount count: Int) -> UncheckedSendableChunksOfCountCollection<Self> {
        UncheckedSendableChunksOfCountCollection(self.chunks(ofCount: count))
    }
}
