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

extension HTTPClient {
    /// A globally shared, singleton ``HTTPClient``.
    ///
    /// The returned client uses the following settings:
    /// - configuration is ``HTTPClient/Configuration/singletonConfiguration`` (matching the platform's default/prevalent browser as well as possible)
    /// - `EventLoopGroup` is ``HTTPClient/defaultEventLoopGroup`` (matching the platform default)
    /// - logging is disabled
    public static var shared: HTTPClient {
        globallySharedHTTPClient
    }
}

private let globallySharedHTTPClient: HTTPClient = {
    let httpClient = HTTPClient(
        eventLoopGroup: HTTPClient.defaultEventLoopGroup,
        configuration: .singletonConfiguration,
        backgroundActivityLogger: HTTPClient.loggingDisabled,
        canBeShutDown: false
    )
    return httpClient
}()
