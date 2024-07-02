//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2024 Apple Inc. and the AsyncHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension HTTPClientRequest {
    /// Set basic auth for a request.
    ///
    /// - parameters:
    ///     - username: the username to authenticate with
    ///     - password: authentication password associated with the username
    public mutating func setBasicAuth(username: String, password: String) {
        self.headers.setBasicAuth(username: username, password: password)
    }
}
