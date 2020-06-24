//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2020 AsyncHTTPClient project authors
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

public final class FileDownloadDelegate: HTTPClientResponseDelegate {
  public typealias Response = (totalBytes: Int?, receivedBytes: Int)

  private var totalBytes: Int?
  private var receivedBytes = 0

  private let handle: NIOFileHandle
  private let io: NonBlockingFileIO
  private let reportHeaders: ((HTTPHeaders) -> ())?
  private let reportProgress: ((_ totalBytes: Int?, _ receivedBytes: Int) -> ())?

  private var writeFuture: EventLoopFuture<()>?

  public init(
    path: String,
    pool: NIOThreadPool = NIOThreadPool(numberOfThreads: 1),
    reportHeaders: ((HTTPHeaders) -> ())? = nil,
    reportProgress: ((_ totalBytes: Int?, _ receivedBytes: Int) -> ())? = nil
  ) throws {
    handle = try NIOFileHandle(path: path, mode: .write, flags: .allowFileCreation())
    pool.start()
    io = NonBlockingFileIO(threadPool: pool)

    self.reportHeaders = reportHeaders
    self.reportProgress = reportProgress
  }

  public func didReceiveHead(
    task: HTTPClient.Task<Response>,
    _ head: HTTPResponseHead
  ) -> EventLoopFuture<()> {
    reportHeaders?(head.headers)

    if let totalBytesString = head.headers.first(name: "Content-Length"),
      let totalBytes = Int(totalBytesString) {
      self.totalBytes = totalBytes
    }

    return task.eventLoop.makeSucceededFuture(())
  }

  public func didReceiveBodyPart(
    task: HTTPClient.Task<Response>,
    _ buffer: ByteBuffer
  ) -> EventLoopFuture<()> {
    receivedBytes += buffer.readableBytes
    reportProgress?(totalBytes, receivedBytes)

    let writeFuture = io.write(fileHandle: handle, buffer: buffer, eventLoop: task.eventLoop)
    self.writeFuture = writeFuture
    return writeFuture
  }

  public func didFinishRequest(task: HTTPClient.Task<Response>) throws -> Response {
    writeFuture?.whenComplete { [weak self] _ in
      try! self?.handle.close()
      self?.writeFuture = nil
    }
    return (totalBytes, receivedBytes)
  }
}
