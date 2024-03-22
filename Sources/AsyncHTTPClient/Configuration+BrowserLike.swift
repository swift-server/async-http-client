//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2023 Apple Inc. and the AsyncHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

extension HTTPClient.Configuration {
    /// A ``HTTPClient/Configuration`` that tries to mimick the platform's default or prevalent browser as closely as possible.
    ///
    /// Platform's default/prevalent browsers that we're trying to match (these might change over time):
    ///  - macOS: Safari
    ///  - iOS: Safari
    ///  - Android: Google Chrome
    ///  - Linux (non-Android): Google Chrome
    ///
    /// - note: Don't rely on the values in here never changing, they will be adapted to better match the platform's default/prevalent browser.
    public static var browserLike: HTTPClient.Configuration {
        // To start with, let's go with these values. Obtained from Firefox's config.
        return HTTPClient.Configuration(
            certificateVerification: .fullVerification,
            redirectConfiguration: .follow(max: 20, allowCycles: false),
            timeout: Timeout(connect: .seconds(90), read: .seconds(90)),
            connectionPool: .seconds(600),
            proxy: nil,
            ignoreUncleanSSLShutdown: false,
            decompression: .enabled(limit: .ratio(10)),
            backgroundActivityLogger: nil
        )
    }
}
