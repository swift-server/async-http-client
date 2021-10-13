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
// HTTPConnectionPool+HTTP1ConnectionsTest+XCTest.swift
//
import XCTest

///
/// NOTE: This file was generated by generate_linux_tests.rb
///
/// Do NOT edit this file directly as it will be regenerated automatically when needed.
///

extension HTTPConnectionPool_HTTP1ConnectionsTests {
    static var allTests: [(String, (HTTPConnectionPool_HTTP1ConnectionsTests) -> () throws -> Void)] {
        return [
            ("testCreatingConnections", testCreatingConnections),
            ("testCreatingConnectionAndFailing", testCreatingConnectionAndFailing),
            ("testLeaseConnectionOnPreferredAndAvailableEL", testLeaseConnectionOnPreferredAndAvailableEL),
            ("testLeaseConnectionOnPreferredButUnavailableEL", testLeaseConnectionOnPreferredButUnavailableEL),
            ("testLeaseConnectionOnRequiredButUnavailableEL", testLeaseConnectionOnRequiredButUnavailableEL),
            ("testLeaseConnectionOnRequiredAndAvailableEL", testLeaseConnectionOnRequiredAndAvailableEL),
            ("testCloseConnectionIfIdle", testCloseConnectionIfIdle),
            ("testCloseConnectionIfIdleButLeasedRaceCondition", testCloseConnectionIfIdleButLeasedRaceCondition),
            ("testCloseConnectionIfIdleButClosedRaceCondition", testCloseConnectionIfIdleButClosedRaceCondition),
            ("testShutdown", testShutdown),
            ("testMigrationFromHTTP2", testMigrationFromHTTP2),
            ("testMigrationFromHTTP2WithPendingRequestsWithRequiredEventLoop", testMigrationFromHTTP2WithPendingRequestsWithRequiredEventLoop),
            ("testMigrationFromHTTP2WithPendingRequestsWithPreferredEventLoop", testMigrationFromHTTP2WithPendingRequestsWithPreferredEventLoop),
            ("testMigrationFromHTTP2WithAlreadyLeasedHTTP1Connection", testMigrationFromHTTP2WithAlreadyLeasedHTTP1Connection),
        ]
    }
}
