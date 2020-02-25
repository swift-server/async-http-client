//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the AsyncHTTPClient project authors
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
import NIOHTTPCompression

internal extension String {
    var isIPAddress: Bool {
        var ipv4Addr = in_addr()
        var ipv6Addr = in6_addr()

        return self.withCString { ptr in
            inet_pton(AF_INET, ptr, &ipv4Addr) == 1 ||
                inet_pton(AF_INET6, ptr, &ipv6Addr) == 1
        }
    }
}

public final class HTTPClientCopyingDelegate: HTTPClientResponseDelegate {
    public typealias Response = Void

    let chunkHandler: (ByteBuffer) -> EventLoopFuture<Void>

    public init(chunkHandler: @escaping (ByteBuffer) -> EventLoopFuture<Void>) {
        self.chunkHandler = chunkHandler
    }

    public func didReceiveBodyPart(task: HTTPClient.Task<Void>, _ buffer: ByteBuffer) -> EventLoopFuture<Void> {
        return self.chunkHandler(buffer)
    }

    public func didFinishRequest(task: HTTPClient.Task<Void>) throws {
        return ()
    }
}

extension ClientBootstrap {
    static func makeHTTPClientBootstrapBase(group: EventLoopGroup, host: String, port: Int, configuration: HTTPClient.Configuration, channelInitializer: ((Channel) -> EventLoopFuture<Void>)? = nil) -> ClientBootstrap {
        return ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)

            .channelInitializer { channel in
                let channelAddedFuture: EventLoopFuture<Void>
                switch configuration.proxy {
                case .none:
                    channelAddedFuture = group.next().makeSucceededFuture(())
                case .some:
                    channelAddedFuture = channel.pipeline.addProxyHandler(host: host, port: port, authorization: configuration.proxy?.authorization)
                }
                return channelAddedFuture.flatMap { (_: Void) -> EventLoopFuture<Void> in
                    channelInitializer?(channel) ?? group.next().makeSucceededFuture(())
                }
            }
    }
}

extension CircularBuffer {
    @discardableResult
    mutating func swapWithFirstAndRemove(at index: Index) -> Element? {
        precondition(index >= self.startIndex && index < self.endIndex)
        if !self.isEmpty {
            self.swapAt(self.startIndex, index)
            return self.removeFirst()
        } else {
            return nil
        }
    }

    @discardableResult
    mutating func swapWithFirstAndRemove(where predicate: (Element) throws -> Bool) rethrows -> Element? {
        if let existingIndex = try self.firstIndex(where: predicate) {
            return self.swapWithFirstAndRemove(at: existingIndex)
        } else {
            return nil
        }
    }
}

extension ConnectionPool.Connection {
    func removeHandler<Handler: RemovableChannelHandler>(_ type: Handler.Type) -> EventLoopFuture<Void> {
        return self.channel.pipeline.handler(type: type).flatMap { handler in
            self.channel.pipeline.removeHandler(handler)
        }.recover { _ in }
    }
}
