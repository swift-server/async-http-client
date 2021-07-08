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

import NIO

extension HTTPConnectionPool {
    struct Waiter {
        struct ID: Hashable {
            private let objectIdentifier: ObjectIdentifier

            init(_ request: HTTPScheduledRequest) {
                self.objectIdentifier = ObjectIdentifier(request)
            }
        }

        var id: ID {
            ID(self.request)
        }

        var request: HTTPScheduledRequest {
            didSet {
                self.updateEventLoopRequirement()
            }
        }

        private var eventLoopRequirement: EventLoop?

        init(request: HTTPScheduledRequest) {
            self.request = request
            self.updateEventLoopRequirement()
        }

        func canBeRun(on option: EventLoop) -> Bool {
            guard let requirement = self.eventLoopRequirement else {
                // if no requirement exists we can run on any EventLoop
                return true
            }

            return requirement === option
        }

        private mutating func updateEventLoopRequirement() {
            switch self.request.eventLoopPreference.preference {
            case .delegateAndChannel(on: let eventLoop),
                 .testOnly_exact(channelOn: let eventLoop, delegateOn: _):
                self.eventLoopRequirement = eventLoop
            case .delegate(on: _),
                 .indifferent:
                self.eventLoopRequirement = nil
            }
        }
    }
}
