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

import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix

import struct Foundation.URL

/// Handles a streaming download to a given file path, allowing headers and progress to be reported.
public final class FileDownloadDelegate: HTTPClientResponseDelegate {
    /// The response type for this delegate: the total count of bytes as reported by the response
    /// "Content-Length" header (if available), the count of bytes downloaded, the
    /// response head, and a history of requests and responses.
    public struct Progress: Sendable {
        public var totalBytes: Int?
        public var receivedBytes: Int

        /// The history of all requests and responses in redirect order.
        public var history: [HTTPClient.RequestResponse] = []

        /// The target URL (after redirects) of the response.
        public var url: URL? {
            self.history.last?.request.url
        }

        public var head: HTTPResponseHead {
            get {
                assert(self._head != nil)
                return self._head!
            }
            set {
                self._head = newValue
            }
        }

        fileprivate var _head: HTTPResponseHead? = nil

        internal init(totalBytes: Int? = nil, receivedBytes: Int) {
            self.totalBytes = totalBytes
            self.receivedBytes = receivedBytes
        }
    }

    private struct State {
        var progress = Progress(
            totalBytes: nil,
            receivedBytes: 0
        )
        var fileIOThreadPool: NIOThreadPool?
        var fileHandleFuture: EventLoopFuture<NIOFileHandle>?
        var writeFuture: EventLoopFuture<Void>?
    }
    private let state: NIOLockedValueBox<State>

    var _fileIOThreadPool: NIOThreadPool? {
        self.state.withLockedValue { $0.fileIOThreadPool }
    }

    public typealias Response = Progress

    private let filePath: String
    private let reportHead: (@Sendable (HTTPClient.Task<Progress>, HTTPResponseHead) -> Void)?
    private let reportProgress: (@Sendable (HTTPClient.Task<Progress>, Progress) -> Void)?

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
    @preconcurrency
    public init(
        path: String,
        pool: NIOThreadPool? = nil,
        reportHead: (@Sendable (HTTPClient.Task<Response>, HTTPResponseHead) -> Void)? = nil,
        reportProgress: (@Sendable (HTTPClient.Task<Response>, Progress) -> Void)? = nil
    ) throws {
        self.state = NIOLockedValueBox(State(fileIOThreadPool: pool))
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
    @preconcurrency
    public convenience init(
        path: String,
        pool: NIOThreadPool,
        reportHead: (@Sendable (HTTPResponseHead) -> Void)? = nil,
        reportProgress: (@Sendable (Progress) -> Void)? = nil
    ) throws {
        try self.init(
            path: path,
            pool: .some(pool),
            reportHead: reportHead.map { reportHead in
                { @Sendable _, head in
                    reportHead(head)
                }
            },
            reportProgress: reportProgress.map { reportProgress in
                { @Sendable _, head in
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
    @preconcurrency
    public convenience init(
        path: String,
        reportHead: (@Sendable (HTTPResponseHead) -> Void)? = nil,
        reportProgress: (@Sendable (Progress) -> Void)? = nil
    ) throws {
        try self.init(
            path: path,
            pool: nil,
            reportHead: reportHead.map { reportHead in
                { @Sendable _, head in
                    reportHead(head)
                }
            },
            reportProgress: reportProgress.map { reportProgress in
                { @Sendable _, head in
                    reportProgress(head)
                }
            }
        )
    }

    public func didVisitURL(task: HTTPClient.Task<Progress>, _ request: HTTPClient.Request, _ head: HTTPResponseHead) {
        self.state.withLockedValue {
            $0.progress.history.append(.init(request: request, responseHead: head))
        }
    }

    public func didReceiveHead(
        task: HTTPClient.Task<Response>,
        _ head: HTTPResponseHead
    ) -> EventLoopFuture<Void> {
        self.state.withLockedValue {
            $0.progress._head = head

            if let totalBytesString = head.headers.first(name: "Content-Length"),
                let totalBytes = Int(totalBytesString)
            {
                $0.progress.totalBytes = totalBytes
            }
        }

        self.reportHead?(task, head)

        return task.eventLoop.makeSucceededFuture(())
    }

    public func didReceiveBodyPart(
        task: HTTPClient.Task<Response>,
        _ buffer: ByteBuffer
    ) -> EventLoopFuture<Void> {
        let (progress, io) = self.state.withLockedValue { state in
            let threadPool: NIOThreadPool = {
                guard let pool = state.fileIOThreadPool else {
                    let pool = task.fileIOThreadPool
                    state.fileIOThreadPool = pool
                    return pool
                }
                return pool
            }()

            let io = NonBlockingFileIO(threadPool: threadPool)
            state.progress.receivedBytes += buffer.readableBytes
            return (state.progress, io)
        }
        self.reportProgress?(task, progress)

        let writeFuture = self.state.withLockedValue { state in
            let writeFuture: EventLoopFuture<Void>
            if let fileHandleFuture = state.fileHandleFuture {
                writeFuture = fileHandleFuture.flatMap {
                    io.write(fileHandle: $0, buffer: buffer, eventLoop: task.eventLoop)
                }
            } else {
                let fileHandleFuture = io.openFile(
                    _deprecatedPath: self.filePath,
                    mode: .write,
                    flags: .allowFileCreation(),
                    eventLoop: task.eventLoop
                )
                state.fileHandleFuture = fileHandleFuture
                writeFuture = fileHandleFuture.flatMap {
                    io.write(fileHandle: $0, buffer: buffer, eventLoop: task.eventLoop)
                }
            }

            state.writeFuture = writeFuture
            return writeFuture
        }

        return writeFuture
    }

    private func close(fileHandle: NIOFileHandle) {
        try! fileHandle.close()
        self.state.withLockedValue {
            $0.fileHandleFuture = nil
        }
    }

    private func finalize() {
        enum Finalize {
            case writeFuture(EventLoopFuture<Void>)
            case fileHandleFuture(EventLoopFuture<NIOFileHandle>)
            case none
        }

        let finalize: Finalize = self.state.withLockedValue { state in
            if let writeFuture = state.writeFuture {
                return .writeFuture(writeFuture)
            } else if let fileHandleFuture = state.fileHandleFuture {
                return .fileHandleFuture(fileHandleFuture)
            } else {
                return .none
            }
        }

        switch finalize {
        case .writeFuture(let future):
            future.whenComplete { _ in
                let fileHandleFuture = self.state.withLockedValue { state in
                    let future = state.fileHandleFuture
                    state.fileHandleFuture = nil
                    state.writeFuture = nil
                    return future
                }

                fileHandleFuture?.whenSuccess {
                    self.close(fileHandle: $0)
                }
            }
        case .fileHandleFuture(let future):
            future.whenSuccess { self.close(fileHandle: $0) }
        case .none:
            ()
        }
    }

    public func didReceiveError(task: HTTPClient.Task<Progress>, _ error: Error) {
        self.finalize()
    }

    public func didFinishRequest(task: HTTPClient.Task<Response>) throws -> Response {
        self.finalize()
        return self.state.withLockedValue { $0.progress }
    }
}
