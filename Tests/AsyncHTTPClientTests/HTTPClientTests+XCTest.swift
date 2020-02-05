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
// HTTPClientTests+XCTest.swift
//
import XCTest

///
/// NOTE: This file was generated by generate_linux_tests.rb
///
/// Do NOT edit this file directly as it will be regenerated automatically when needed.
///

extension HTTPClientTests {
    static var allTests: [(String, (HTTPClientTests) -> () throws -> Void)] {
        return [
            ("testRequestURI", testRequestURI),
            ("testBadRequestURI", testBadRequestURI),
            ("testSchemaCasing", testSchemaCasing),
            ("testGet", testGet),
            ("testGetWithDifferentEventLoopBackpressure", testGetWithDifferentEventLoopBackpressure),
            ("testPost", testPost),
            ("testGetHttps", testGetHttps),
            ("testGetHttpsWithIP", testGetHttpsWithIP),
            ("testPostHttps", testPostHttps),
            ("testHttpRedirect", testHttpRedirect),
            ("testHttpHostRedirect", testHttpHostRedirect),
            ("testPercentEncoded", testPercentEncoded),
            ("testMultipleContentLengthHeaders", testMultipleContentLengthHeaders),
            ("testStreaming", testStreaming),
            ("testRemoteClose", testRemoteClose),
            ("testReadTimeout", testReadTimeout),
            ("testDeadline", testDeadline),
            ("testCancel", testCancel),
            ("testHTTPClientAuthorization", testHTTPClientAuthorization),
            ("testProxyPlaintext", testProxyPlaintext),
            ("testProxyTLS", testProxyTLS),
            ("testProxyPlaintextWithCorrectlyAuthorization", testProxyPlaintextWithCorrectlyAuthorization),
            ("testProxyPlaintextWithIncorrectlyAuthorization", testProxyPlaintextWithIncorrectlyAuthorization),
            ("testUploadStreaming", testUploadStreaming),
            ("testNoContentLengthForSSLUncleanShutdown", testNoContentLengthForSSLUncleanShutdown),
            ("testNoContentLengthWithIgnoreErrorForSSLUncleanShutdown", testNoContentLengthWithIgnoreErrorForSSLUncleanShutdown),
            ("testCorrectContentLengthForSSLUncleanShutdown", testCorrectContentLengthForSSLUncleanShutdown),
            ("testNoContentForSSLUncleanShutdown", testNoContentForSSLUncleanShutdown),
            ("testNoResponseForSSLUncleanShutdown", testNoResponseForSSLUncleanShutdown),
            ("testNoResponseWithIgnoreErrorForSSLUncleanShutdown", testNoResponseWithIgnoreErrorForSSLUncleanShutdown),
            ("testWrongContentLengthForSSLUncleanShutdown", testWrongContentLengthForSSLUncleanShutdown),
            ("testWrongContentLengthWithIgnoreErrorForSSLUncleanShutdown", testWrongContentLengthWithIgnoreErrorForSSLUncleanShutdown),
            ("testEventLoopArgument", testEventLoopArgument),
            ("testDecompression", testDecompression),
            ("testDecompressionLimit", testDecompressionLimit),
            ("testLoopDetectionRedirectLimit", testLoopDetectionRedirectLimit),
            ("testCountRedirectLimit", testCountRedirectLimit),
            ("testMultipleConcurrentRequests", testMultipleConcurrentRequests),
            ("testWorksWith500Error", testWorksWith500Error),
            ("testWorksWithHTTP10Response", testWorksWithHTTP10Response),
            ("testWorksWhenServerClosesConnectionAfterReceivingRequest", testWorksWhenServerClosesConnectionAfterReceivingRequest),
            ("testSubsequentRequestsWorkWithServerSendingConnectionClose", testSubsequentRequestsWorkWithServerSendingConnectionClose),
            ("testSubsequentRequestsWorkWithServerAlternatingBetweenKeepAliveAndClose", testSubsequentRequestsWorkWithServerAlternatingBetweenKeepAliveAndClose),
            ("testManyConcurrentRequestsWork", testManyConcurrentRequestsWork),
            ("testRepeatedRequestsWorkWhenServerAlwaysCloses", testRepeatedRequestsWorkWhenServerAlwaysCloses),
        ]
    }
}
