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

import Algorithms
import NIOCore
import NIOHTTP1
import NIOSSL

@usableFromInline
let bagOfBytesToByteBufferConversionChunkSize = 1024 * 1024 * 4

#if arch(arm) || arch(i386)
// on 32-bit platforms we can't make use of a whole UInt32.max (as it doesn't fit in an Int)
@usableFromInline
let byteBufferMaxSize = Int.max
#else
// on 64-bit platforms we're good
@usableFromInline
let byteBufferMaxSize = Int(UInt32.max)
#endif

/// A representation of an HTTP request for the Swift Concurrency HTTPClient API.
///
/// This object is similar to ``HTTPClient/Request``, but used for the Swift Concurrency API.
///
/// - note: For many ``HTTPClientRequest/body-swift.property`` configurations, this type is _not_ a value type
///    (https://github.com/swift-server/async-http-client/issues/708).
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
public struct HTTPClientRequest: Sendable {
    /// The request URL, including scheme, hostname, and optionally port.
    public var url: String

    /// The request method.
    public var method: HTTPMethod

    /// The request headers.
    public var headers: HTTPHeaders

    /// The request body, if any.
    public var body: Body?

    /// Request-specific TLS configuration, defaults to no request-specific TLS configuration.
    public var tlsConfiguration: TLSConfiguration?

    public init(url: String) {
        self.url = url
        self.method = .GET
        self.headers = .init()
        self.body = .none
        self.tlsConfiguration = nil
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension HTTPClientRequest {
    /// An HTTP request body.
    ///
    /// This object encapsulates the difference between streamed HTTP request bodies and those bodies that
    /// are already entirely in memory.
    public struct Body: Sendable {
        @usableFromInline
        internal enum Mode: Sendable {
            /// - parameters:
            ///     - length: complete body length.
            ///     If `length` is `.known`, `nextBodyPart` is not allowed to produce more bytes than `length` defines.
            ///     - makeAsyncIterator: Creates a new async iterator under the hood and returns a function which will call `next()` on it.
            ///     The returned function then produce the next body buffer asynchronously.
            ///     We use a closure as an abstraction instead of an existential to enable specialization.
            case asyncSequence(
                length: RequestBodyLength,
                makeAsyncIterator: @Sendable () -> ((ByteBufferAllocator) async throws -> ByteBuffer?)
            )
            /// - parameters:
            ///     - length: complete body length.
            ///     If `length` is `.known`, `nextBodyPart` is not allowed to produce more bytes than `length` defines.
            ///     - canBeConsumedMultipleTimes: if `makeBody` can be called multiple times and returns the same result.
            ///     - makeCompleteBody: function to produce the complete body.
            case sequence(
                length: RequestBodyLength,
                canBeConsumedMultipleTimes: Bool,
                makeCompleteBody: @Sendable (ByteBufferAllocator) -> ByteBuffer
            )
            case byteBuffer(ByteBuffer)
        }

        @usableFromInline
        internal var mode: Mode

        @inlinable
        internal init(_ mode: Mode) {
            self.mode = mode
        }
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension HTTPClientRequest.Body {
    /// Create an ``HTTPClientRequest/Body-swift.struct`` from a `ByteBuffer`.
    ///
    /// - parameter byteBuffer: The bytes of the body.
    public static func bytes(_ byteBuffer: ByteBuffer) -> Self {
        self.init(.byteBuffer(byteBuffer))
    }

    /// Create an ``HTTPClientRequest/Body-swift.struct`` from a `RandomAccessCollection` of bytes.
    ///
    /// This construction will flatten the `bytes` into a `ByteBuffer` in chunks of ~4MB.
    /// As a result, the peak memory usage of this construction will be a small multiple of ~4MB.
    /// The construction of the `ByteBuffer` will be delayed until it's needed.
    ///
    /// - parameter bytes: The bytes of the request body.
    @inlinable
    @preconcurrency
    public static func bytes<Bytes: RandomAccessCollection & Sendable>(
        _ bytes: Bytes
    ) -> Self where Bytes.Element == UInt8 {
        self.bytes(bytes, length: .known(Int64(bytes.count)))
    }

    /// Create an ``HTTPClientRequest/Body-swift.struct`` from a `Sequence` of bytes.
    ///
    /// This construction will flatten the bytes into a `ByteBuffer`. As a result, the peak memory
    /// usage of this construction will be double the size of the original collection. The construction
    /// of the `ByteBuffer` will be delayed until it's needed.
    ///
    /// Unlike ``bytes(_:)-1uns7``, this construction does not assume that the body can be replayed. As a result,
    /// if a redirect is encountered that would need us to replay the request body, the redirect will instead
    /// not be followed. Prefer ``bytes(_:)-1uns7`` wherever possible.
    ///
    /// Caution should be taken with this method to ensure that the `length` is correct. Incorrect lengths
    /// will cause unnecessary runtime failures. Setting `length` to ``Length/unknown`` will trigger the upload
    /// to use `chunked` `Transfer-Encoding`, while using ``Length/known(_:)-9q0ge`` will use `Content-Length`.
    ///
    /// - parameters:
    ///     - bytes: The bytes of the request body.
    ///     - length: The length of the request body.
    @inlinable
    @preconcurrency
    public static func bytes<Bytes: Sequence & Sendable>(
        _ bytes: Bytes,
        length: Length
    ) -> Self where Bytes.Element == UInt8 {
        Self._bytes(
            bytes,
            length: length,
            bagOfBytesToByteBufferConversionChunkSize: bagOfBytesToByteBufferConversionChunkSize,
            byteBufferMaxSize: byteBufferMaxSize
        )
    }

    /// internal method to test chunking
    @inlinable
    @preconcurrency
    static func _bytes<Bytes: Sequence & Sendable>(
        _ bytes: Bytes,
        length: Length,
        bagOfBytesToByteBufferConversionChunkSize: Int,
        byteBufferMaxSize: Int
    ) -> Self where Bytes.Element == UInt8 {
        // fast path
        let body: Self? = bytes.withContiguousStorageIfAvailable { bufferPointer -> Self in
            // `some Sequence<UInt8>` is special as it can't be efficiently chunked lazily.
            // Therefore we need to do the chunking eagerly if it implements the fast path withContiguousStorageIfAvailable
            // If we do it eagerly, it doesn't make sense to do a bunch of small chunks, so we only chunk if it exceeds
            // the maximum size of a ByteBuffer.
            if bufferPointer.count <= byteBufferMaxSize {
                let buffer = ByteBuffer(bytes: bufferPointer)
                return Self(
                    .sequence(
                        length: length.storage,
                        canBeConsumedMultipleTimes: true,
                        makeCompleteBody: { _ in buffer }
                    )
                )
            } else {
                // we need to copy `bufferPointer` eagerly as the pointer is only valid during the call to `withContiguousStorageIfAvailable`
                let buffers: [ByteBuffer] = bufferPointer.chunks(ofCount: byteBufferMaxSize).map {
                    ByteBuffer(bytes: $0)
                }
                return Self(
                    .asyncSequence(
                        length: length.storage,
                        makeAsyncIterator: {
                            var iterator = buffers.makeIterator()
                            return { _ in
                                iterator.next()
                            }
                        }
                    )
                )
            }
        }
        if let body = body {
            return body
        }

        // slow path
        return Self(
            .asyncSequence(
                length: length.storage
            ) {
                var iterator = bytes.makeIterator()
                return { allocator in
                    var buffer = allocator.buffer(capacity: bagOfBytesToByteBufferConversionChunkSize)
                    while buffer.writableBytes > 0, let byte = iterator.next() {
                        buffer.writeInteger(byte)
                    }
                    if buffer.readableBytes > 0 {
                        return buffer
                    }
                    return nil
                }
            }
        )
    }

    /// Create an ``HTTPClientRequest/Body-swift.struct`` from a `Collection` of bytes.
    ///
    /// This construction will flatten the `bytes` into a `ByteBuffer` in chunks of ~4MB.
    /// As a result, the peak memory usage of this construction will be a small multiple of ~4MB.
    /// The construction of the `ByteBuffer` will be delayed until it's needed.
    ///
    /// Caution should be taken with this method to ensure that the `length` is correct. Incorrect lengths
    /// will cause unnecessary runtime failures. Setting `length` to ``Length/unknown`` will trigger the upload
    /// to use `chunked` `Transfer-Encoding`, while using ``Length/known(_:)-9q0ge`` will use `Content-Length`.
    ///
    /// - parameters:
    ///     - bytes: The bytes of the request body.
    ///     - length: The length of the request body.
    @inlinable
    @preconcurrency
    public static func bytes<Bytes: Collection & Sendable>(
        _ bytes: Bytes,
        length: Length
    ) -> Self where Bytes.Element == UInt8 {
        if bytes.count <= bagOfBytesToByteBufferConversionChunkSize {
            return self.init(
                .sequence(
                    length: length.storage,
                    canBeConsumedMultipleTimes: true
                ) { allocator in
                    allocator.buffer(bytes: bytes)
                }
            )
        } else {
            return self.init(
                .asyncSequence(
                    length: length.storage,
                    makeAsyncIterator: {
                        var iterator = bytes.chunks(ofCount: bagOfBytesToByteBufferConversionChunkSize).makeIterator()
                        return { allocator in
                            guard let chunk = iterator.next() else {
                                return nil
                            }
                            return allocator.buffer(bytes: chunk)
                        }
                    }
                )
            )
        }
    }

    /// Create an ``HTTPClientRequest/Body-swift.struct`` from an `AsyncSequence` of `ByteBuffer`s.
    ///
    /// This construction will stream the upload one `ByteBuffer` at a time.
    ///
    /// Caution should be taken with this method to ensure that the `length` is correct. Incorrect lengths
    /// will cause unnecessary runtime failures. Setting `length` to ``Length/unknown`` will trigger the upload
    /// to use `chunked` `Transfer-Encoding`, while using ``Length/known(_:)-9q0ge`` will use `Content-Length`.
    ///
    /// - parameters:
    ///     - sequenceOfBytes: The bytes of the request body.
    ///     - length: The length of the request body.
    @inlinable
    @preconcurrency
    public static func stream<SequenceOfBytes: AsyncSequence & Sendable>(
        _ sequenceOfBytes: SequenceOfBytes,
        length: Length
    ) -> Self where SequenceOfBytes.Element == ByteBuffer {
        let body = self.init(
            .asyncSequence(length: length.storage) {
                var iterator = sequenceOfBytes.makeAsyncIterator()
                return { _ -> ByteBuffer? in
                    try await iterator.next()
                }
            }
        )
        return body
    }

    /// Create an ``HTTPClientRequest/Body-swift.struct`` from an `AsyncSequence` of bytes.
    ///
    /// This construction will consume 4MB chunks from the `Bytes` and send them at once. This optimizes for
    /// `AsyncSequence`s where larger chunks are buffered up and available without actually suspending, such
    /// as those provided by `FileHandle`.
    ///
    /// Caution should be taken with this method to ensure that the `length` is correct. Incorrect lengths
    /// will cause unnecessary runtime failures. Setting `length` to ``Length/unknown`` will trigger the upload
    /// to use `chunked` `Transfer-Encoding`, while using ``Length/known(_:)-9q0ge`` will use `Content-Length`.
    ///
    /// - parameters:
    ///     - bytes: The bytes of the request body.
    ///     - length: The length of the request body.
    @inlinable
    @preconcurrency
    public static func stream<Bytes: AsyncSequence & Sendable>(
        _ bytes: Bytes,
        length: Length
    ) -> Self where Bytes.Element == UInt8 {
        let body = self.init(
            .asyncSequence(length: length.storage) {
                var iterator = bytes.makeAsyncIterator()
                return { allocator -> ByteBuffer? in
                    var buffer = allocator.buffer(capacity: bagOfBytesToByteBufferConversionChunkSize)
                    while buffer.writableBytes > 0, let byte = try await iterator.next() {
                        buffer.writeInteger(byte)
                    }
                    if buffer.readableBytes > 0 {
                        return buffer
                    }
                    return nil
                }
            }
        )
        return body
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension Optional where Wrapped == HTTPClientRequest.Body {
    internal var canBeConsumedMultipleTimes: Bool {
        switch self?.mode {
        case .none: return true
        case .byteBuffer: return true
        case .sequence(_, let canBeConsumedMultipleTimes, _): return canBeConsumedMultipleTimes
        case .asyncSequence: return false
        }
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension HTTPClientRequest.Body {
    /// The length of a HTTP request body.
    public struct Length: Sendable {
        /// The size of the request body is not known before starting the request
        public static let unknown: Self = .init(storage: .unknown)

        /// The size of the request body is known and exactly `count` bytes
        @available(*, deprecated, message: "Use `known(_ count: Int64)` with an explicit Int64 argument instead")
        public static func known(_ count: Int) -> Self {
            .init(storage: .known(Int64(count)))
        }

        /// The size of the request body is known and exactly `count` bytes
        public static func known(_ count: Int64) -> Self {
            .init(storage: .known(count))
        }

        @usableFromInline
        internal var storage: RequestBodyLength
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension HTTPClientRequest.Body: AsyncSequence {
    public typealias Element = ByteBuffer

    @inlinable
    public func makeAsyncIterator() -> AsyncIterator {
        switch self.mode {
        case .asyncSequence(_, let makeAsyncIterator):
            return .init(storage: .makeNext(makeAsyncIterator()))
        case .sequence(_, _, let makeCompleteBody):
            return .init(storage: .byteBuffer(makeCompleteBody(AsyncIterator.allocator)))
        case .byteBuffer(let byteBuffer):
            return .init(storage: .byteBuffer(byteBuffer))
        }
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension HTTPClientRequest.Body {
    public struct AsyncIterator: AsyncIteratorProtocol {
        @usableFromInline
        static let allocator = ByteBufferAllocator()

        @usableFromInline
        enum Storage {
            case byteBuffer(ByteBuffer?)
            case makeNext((ByteBufferAllocator) async throws -> ByteBuffer?)
        }

        @usableFromInline
        var storage: Storage

        @inlinable
        init(storage: Storage) {
            self.storage = storage
        }

        @inlinable
        public mutating func next() async throws -> ByteBuffer? {
            switch self.storage {
            case .byteBuffer(let buffer):
                self.storage = .byteBuffer(nil)
                return buffer
            case .makeNext(let makeNext):
                return try await makeNext(Self.allocator)
            }
        }
    }
}

@available(*, unavailable)
extension HTTPClientRequest.Body.AsyncIterator: Sendable {}

@available(*, unavailable)
extension HTTPClientRequest.Body.AsyncIterator.Storage: Sendable {}
