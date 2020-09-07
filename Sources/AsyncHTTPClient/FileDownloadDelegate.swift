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
    public struct Progress {
        public var totalBytes: Int?
        public var receivedBytes: Int
    }

    private var progress = Progress(totalBytes: nil, receivedBytes: 0)

    public typealias Response = Progress

    private let filePath: String
    private let io: NonBlockingFileIO
    private let reportHeaders: ((HTTPHeaders) -> Void)?
    private let reportProgress: ((Progress) -> Void)?

    private var fileHandleFuture: EventLoopFuture<NIOFileHandle>?
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
        reportProgress: ((Progress) -> Void)? = nil
    ) throws {
        pool.start()
        self.io = NonBlockingFileIO(threadPool: pool)
        self.filePath = path

        self.reportHeaders = reportHeaders
        self.reportProgress = reportProgress
    }

    private func write(
        buffer: ByteBuffer,
        to fileHandle: NIOFileHandle,
        eventLoop: EventLoop
    ) -> EventLoopFuture<Void> {
        self.io.write(fileHandle: fileHandle, buffer: buffer, eventLoop: eventLoop)
    }

    public func didReceiveHead(
        task: HTTPClient.Task<Response>,
        _ head: HTTPResponseHead
    ) -> EventLoopFuture<Void> {
        self.reportHeaders?(head.headers)

        if let totalBytesString = head.headers.first(name: "Content-Length"),
            let totalBytes = Int(totalBytesString) {
            self.progress.totalBytes = totalBytes
        }

        return task.eventLoop.makeSucceededFuture(())
    }

    public func didReceiveBodyPart(
        task: HTTPClient.Task<Response>,
        _ buffer: ByteBuffer
    ) -> EventLoopFuture<Void> {
        self.progress.receivedBytes += buffer.readableBytes
        self.reportProgress?(self.progress)

        let writeFuture: EventLoopFuture<Void>
        if let fileHandleFuture = self.fileHandleFuture {
            writeFuture = fileHandleFuture.flatMap {
                self.write(buffer: buffer, to: $0, eventLoop: task.eventLoop)
            }
        } else {
            let fileHandleFuture = self.io.openFile(
                path: self.filePath,
                mode: .write,
                flags: .allowFileCreation(),
                eventLoop: task.eventLoop
            )
            self.fileHandleFuture = fileHandleFuture
            writeFuture = fileHandleFuture.flatMap {
                self.write(buffer: buffer, to: $0, eventLoop: task.eventLoop)
            }
        }

        self.writeFuture = writeFuture
        return writeFuture
    }

    private func close(fileHandle: NIOFileHandle) {
        try! fileHandle.close()
        self.fileHandleFuture = nil
    }

    public func didFinishRequest(task: HTTPClient.Task<Response>) throws -> Response {
        if let writeFuture = self.writeFuture {
            writeFuture.whenComplete { _ in
                self.fileHandleFuture?.whenSuccess(self.close(fileHandle:))
                self.writeFuture = nil
            }
        } else {
            self.fileHandleFuture?.whenSuccess(self.close(fileHandle:))
        }
        return self.progress
    }
}
