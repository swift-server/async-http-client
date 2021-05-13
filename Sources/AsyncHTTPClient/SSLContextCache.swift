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

import Dispatch
import Logging
import NIO
import NIOConcurrencyHelpers
import NIOSSL

class SSLContextCache {
    private let lock = Lock()
    private var sslContextCache = LRUCache<BestEffortHashableTLSConfiguration, NIOSSLContext>()
    private let offloadQueue = DispatchQueue(label: "io.github.swift-server.AsyncHTTPClient.SSLContextCache")
}

extension SSLContextCache {
    func sslContext(tlsConfiguration: TLSConfiguration,
                    eventLoop: EventLoop,
                    logger: Logger) -> EventLoopFuture<NIOSSLContext> {
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
        let newSSLContext = self.offloadQueue.asyncWithFuture(eventLoop: eventLoop) {
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
