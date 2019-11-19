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
// HTTPClientPerformanceBenchmarkTests.swift.swift
import AsyncHTTPClient
import Foundation
import XCTest

private class AsyncHTTPClientTestOperation: AsynchronousOperation {
    private let httpClient: HTTPClient
    
    init(httpClient: HTTPClient) {
        self.httpClient = httpClient
        super.init()
    }
    
    override func execute() {
        httpClient.get(url: "https://swift.org").whenComplete { _ in
            self.finish()
        }
    }
}
private class URLSessionTestOperation: AsynchronousOperation {

    private let session: URLSession

    init(session: URLSession) {
        self.session = session
        super.init()
    }

    override func execute() {
        let url = URL(string: "https://swift.org")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let task = session.dataTask(with: request) { (_, _, _) in
            self.finish()
        }
        task.resume()
    }
}

final class PerformanceTests: XCTestCase {

    var httpClient: HTTPClient!
    var session: URLSession!

    private let operationQueue = OperationQueue()
    private let processingQueue = DispatchQueue(label: "TestOperationQueue", qos: .utility, attributes: .concurrent)

    private struct K {
        static let numberOfOperations = 2
    }

    override func setUp() {
        operationQueue.maxConcurrentOperationCount = 1
        operationQueue.underlyingQueue = processingQueue

        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30.0
        session = URLSession(configuration: configuration)
        httpClient = HTTPClient(eventLoopGroupProvider: .createNew)
    }

    override func tearDown() {
        try! httpClient.syncShutdown()
    }

    func testAsyncHTTPClient() {
        self.measure {
            var operations: [Operation] = []
            var startDate = Date()

            for _ in 0..<K.numberOfOperations {
                operations.append(AsyncHTTPClientTestOperation(httpClient: httpClient))
            }

            operations.last?.completionBlock = {
                print("AsyncHTTPClient run time: \(abs(startDate.timeIntervalSinceNow))")
                startDate = Date()
            }

            self.operationQueue.addOperations(operations, waitUntilFinished: true)
        }
    }

    func testURLSession() {
        self.measure {
            var operations: [Operation] = []
            var startDate = Date()

            for _ in 0..<K.numberOfOperations {
                operations.append(URLSessionTestOperation(session: session))
            }

            operations.last?.completionBlock = {
                print("URLSession run time: \(abs(startDate.timeIntervalSinceNow))")
                startDate = Date()
            }

            self.operationQueue.addOperations(operations, waitUntilFinished: true)
        }
    }
}

