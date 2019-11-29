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
#if os(Linux)
#else
import Network
#endif

public final class HTTPClientCopyingDelegate: HTTPClientResponseDelegate {
    public typealias Response = Void

    let chunkHandler: (ByteBuffer) -> EventLoopFuture<Void>

    init(chunkHandler: @escaping (ByteBuffer) -> EventLoopFuture<Void>) {
        self.chunkHandler = chunkHandler
    }

    public func didReceiveBodyPart(task: HTTPClient.Task<Void>, _ buffer: ByteBuffer) -> EventLoopFuture<Void> {
        return self.chunkHandler(buffer)
    }

    public func didFinishRequest(task: HTTPClient.Task<Void>) throws {
        return ()
    }
}

#if os(Linux)
internal extension String {
    var isIPAddress: Bool {
      var ipv4Addr = in_addr()
      var ipv6Addr = in6_addr()

      return self.withCString { ptr in
          return inet_pton(AF_INET, ptr, &ipv4Addr) == 1 ||
                 inet_pton(AF_INET6, ptr, &ipv6Addr) == 1
      }
    }
}
#else
internal extension String {
    var isIPAddress: Bool {
        if #available(OSX 10.14, *) {
            if IPv4Address(self) != nil || IPv6Address(self) != nil {
                return true
            }
        } else {
            var ipv4Addr = in_addr()
            var ipv6Addr = in6_addr()

            return self.withCString { ptr in
                return inet_pton(AF_INET, ptr, &ipv4Addr) == 1 ||
                       inet_pton(AF_INET6, ptr, &ipv6Addr) == 1
            }
        }
        return false
    }
}
#endif
