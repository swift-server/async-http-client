//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIOHTTPClient open source project
//
// Copyright (c) 2018-2019 Swift Server Working Group and the SwiftNIOHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIOHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO
import NIOHTTP1

public extension HTTPClient {

    func download(url: String, to path: String) -> EventLoopFuture<Void> {
        do {
            let request = try Request(url: url, method: .GET)
            return self.download(request: request, to: path)
        } catch {
            return self.group.next().makeFailedFuture(error)
        }
    }

    func download(request: Request, to path: String) -> EventLoopFuture<Void> {
        let eventLoop = self.group.next()
        let pool = NIOThreadPool(numberOfThreads: 1)
        let io = NonBlockingFileIO(threadPool: pool)

        pool.start()

        let file: EventLoopFuture<NIOFileHandle> = pool.runIfActive(eventLoop: eventLoop) {
            let fd = open(path, O_WRONLY | O_CREAT, S_IWUSR | S_IRUSR | S_IRGRP | S_IROTH)
            return NIOFileHandle(descriptor: fd)
        }

        return file.flatMap { handle in
            let delegate = DownloadFileDelegate(io: io, eventLoop: eventLoop, handle: handle)
            let response = self.execute(request: request, delegate: delegate).future.flatMap { future in
                future
            }

            response.whenComplete { _ in
                try? handle.close()
                try? pool.syncShutdownGracefully()
            }

            return response
        }
    }

}

class DownloadFileDelegate: HTTPClientResponseDelegate {
    typealias Response = EventLoopFuture<Void>

    let io: NonBlockingFileIO
    let eventLoop: EventLoop
    let handle: NIOFileHandle

    enum State {
        case idle
        case writing(EventLoopFuture<Void>)
        case error(Error)
    }

    var state: State = .idle

    init(io: NonBlockingFileIO, eventLoop: EventLoop, handle: NIOFileHandle) {
        self.io = io
        self.eventLoop = eventLoop
        self.handle = handle
    }

    func didReceiveHead(task: HTTPClient.Task<EventLoopFuture<Void>>, _ head: HTTPResponseHead) {
        if head.status != .ok {
            self.state = .error(HTTPClientError.non200Reponse)
        }
    }

    func didReceivePart(task: HTTPClient.Task<EventLoopFuture<Void>>, _ part: ByteBuffer) {
        switch self.state {
        case .error:
            return
        default:
            let writeFuture = io.write(fileHandle: self.handle, buffer: part, eventLoop: self.eventLoop)
            writeFuture.whenFailure { error in
                self.state = .error(error)
            }
            self.state = .writing(writeFuture)
        }
    }

    func didReceiveError(task: HTTPClient.Task<EventLoopFuture<Void>>, error: Error) {
        self.state = .error(error)
    }

    func didFinishRequest(task: HTTPClient.Task<EventLoopFuture<Void>>) throws -> EventLoopFuture<Void> {
        switch state {
        case .idle:
            throw HTTPClientError.emptyBody
        case .writing(let future):
            return future
        case .error(let error):
            throw error
        }
    }

}
