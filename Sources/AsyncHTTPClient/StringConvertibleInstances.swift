//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2020 Apple Inc. and the AsyncHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

extension Connection: CustomStringConvertible {
    var description: String {
        return "\(self.channel)"
    }
}

extension HTTP1ConnectionProvider.Waiter: CustomStringConvertible {
    var description: String {
        return "HTTP1ConnectionProvider.Waiter(\(self.preference))"
    }
}

extension HTTPClient.EventLoopPreference: CustomStringConvertible {
    public var description: String {
        return "\(self.preference)"
    }
}
