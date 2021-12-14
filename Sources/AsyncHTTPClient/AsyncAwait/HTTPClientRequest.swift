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

#if compiler(>=5.5) && canImport(_Concurrency)
import NIOCore
import NIOHTTP1

@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
struct HTTPClientRequest {
    var url: String
    var method: HTTPMethod
    var headers: HTTPHeaders

    var body: Body?

    init(url: String) {
        self.url = url
        self.method = .GET
        self.headers = .init()
        self.body = .none
    }
}

@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
extension HTTPClientRequest {
    struct Body {
        internal enum Mode {
            case asyncSequence(length: Int?, (ByteBufferAllocator) async throws -> ByteBuffer?)
            case sequence(length: Int?, canBeConsumedMultipleTimes: Bool, (ByteBufferAllocator) -> ByteBuffer)
            case byteBuffer(ByteBuffer)
        }

        var mode: Mode

        private init(_ mode: Mode) {
            self.mode = mode
        }
    }
}

@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
extension HTTPClientRequest.Body {
    static func byteBuffer(_ byteBuffer: ByteBuffer) -> Self {
        self.init(.byteBuffer(byteBuffer))
    }

    @inlinable
    static func bytes<Bytes: Sequence>(
        length: Int?,
        _ bytes: Bytes
    ) -> Self where Bytes.Element == UInt8 {
        self.init(.sequence(length: length, canBeConsumedMultipleTimes: false) { allocator in
            if let buffer = bytes.withContiguousStorageIfAvailable({ allocator.buffer(bytes: $0) }) {
                // fastpath
                return buffer
            }
            // potentially really slow path
            return allocator.buffer(bytes: bytes)
        })
    }

    @inlinable
    static func bytes<Bytes: Collection>(
        length: Int?,
        _ bytes: Bytes
    ) -> Self where Bytes.Element == UInt8 {
        self.init(.sequence(length: length, canBeConsumedMultipleTimes: true) { allocator in
            if let buffer = bytes.withContiguousStorageIfAvailable({ allocator.buffer(bytes: $0) }) {
                // fastpath
                return buffer
            }
            // potentially really slow path
            return allocator.buffer(bytes: bytes)
        })
    }

    @inlinable
    static func bytes<Bytes: RandomAccessCollection>(
        _ bytes: Bytes
    ) -> Self where Bytes.Element == UInt8 {
        self.init(.sequence(length: bytes.count, canBeConsumedMultipleTimes: true) { allocator in
            if let buffer = bytes.withContiguousStorageIfAvailable({ allocator.buffer(bytes: $0) }) {
                // fastpath
                return buffer
            }
            // potentially really slow path
            return allocator.buffer(bytes: bytes)
        })
    }

    @inlinable
    static func stream<SequenceOfBytes: AsyncSequence>(
        length: Int?,
        _ sequenceOfBytes: SequenceOfBytes
    ) -> Self where SequenceOfBytes.Element == ByteBuffer {
        var iterator = sequenceOfBytes.makeAsyncIterator()
        let body = self.init(.asyncSequence(length: length) { _ -> ByteBuffer? in
            try await iterator.next()
        })
        return body
    }

    @inlinable
    static func stream<Bytes: AsyncSequence>(
        length: Int?,
        _ bytes: Bytes
    ) -> Self where Bytes.Element == UInt8 {
        var iterator = bytes.makeAsyncIterator()
        let body = self.init(.asyncSequence(length: length) { allocator -> ByteBuffer? in
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

@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
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

#endif
