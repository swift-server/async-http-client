//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2025 Apple Inc. and the AsyncHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore
import NIOHTTP1
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
internal import NIOFoundationCompat

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension HTTPClientResponse {
    /// Response body as `ByteBuffer`.
    /// - Parameter maxBytes: The maximum number of bytes this method is allowed to accumulate.
    /// - Returns: Bytes collected over time
    public func bytes(upTo maxBytes: Int) async throws -> ByteBuffer {
        let expectedBytes = self.headers.first(name: "content-length").flatMap(Int.init) ?? maxBytes
        return try await self.body.collect(upTo: min(expectedBytes, maxBytes))
    }
}


@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension HTTPClientResponse {
    /// Response body as `Data`.
    /// - Parameter maxBytes: The maximum number of bytes this method is allowed to accumulate.
    /// - Returns: Bytes collected over time
    public func data(upTo maxBytes: Int) async throws -> Data? {
        var bytes = try await self.bytes(upTo: maxBytes)
        return bytes.readData(length: bytes.readableBytes)
    }
}
