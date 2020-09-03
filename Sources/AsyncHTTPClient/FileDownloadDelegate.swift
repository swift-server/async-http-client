//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2020 Apple Inc. and the AsyncHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO
import NIOHTTP1

/// Handles a streaming download to a given file path, allowing headers and progress to be reported.
public final class FileDownloadDelegate: HTTPClientResponseDelegate {
    /// The response type for this delegate: the total count of bytes as reported by the response
    /// "Content-Length" header (if available) and the count of bytes downloaded.
    public typealias Response = (totalBytes: Int?, receivedBytes: Int)

    private var totalBytes: Int?
    private var receivedBytes = 0

    private let handle: NIOFileHandle
    private let io: NonBlockingFileIO
    private let reportHeaders: ((HTTPHeaders) -> Void)?
    private let reportProgress: ((_ totalBytes: Int?, _ receivedBytes: Int) -> Void)?

    private var writeFuture: EventLoopFuture<Void>?

    /// Initializes a new file download delegate.
    /// - parameters:
    ///     - path: Path to a file you'd like to write the download to.
    ///     - pool: A thread pool to use for asynchronous file I/O.
    ///     - reportHeaders: A closure called when the response headers are available.
    ///     - reportProgress: A closure called when a body chunk has been downloaded, with
    ///       the total byte count and download byte count passed to it as arguments. The callbacks 
    ///       will be invoked in the same threading context that the delegate itself is invoked, 
    ///       as controlled by `EventLoopPreference`.
    public init(
        path: String,
        pool: NIOThreadPool = NIOThreadPool(numberOfThreads: 1),
        reportHeaders: ((HTTPHeaders) -> Void)? = nil,
        reportProgress: ((_ totalBytes: Int?, _ receivedBytes: Int) -> Void)? = nil
    ) throws {
        self.handle = try NIOFileHandle(path: path, mode: .write, flags: .allowFileCreation())
        pool.start()
        self.io = NonBlockingFileIO(threadPool: pool)

        self.reportHeaders = reportHeaders
        self.reportProgress = reportProgress
    }

    public func didReceiveHead(
        task: HTTPClient.Task<Response>,
        _ head: HTTPResponseHead
    ) -> EventLoopFuture<Void> {
        self.reportHeaders?(head.headers)

        if let totalBytesString = head.headers.first(name: "Content-Length"),
            let totalBytes = Int(totalBytesString) {
            self.totalBytes = totalBytes
        }

        return task.eventLoop.makeSucceededFuture(())
    }

    public func didReceiveBodyPart(
        task: HTTPClient.Task<Response>,
        _ buffer: ByteBuffer
    ) -> EventLoopFuture<Void> {
        self.receivedBytes += buffer.readableBytes
        self.reportProgress?(self.totalBytes, self.receivedBytes)

        let writeFuture = self.io.write(fileHandle: self.handle, buffer: buffer, eventLoop: task.eventLoop)
        self.writeFuture = writeFuture
        return writeFuture
    }

    public func didFinishRequest(task: HTTPClient.Task<Response>) throws -> Response {
        self.writeFuture?.whenComplete { _ in
            try! self.handle.close()
            self.writeFuture = nil
        }
        return (self.totalBytes, self.receivedBytes)
    }
}
