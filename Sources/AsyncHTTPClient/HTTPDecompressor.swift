//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2018-2019 Swift Server Working Group and the AsyncHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import CNIOExtrasZlib
import NIO
import NIOHTTP1

private enum CompressionAlgorithm: String {
    case gzip
    case deflate
}

extension z_stream {
    mutating func inflatePart(input: inout ByteBuffer, allocator: ByteBufferAllocator, consumer: (ByteBuffer) -> Void) {
        input.readWithUnsafeMutableReadableBytes { dataPtr in
            let typedPtr = dataPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
            let typedDataPtr = UnsafeMutableBufferPointer(start: typedPtr, count: dataPtr.count)

            self.avail_in = UInt32(typedDataPtr.count)
            self.next_in = typedDataPtr.baseAddress!

            defer {
                self.avail_in = 0
                self.next_in = nil
                self.avail_out = 0
                self.next_out = nil
            }

            repeat {
                var buffer = allocator.buffer(capacity: 16384)
                self.inflatePart(to: &buffer)
                consumer(buffer)
            } while self.avail_out == 0

            return Int(self.avail_in)
        }
    }

    private mutating func inflatePart(to buffer: inout ByteBuffer) {
        buffer.writeWithUnsafeMutableBytes { outputPtr in
            let typedOutputPtr = UnsafeMutableBufferPointer(start: outputPtr.baseAddress!.assumingMemoryBound(to: UInt8.self), count: outputPtr.count)

            self.avail_out = UInt32(typedOutputPtr.count)
            self.next_out = typedOutputPtr.baseAddress!

            let rc = inflate(&self, Z_NO_FLUSH)
            precondition(rc == Z_OK || rc == Z_STREAM_END, "decompression failed: \(rc)")

            return typedOutputPtr.count - Int(self.avail_out)
        }
    }
}

final class HTTPResponseDecompressor: ChannelDuplexHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPClientResponsePart
    typealias InboundOut = HTTPClientResponsePart
    typealias OutboundIn = HTTPClientRequestPart
    typealias OutboundOut = HTTPClientRequestPart

    private enum State {
        case empty
        case compressed(CompressionAlgorithm, Int)
    }

    private let limit: HTTPClient.DecompressionLimit
    private var state = State.empty
    private var stream = z_stream()
    private var inflated = 0

    init(limit: HTTPClient.DecompressionLimit) {
        self.limit = limit
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let request = self.unwrapOutboundIn(data)
        switch request {
        case .head(var head):
            if head.headers.contains(name: "Accept-Encoding") {
                context.write(data, promise: promise)
            } else {
                head.headers.replaceOrAdd(name: "Accept-Encoding", value: "deflate, gzip")
                context.write(self.wrapOutboundOut(.head(head)), promise: promise)
            }
        default:
            context.write(data, promise: promise)
        }
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch self.unwrapInboundIn(data) {
        case .head(let head):
            let algorithm: CompressionAlgorithm?
            let contentType = head.headers[canonicalForm: "Content-Encoding"].first?.lowercased()
            if contentType == "gzip" {
                algorithm = .gzip
            } else if contentType == "deflate" {
                algorithm = .deflate
            } else {
                algorithm = nil
            }

            let length = head.headers[canonicalForm: "Content-Length"].first.flatMap { Int($0) }

            if let algorithm = algorithm, let length = length {
                self.initializeDecoder(encoding: algorithm, length: length)
            }

            context.fireChannelRead(data)
        case .body(var part):
            switch self.state {
            case .compressed(_, let originalLength):
                self.stream.inflatePart(input: &part, allocator: context.channel.allocator) { output in
                    self.inflated += output.readableBytes
                    if self.limit.exceeded(compressed: originalLength, decompressed: self.inflated) {
                        context.fireErrorCaught(HTTPClientError.decompressionLimit)
                        return
                    }
                    context.fireChannelRead(self.wrapInboundOut(.body(output)))
                }
            default:
                context.fireChannelRead(data)
            }
        case .end:
            deflateEnd(&self.stream)
            context.fireChannelRead(data)
        }
    }

    private func initializeDecoder(encoding: CompressionAlgorithm, length: Int) {
        self.state = .compressed(encoding, length)

        self.stream.zalloc = nil
        self.stream.zfree = nil
        self.stream.opaque = nil

        let window: Int32
        switch encoding {
        case .gzip:
            window = 15 + 16
        default:
            window = 15
        }

        let rc = CNIOExtrasZlib_inflateInit2(&self.stream, window)
        precondition(rc == Z_OK, "Unexpected return from zlib init: \(rc)")
    }
}
