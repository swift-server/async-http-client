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

import NIOCore

extension HTTPConnectionPool {
    struct RequestID: Hashable {
        private let objectIdentifier: ObjectIdentifier

        init(_ request: HTTPSchedulableRequest) {
            self.objectIdentifier = ObjectIdentifier(request)
        }
    }

    struct Waiter {
        var requestID: RequestID {
            RequestID(self.request)
        }

        var request: HTTPSchedulableRequest

        private var eventLoopRequirement: EventLoop? {
            switch self.request.eventLoopPreference.preference {
            case .delegateAndChannel(on: let eventLoop),
                 .testOnly_exact(channelOn: let eventLoop, delegateOn: _):
                return eventLoop
            case .delegate(on: _),
                 .indifferent:
                return nil
            }
        }

        init(request: HTTPSchedulableRequest) {
            self.request = request
        }

        func canBeRun(on option: EventLoop) -> Bool {
            guard let requirement = self.eventLoopRequirement else {
                // if no requirement exists we can run on any EventLoop
                return true
            }

            return requirement === option
        }
    }
}
