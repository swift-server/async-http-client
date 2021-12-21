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

#if compiler(>=5.5.2) && canImport(_Concurrency)
import NIOCore
import NIOHTTP1

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
public struct HTTPClientRequest {
    public var url: String
    public var method: HTTPMethod
    public var headers: HTTPHeaders

    public var body: Body?

    public init(url: String) {
        self.url = url
        self.method = .GET
        self.headers = .init()
        self.body = .none
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension HTTPClientRequest {
    public struct Body {
        @usableFromInline
        internal enum Mode {
            case asyncSequence(length: RequestBodyLength, (ByteBufferAllocator) async throws -> ByteBuffer?)
            case sequence(length: RequestBodyLength, canBeConsumedMultipleTimes: Bool, (ByteBufferAllocator) -> ByteBuffer)
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
    public static func bytes(_ byteBuffer: ByteBuffer) -> Self {
        self.init(.byteBuffer(byteBuffer))
    }

    @inlinable
    public static func bytes<Bytes: RandomAccessCollection>(
        _ bytes: Bytes
    ) -> Self where Bytes.Element == UInt8 {
        self.init(.sequence(
            length: .known(bytes.count),
            canBeConsumedMultipleTimes: true
        ) { allocator in
            if let buffer = bytes.withContiguousStorageIfAvailable({ allocator.buffer(bytes: $0) }) {
                // fastpath
                return buffer
            }
            // potentially really slow path
            return allocator.buffer(bytes: bytes)
        })
    }

    @inlinable
    public static func bytes<Bytes: Sequence>(
        _ bytes: Bytes,
        length: Length
    ) -> Self where Bytes.Element == UInt8 {
        self.init(.sequence(
            length: length.storage,
            canBeConsumedMultipleTimes: false
        ) { allocator in
            if let buffer = bytes.withContiguousStorageIfAvailable({ allocator.buffer(bytes: $0) }) {
                // fastpath
                return buffer
            }
            // potentially really slow path
            return allocator.buffer(bytes: bytes)
        })
    }

    @inlinable
    public static func bytes<Bytes: Collection>(
        _ bytes: Bytes,
        length: Length
    ) -> Self where Bytes.Element == UInt8 {
        self.init(.sequence(
            length: length.storage,
            canBeConsumedMultipleTimes: true
        ) { allocator in
            if let buffer = bytes.withContiguousStorageIfAvailable({ allocator.buffer(bytes: $0) }) {
                // fastpath
                return buffer
            }
            // potentially really slow path
            return allocator.buffer(bytes: bytes)
        })
    }

    @inlinable
    public static func stream<SequenceOfBytes: AsyncSequence>(
        _ sequenceOfBytes: SequenceOfBytes,
        length: Length
    ) -> Self where SequenceOfBytes.Element == ByteBuffer {
        var iterator = sequenceOfBytes.makeAsyncIterator()
        let body = self.init(.asyncSequence(length: length.storage) { _ -> ByteBuffer? in
            try await iterator.next()
        })
        return body
    }

    @inlinable
    public static func stream<Bytes: AsyncSequence>(
        _ bytes: Bytes,
        length: Length
    ) -> Self where Bytes.Element == UInt8 {
        var iterator = bytes.makeAsyncIterator()
        let body = self.init(.asyncSequence(length: length.storage) { allocator -> ByteBuffer? in
            var buffer = allocator.buffer(capacity: 1024) // TODO: Magic number
            while buffer.writableBytes > 0, let byte = try await iterator.next() {
                buffer.writeInteger(byte)
            }
            if buffer.readableBytes > 0 {
                return buffer
            }
            return nil
        })
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
    public struct Length {
        /// size of the request body is not known before starting the request
        public static let unknown: Self = .init(storage: .unknown)
        /// size of the request body is fixed and exactly `count` bytes
        public static func known(_ count: Int) -> Self {
            .init(storage: .known(count))
        }

        @usableFromInline
        internal var storage: RequestBodyLength
    }
}

#endif
