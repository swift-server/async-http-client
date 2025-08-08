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
import NIOHTTP1

/// Generates base64 encoded username + password for http basic auth.
///
/// - Parameters:
///   - username: the username to authenticate with
///   - password: authentication password associated with the username
/// - Returns: encoded credentials to use the Authorization: Basic http header.
func encodeBasicAuthCredentials(username: String, password: String) -> String {
    var value = Data()
    value.reserveCapacity(username.utf8.count + password.utf8.count + 1)
    value.append(contentsOf: username.utf8)
    value.append(UInt8(ascii: ":"))
    value.append(contentsOf: password.utf8)
    return value.base64EncodedString()
}

extension HTTPHeaders {
    /// Sets the basic auth header
    mutating func setBasicAuth(username: String, password: String) {
        let encoded = encodeBasicAuthCredentials(username: username, password: password)
        self.replaceOrAdd(name: "Authorization", value: "Basic \(encoded)")
    }
}
