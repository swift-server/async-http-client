//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the AsyncHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
//
// HTTPConnectionPoolTests+XCTest.swift
//
import XCTest

///
/// NOTE: This file was generated by generate_linux_tests.rb
///
/// Do NOT edit this file directly as it will be regenerated automatically when needed.
///

extension HTTPConnectionPoolTests {
    static var allTests: [(String, (HTTPConnectionPoolTests) -> () throws -> Void)] {
        return [
            ("testOnlyOneConnectionIsUsedForSubSequentRequests", testOnlyOneConnectionIsUsedForSubSequentRequests),
            ("testConnectionsForEventLoopRequirementsAreClosed", testConnectionsForEventLoopRequirementsAreClosed),
            ("testConnectionPoolGrowsToMaxConcurrentConnections", testConnectionPoolGrowsToMaxConcurrentConnections),
            ("testConnectionCreationIsRetriedUntilRequestIsFailed", testConnectionCreationIsRetriedUntilRequestIsFailed),
            ("testConnectionCreationIsRetriedUntilPoolIsShutdown", testConnectionCreationIsRetriedUntilPoolIsShutdown),
            ("testConnectionCreationIsRetriedUntilRequestIsCancelled", testConnectionCreationIsRetriedUntilRequestIsCancelled),
        ]
    }
}
