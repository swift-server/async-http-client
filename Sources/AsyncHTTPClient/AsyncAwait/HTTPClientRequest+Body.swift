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

@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
extension HTTPClientRequest {
    struct Body {
        internal enum Mode {
            case asyncSequence(length: Int?, (ByteBufferAllocator) async throws -> ByteBuffer?)
            case sequence(length: Int?, (ByteBufferAllocator) -> ByteBuffer)
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

    static func bytes<Bytes>(
        length: Int? = nil,
        _ bytes: Bytes
    ) -> Self where Bytes: Sequence, Bytes.Element == UInt8 {
        self.init(.sequence(length: length) { allocator in
            if let buffer = bytes.withContiguousStorageIfAvailable({ allocator.buffer(bytes: $0) }) {
                // fastpath
                return buffer
            }
            // potentially really slow path
            return allocator.buffer(bytes: bytes)
        })
    }

    static func bytes<Bytes>(
        _ bytes: Bytes
    ) -> Self where Bytes: RandomAccessCollection, Bytes.Element == UInt8 {
        self.init(.sequence(length: bytes.count) { allocator in
            if let buffer = bytes.withContiguousStorageIfAvailable({ allocator.buffer(bytes: $0) }) {
                // fastpath
                return buffer
            }
            // potentially really slow path
            return allocator.buffer(bytes: bytes)
        })
    }

    /// This method should never be used and was always deprecated.
    /// The whole purpose of this overload is to prevent users from providing a redundant length if `Bytes` conforms to
    /// `RandomAccessCollection` because it already provide a property `count` to get the length in O(**1**).
    /// - Note: `length` is ignored in favour of `bytes.count`
    @available(*, deprecated, message: "no need to manually specify `length` because we automatically use `bytes.count` as the `length`")
    static func bytes<Bytes>(
        length: Int,
        _ collection: Bytes
    ) -> Self where Bytes: RandomAccessCollection, Bytes.Element == UInt8 {
        return .bytes(collection)
    }

    static func stream<SequenceOfBytes>(
        length: Int? = nil,
        _ sequenceOfBytes: SequenceOfBytes
    ) -> Self where SequenceOfBytes: AsyncSequence, SequenceOfBytes.Element == ByteBuffer {
        var iterator = sequenceOfBytes.makeAsyncIterator()
        let body = self.init(.asyncSequence(length: length) { _ -> ByteBuffer? in
            try await iterator.next()
        })
        return body
    }

    static func stream<Bytes>(
        length: Int? = nil,
        _ bytes: Bytes
    ) -> Self where Bytes: AsyncSequence, Bytes.Element == UInt8 {
        var iterator = bytes.makeAsyncIterator()
        let body = self.init(.asyncSequence(length: nil) { allocator -> ByteBuffer? in
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

#endif
