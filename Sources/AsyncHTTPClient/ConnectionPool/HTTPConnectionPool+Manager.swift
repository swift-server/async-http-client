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
import NIOHTTP1

extension HTTPConnectionPool {
    final class Manager {
        private typealias Key = ConnectionPool.Key

        enum State {
            case active
            case shuttingDown(promise: EventLoopPromise<Bool>, unclean: Bool)
            case shutDown
        }

        let eventLoopGroup: EventLoopGroup
        let configuration: HTTPClient.Configuration
        let connectionIDGenerator = Connection.ID.globalGenerator
        let logger: Logger

        private var state: State = .active
        private var _pools: [Key: HTTPConnectionPool] = [:]
        private let lock = Lock()

        private let sslContextCache = SSLContextCache()

        init(eventLoopGroup: EventLoopGroup,
             configuration: HTTPClient.Configuration,
             backgroundActivityLogger logger: Logger) {
            self.eventLoopGroup = eventLoopGroup
            self.configuration = configuration
            self.logger = logger
        }

        deinit {
            guard case .shutDown = self.state else {
                preconditionFailure("Manager must be shutdown before deinit")
            }
        }

        func executeRequest(_ request: HTTPSchedulableRequest) {
            let poolKey = request.poolKey
            let poolResult = self.lock.withLock { () -> Result<HTTPConnectionPool, HTTPClientError> in
                switch self.state {
                case .active:
                    if let pool = self._pools[poolKey] {
                        return .success(pool)
                    }

                    let pool = HTTPConnectionPool(
                        eventLoopGroup: self.eventLoopGroup,
                        sslContextCache: self.sslContextCache,
                        tlsConfiguration: request.tlsConfiguration,
                        clientConfiguration: self.configuration,
                        key: poolKey,
                        delegate: self,
                        idGenerator: self.connectionIDGenerator,
                        backgroundActivityLogger: self.logger
                    )
                    self._pools[poolKey] = pool
                    return .success(pool)

                case .shuttingDown, .shutDown:
                    return .failure(HTTPClientError.alreadyShutdown)
                }
            }

            switch poolResult {
            case .success(let pool):
                pool.executeRequest(request)
            case .failure(let error):
                request.fail(error)
            }
        }

        func shutdown(on eventLoop: EventLoop) -> EventLoopFuture<Bool> {
            enum ShutdownAction {
                case done(EventLoopFuture<Bool>)
                case shutdown([Key: HTTPConnectionPool], EventLoopFuture<Bool>)
            }

            let action = self.lock.withLock { () -> ShutdownAction in
                switch self.state {
                case .active:
                    // If there aren't any pools, we can mark the pool as shut down right away.
                    if self._pools.isEmpty {
                        let future = eventLoop.makeSucceededFuture(true)
                        self.state = .shutDown
                        return .done(future)
                    } else {
                        let promise = eventLoop.makePromise(of: Bool.self)
                        self.state = .shuttingDown(promise: promise, unclean: false)
                        return .shutdown(self._pools, promise.futureResult)
                    }

                case .shuttingDown, .shutDown:
                    preconditionFailure("PoolManager already shutdown")
                }
            }

            // if no pools are returned, the manager is already shutdown completely. Inform the
            // delegate. This is a very clean shutdown...
            switch action {
            case .done(let future):
                return future

            case .shutdown(let pools, let future):
                pools.values.forEach { pool in
                    pool.shutdown()
                }
                return future
            }
        }
    }
}

extension HTTPConnectionPool.Manager: HTTPConnectionPoolDelegate {
    func connectionPoolDidShutdown(_ pool: HTTPConnectionPool, unclean: Bool) {
        enum CloseAction {
            case close(EventLoopPromise<Bool>, unclean: Bool)
            case wait
        }

        let closeAction = self.lock.withLock { () -> CloseAction in
            switch self.state {
            case .active, .shutDown:
                preconditionFailure("Why are pools shutting down, if the manager did not give a signal")

            case .shuttingDown(let promise, let soFarUnclean):
                guard self._pools.removeValue(forKey: pool.key) === pool else {
                    preconditionFailure("Expected that the pool was ")
                }

                if self._pools.isEmpty {
                    self.state = .shutDown
                    return .close(promise, unclean: soFarUnclean || unclean)
                } else {
                    self.state = .shuttingDown(promise: promise, unclean: soFarUnclean || unclean)
                    return .wait
                }
            }
        }

        switch closeAction {
        case .close(let promise, unclean: let unclean):
            promise.succeed(unclean)
        case .wait:
            break
        }
    }
}

extension HTTPConnectionPool.Connection.ID {
    static var globalGenerator = Generator()

    struct Generator {
        private let atomic: NIOAtomic<Int>

        init() {
            self.atomic = .makeAtomic(value: 0)
        }

        func next() -> Int {
            return self.atomic.add(1)
        }
    }
}
