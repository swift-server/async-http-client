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
// HTTPConnectionPool+HTTP2StateMachineTests+XCTest.swift
//
import XCTest

///
/// NOTE: This file was generated by generate_linux_tests.rb
///
/// Do NOT edit this file directly as it will be regenerated automatically when needed.
///

extension HTTPConnectionPool_HTTP2StateMachineTests {
    static var allTests: [(String, (HTTPConnectionPool_HTTP2StateMachineTests) -> () throws -> Void)] {
        return [
            ("testCreatingOfConnection", testCreatingOfConnection),
            ("testConnectionFailureBackoff", testConnectionFailureBackoff),
            ("testConnectionFailureWhileShuttingDown", testConnectionFailureWhileShuttingDown),
            ("testConnectionFailureWithoutRetry", testConnectionFailureWithoutRetry),
            ("testCancelRequestWorks", testCancelRequestWorks),
            ("testExecuteOnShuttingDownPool", testExecuteOnShuttingDownPool),
            ("testHTTP1ToHTTP2MigrationAndShutdownIfFirstConnectionIsHTTP1", testHTTP1ToHTTP2MigrationAndShutdownIfFirstConnectionIsHTTP1),
            ("testSchedulingAndCancelingOfIdleTimeout", testSchedulingAndCancelingOfIdleTimeout),
            ("testConnectionTimeout", testConnectionTimeout),
            ("testConnectionEstablishmentFailure", testConnectionEstablishmentFailure),
            ("testGoAwayOnIdleConnection", testGoAwayOnIdleConnection),
            ("testGoAwayWithLeasedStream", testGoAwayWithLeasedStream),
            ("testGoAwayWithPendingRequestsStartsNewConnection", testGoAwayWithPendingRequestsStartsNewConnection),
            ("testMigrationFromHTTP1ToHTTP2", testMigrationFromHTTP1ToHTTP2),
            ("testMigrationFromHTTP1ToHTTP2WhileShuttingDown", testMigrationFromHTTP1ToHTTP2WhileShuttingDown),
            ("testMigrationFromHTTP1ToHTTP2WithAlreadyStartedHTTP1Connections", testMigrationFromHTTP1ToHTTP2WithAlreadyStartedHTTP1Connections),
            ("testHTTP2toHTTP1Migration", testHTTP2toHTTP1Migration),
            ("testHTTP2toHTTP1MigrationDuringShutdown", testHTTP2toHTTP1MigrationDuringShutdown),
            ("testConnectionIsImmediatelyCreatedAfterBackoffTimerFires", testConnectionIsImmediatelyCreatedAfterBackoffTimerFires),
            ("testMaxConcurrentStreamsIsRespected", testMaxConcurrentStreamsIsRespected),
            ("testEventsAfterConnectionIsClosed", testEventsAfterConnectionIsClosed),
        ]
    }
}
