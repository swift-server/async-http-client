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

import Logging
import NIO
import NIOConcurrencyHelpers
import NIOSSL

class SSLContextCache {
    private var state = State.activeNoThread
    private let lock = Lock()
    private var sslContextCache = LRUCache<BestEffortHashableTLSConfiguration, NIOSSLContext>()
    private let threadPool = NIOThreadPool(numberOfThreads: 1)

    enum State {
        case activeNoThread
        case active
        case shutDown
    }

    init() {}

    func shutdown() {
        self.lock.withLock { () -> Void in
            switch self.state {
            case .activeNoThread:
                self.state = .shutDown
            case .active:
                self.state = .shutDown
                self.threadPool.shutdownGracefully { maybeError in
                    precondition(maybeError == nil, "\(maybeError!)")
                }
            case .shutDown:
                preconditionFailure("SSLContextCache shut down twice")
            }
        }
    }

    deinit {
        assert(self.state == .shutDown)
    }
}

extension SSLContextCache {
    private struct SSLContextCacheShutdownError: Error {}

    func sslContext(tlsConfiguration: TLSConfiguration,
                    eventLoop: EventLoop,
                    logger: Logger) -> EventLoopFuture<NIOSSLContext> {
        let earlyExitError: Error? = self.lock.withLock { () -> Error? in
            switch self.state {
            case .activeNoThread:
                self.state = .active
                self.threadPool.start()
                return nil
            case .active:
                return nil
            case .shutDown:
                return SSLContextCacheShutdownError()
            }
        }

        if let error = earlyExitError {
            return eventLoop.makeFailedFuture(error)
        }

        let eqTLSConfiguration = BestEffortHashableTLSConfiguration(wrapping: tlsConfiguration)
        let sslContext = self.lock.withLock {
            self.sslContextCache.find(key: eqTLSConfiguration)
        }

        if let sslContext = sslContext {
            logger.debug("found SSL context in cache",
                         metadata: ["ahc-tls-config": "\(tlsConfiguration)"])
            return eventLoop.makeSucceededFuture(sslContext)
        }

        logger.debug("creating new SSL context",
                     metadata: ["ahc-tls-config": "\(tlsConfiguration)"])
        let newSSLContext = self.threadPool.runIfActive(eventLoop: eventLoop) {
            try NIOSSLContext(configuration: tlsConfiguration)
        }

        newSSLContext.whenSuccess { (newSSLContext: NIOSSLContext) -> Void in
            self.lock.withLock { () -> Void in
                self.sslContextCache.append(key: eqTLSConfiguration,
                                            value: newSSLContext)
            }
        }

        return newSSLContext
    }
}
