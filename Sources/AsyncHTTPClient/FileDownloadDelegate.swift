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

import NIOCore
import NIOHTTP1
import NIOPosix

/// Handles a streaming download to a given file path, allowing headers and progress to be reported.
public final class FileDownloadDelegate: HTTPClientResponseDelegate {
    /// The response type for this delegate: the total count of bytes as reported by the response
    /// "Content-Length" header (if available) and the count of bytes downloaded.
    public struct Progress: Sendable {
        public var totalBytes: Int?
        public var receivedBytes: Int
    }

    private var progress = Progress(totalBytes: nil, receivedBytes: 0)

    public typealias Response = Progress

    private let filePath: String
    private(set) var fileIOThreadPool: NIOThreadPool?
    private let reportHead: ((HTTPClient.Task<Progress>, HTTPResponseHead) -> Void)?
    private let reportProgress: ((HTTPClient.Task<Progress>, Progress) -> Void)?

    private var fileHandleFuture: EventLoopFuture<NIOFileHandle>?
    private var writeFuture: EventLoopFuture<Void>?

    /// Initializes a new file download delegate.
    ///
    /// - parameters:
    ///     - path: Path to a file you'd like to write the download to.
    ///     - pool: A thread pool to use for asynchronous file I/O. If nil, a shared thread pool will be used.  Defaults to nil.
    ///     - reportHead: A closure called when the response head is available.
    ///     - reportProgress: A closure called when a body chunk has been downloaded, with
    ///       the total byte count and download byte count passed to it as arguments. The callbacks
    ///       will be invoked in the same threading context that the delegate itself is invoked,
    ///       as controlled by `EventLoopPreference`.
    public init(
        path: String,
        pool: NIOThreadPool? = nil,
        reportHead: ((HTTPClient.Task<Response>, HTTPResponseHead) -> Void)? = nil,
        reportProgress: ((HTTPClient.Task<Response>, Progress) -> Void)? = nil
    ) throws {
        if let pool = pool {
            self.fileIOThreadPool = pool
        } else {
            // we should use the shared thread pool from the HTTPClient which
            // we will get from the `HTTPClient.Task`
            self.fileIOThreadPool = nil
        }

        self.filePath = path

        self.reportHead = reportHead
        self.reportProgress = reportProgress
    }

    /// Initializes a new file download delegate.
    ///
    /// - parameters:
    ///     - path: Path to a file you'd like to write the download to.
    ///     - pool: A thread pool to use for asynchronous file I/O.
    ///     - reportHead: A closure called when the response head is available.
    ///     - reportProgress: A closure called when a body chunk has been downloaded, with
    ///       the total byte count and download byte count passed to it as arguments. The callbacks
    ///       will be invoked in the same threading context that the delegate itself is invoked,
    ///       as controlled by `EventLoopPreference`.
    public convenience init(
        path: String,
        pool: NIOThreadPool,
        reportHead: ((HTTPResponseHead) -> Void)? = nil,
        reportProgress: ((Progress) -> Void)? = nil
    ) throws {
        try self.init(
            path: path,
            pool: .some(pool),
            reportHead: reportHead.map { reportHead in
                return { _, head in
                    reportHead(head)
                }
            },
            reportProgress: reportProgress.map { reportProgress in
                return { _, head in
                    reportProgress(head)
                }
            }
        )
    }

    /// Initializes a new file download delegate and uses the shared thread pool of the ``HTTPClient`` for file I/O.
    ///
    /// - parameters:
    ///     - path: Path to a file you'd like to write the download to.
    ///     - reportHead: A closure called when the response head is available.
    ///     - reportProgress: A closure called when a body chunk has been downloaded, with
    ///       the total byte count and download byte count passed to it as arguments. The callbacks
    ///       will be invoked in the same threading context that the delegate itself is invoked,
    ///       as controlled by `EventLoopPreference`.
    public convenience init(
        path: String,
        reportHead: ((HTTPResponseHead) -> Void)? = nil,
        reportProgress: ((Progress) -> Void)? = nil
    ) throws {
        try self.init(
            path: path,
            pool: nil,
            reportHead: reportHead.map { reportHead in
                return { _, head in
                    reportHead(head)
                }
            },
            reportProgress: reportProgress.map { reportProgress in
                return { _, head in
                    reportProgress(head)
                }
            }
        )
    }

    public func didReceiveHead(
        task: HTTPClient.Task<Response>,
        _ head: HTTPResponseHead
    ) -> EventLoopFuture<Void> {
        self.reportHead?(task, head)

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
        let threadPool: NIOThreadPool = {
            guard let pool = self.fileIOThreadPool else {
                let pool = task.fileIOThreadPool
                self.fileIOThreadPool = pool
                return pool
            }
            return pool
        }()
        let io = NonBlockingFileIO(threadPool: threadPool)
        self.progress.receivedBytes += buffer.readableBytes
        self.reportProgress?(task, self.progress)

        let writeFuture: EventLoopFuture<Void>
        if let fileHandleFuture = self.fileHandleFuture {
            writeFuture = fileHandleFuture.flatMap {
                io.write(fileHandle: $0, buffer: buffer, eventLoop: task.eventLoop)
            }
        } else {
            let fileHandleFuture = io.openFile(
                path: self.filePath,
                mode: .write,
                flags: .allowFileCreation(),
                eventLoop: task.eventLoop
            )
            self.fileHandleFuture = fileHandleFuture
            writeFuture = fileHandleFuture.flatMap {
                io.write(fileHandle: $0, buffer: buffer, eventLoop: task.eventLoop)
            }
        }

        self.writeFuture = writeFuture
        return writeFuture
    }

    private func close(fileHandle: NIOFileHandle) {
        try! fileHandle.close()
        self.fileHandleFuture = nil
    }

    private func finalize() {
        if let writeFuture = self.writeFuture {
            writeFuture.whenComplete { _ in
                self.fileHandleFuture?.whenSuccess(self.close(fileHandle:))
                self.writeFuture = nil
            }
        } else {
            self.fileHandleFuture?.whenSuccess(self.close(fileHandle:))
        }
    }

    public func didReceiveError(task: HTTPClient.Task<Progress>, _ error: Error) {
        self.finalize()
    }

    public func didFinishRequest(task: HTTPClient.Task<Response>) throws -> Response {
        self.finalize()
        return self.progress
    }
}
