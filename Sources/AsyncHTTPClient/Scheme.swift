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

/// List of schemes `HTTPClient` currently supports
enum Scheme: String {
    case http
    case https
    case unix
    case httpUnix = "http+unix"
    case httpsUnix = "https+unix"
}

extension Scheme {
    var usesTLS: Bool {
        switch self {
        case .http, .httpUnix, .unix:
            return false
        case .https, .httpsUnix:
            return true
        }
    }

    var defaultPort: Int {
        self.usesTLS ? 443 : 80
    }
}

extension Scheme {
    func supportsRedirects(to destinationScheme: String?) -> Bool {
        guard
            let destinationSchemeString = destinationScheme?.lowercased(),
            let destinationScheme = Self(rawValue: destinationSchemeString)
        else {
            return false
        }
        return self.supportsRedirects(to: destinationScheme)
    }

    func supportsRedirects(to destinationScheme: Self) -> Bool {
        switch self {
        case .http, .https:
            switch destinationScheme {
            case .http, .https:
                return true
            case .unix, .httpUnix, .httpsUnix:
                return false
            }
        case .unix, .httpUnix, .httpsUnix:
            return true
        }
    }
}
