//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2022 Apple Inc. and the AsyncHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if canImport(Network)
import Network
#endif
import NIOCore
import NIOHTTP1
import NIOTransportServices

final class NWWaitingHandler<Requester: HTTPConnectionRequester>: ChannelInboundHandler {
    typealias InboundIn = Any
    typealias InboundOut = Any

    private var requester: Requester?
    private let connectionID: HTTPConnectionPool.Connection.ID

    init(requester: Requester, connectionID: HTTPConnectionPool.Connection.ID) {
        self.requester = requester
        self.connectionID = connectionID
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        #if canImport(Network)
        if #available(OSX 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *) {
            if let waitingEvent = event as? NIOTSNetworkEvents.WaitingForConnectivity, let requester = self.requester {
                requester.waitingForConnectivity(self.connectionID, error: HTTPClient.NWErrorHandler.translateError(waitingEvent.transientError))
                self.requester = nil
            }
        }
        #endif
        context.fireUserInboundEventTriggered(event)
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.requester = nil
    }
}
