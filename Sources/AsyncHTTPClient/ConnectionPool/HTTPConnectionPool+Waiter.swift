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

        let id: ID
        let request: HTTPScheduledRequest
        let eventLoopRequirement: EventLoop?

        init(request: HTTPScheduledRequest, eventLoopRequirement: EventLoop?) {
            self.id = ID(request)
            self.request = request
            self.eventLoopRequirement = eventLoopRequirement
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
