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

protocol HTTPConnectionPoolManagerDelegate: AnyObject {
    func httpConnectionPoolManagerDidShutdown(_: HTTPConnectionPool.Manager, unclean: Bool)
}

extension HTTPConnectionPool {
    final class Manager {
        private typealias Key = ConnectionPool.Key

        private var _pools: [Key: HTTPConnectionPool] = [:]
        private let lock = Lock()

        private let sslContextCache = SSLContextCache()

        enum State {
            case active
            case shuttingDown(unclean: Bool)
            case shutDown
        }

        let eventLoopGroup: EventLoopGroup
        let configuration: HTTPClient.Configuration
        let connectionIDGenerator = Connection.ID.globalGenerator
        let logger: Logger

        /// A delegate to inform about the pools managers shutdown
        ///
        /// NOTE: Normally we create retain cycles in SwiftNIO code that we break on shutdown. However we wan't to inform
        ///      users that they must call `shutdown` on their AsyncHTTPClient. The best way to make them aware is with
        ///      a `preconditionFailure` in the HTTPClient's `deinit`. If we create a retain cycle here, the
        ///      `HTTPClient`'s `deinit` can never be reached. Instead the `HTTPClient` would leak.
        ///
        ///      The delegate is not thread safe at all. This only works if the HTTPClient sets itself as a delegate in its own
        ///      init.
        weak var delegate: HTTPConnectionPoolManagerDelegate?

        private var state: State = .active

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

        func execute(request: HTTPRequestTask) {
            let key = Key(request.request)

            let poolResult = self.lock.withLock { () -> Result<HTTPConnectionPool, HTTPClientError> in
                guard case .active = self.state else {
                    return .failure(HTTPClientError.alreadyShutdown)
                }

                if let pool = self._pools[key] {
                    return .success(pool)
                }

                let pool = HTTPConnectionPool(
                    eventLoopGroup: self.eventLoopGroup,
                    sslContextCache: self.sslContextCache,
                    tlsConfiguration: request.request.tlsConfiguration,
                    clientConfiguration: self.configuration,
                    key: key,
                    delegate: self,
                    idGenerator: self.connectionIDGenerator,
                    logger: self.logger
                )
                self._pools[key] = pool
                return .success(pool)
            }

            switch poolResult {
            case .success(let pool):
                pool.execute(request: request)
            case .failure(let error):
                request.fail(error)
            }
        }

        func shutdown() {
            let pools = self.lock.withLock { () -> [Key: HTTPConnectionPool] in
                guard case .active = self.state else {
                    preconditionFailure("PoolManager already shutdown")
                }

                // If there aren't any pools, we can mark the pool as shut down right away.
                if self._pools.isEmpty {
                    self.state = .shutDown
                } else {
                    self.state = .shuttingDown(unclean: false)
                }

                return self._pools
            }

            // if no pools are returned, the manager is already shutdown completely. Inform the
            // delegate. This is a very clean shutdown...
            if pools.isEmpty {
                self.delegate?.httpConnectionPoolManagerDidShutdown(self, unclean: false)
                return
            }

            pools.values.forEach { pool in
                pool.shutdown()
            }
        }
    }
}

extension HTTPConnectionPool.Manager: HTTPConnectionPoolDelegate {
    enum CloseAction {
        case close(unclean: Bool)
        case wait
    }

    func connectionPoolDidShutdown(_ pool: HTTPConnectionPool, unclean: Bool) {
        let closeAction = self.lock.withLock { () -> CloseAction in
            guard case .shuttingDown(let soFarUnclean) = self.state else {
                preconditionFailure("Why are pools shutting down, if the manager did not give a signal")
            }

            guard self._pools.removeValue(forKey: pool.key) === pool else {
                preconditionFailure("Expected that the pool was ")
            }

            if self._pools.isEmpty {
                self.state = .shutDown
                return .close(unclean: soFarUnclean || unclean)
            } else {
                self.state = .shuttingDown(unclean: soFarUnclean || unclean)
                return .wait
            }
        }

        switch closeAction {
        case .close(unclean: let unclean):
            self.delegate?.httpConnectionPoolManagerDidShutdown(self, unclean: unclean)
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
