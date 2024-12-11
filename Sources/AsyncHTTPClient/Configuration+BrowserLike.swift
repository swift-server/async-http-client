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
import NIOCore
import NIOHTTPCompression
import NIOSSL

// swift-format-ignore: DontRepeatTypeInStaticProperties
extension HTTPClient.Configuration {
    /// The ``HTTPClient/Configuration`` for ``HTTPClient/shared`` which tries to mimic the platform's default or prevalent browser as closely as possible.
    ///
    /// Don't rely on specific values of this configuration as they're subject to change. You can rely on them being somewhat sensible though.
    ///
    /// - note: At present, this configuration is nowhere close to a real browser configuration but in case of disagreements we will choose values that match
    ///   the default browser as closely as possible.
    ///
    /// Platform's default/prevalent browsers that we're trying to match (these might change over time):
    ///  - macOS: Safari
    ///  - iOS: Safari
    ///  - Android: Google Chrome
    ///  - Linux (non-Android): Google Chrome
    public static var singletonConfiguration: HTTPClient.Configuration {
        // To start with, let's go with these values. Obtained from Firefox's config.
        HTTPClient.Configuration(
            certificateVerification: .fullVerification,
            redirectConfiguration: .follow(max: 20, allowCycles: false),
            timeout: Timeout(connect: .seconds(90), read: .seconds(90)),
            connectionPool: .seconds(600),
            proxy: nil,
            ignoreUncleanSSLShutdown: false,
            decompression: .enabled(limit: .ratio(25)),
            backgroundActivityLogger: nil
        )
    }
}
