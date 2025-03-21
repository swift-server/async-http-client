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
//
// Copyright 2021, gRPC Authors All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import XCTest

extension XCTestCase {
    /// Cross-platform XCTest support for async-await tests.
    ///
    /// Currently the Linux implementation of XCTest doesn't have async-await support.
    /// Until it does, we make use of this shim which uses a detached `Task` along with
    /// `XCTest.wait(for:timeout:)` to wrap the operation.
    ///
    /// - NOTE: Support for Linux is tracked by https://bugs.swift.org/browse/SR-14403.
    /// - NOTE: Implementation currently in progress: https://github.com/apple/swift-corelibs-xctest/pull/326
    @available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
    func XCTAsyncTest(
        expectationDescription: String = "Async operation",
        timeout: TimeInterval = 30,
        file: StaticString = #filePath,
        line: UInt = #line,
        function: StaticString = #function,
        operation: @escaping @Sendable () async throws -> Void
    ) {
        let expectation = self.expectation(description: expectationDescription)
        Task {
            do {
                try await operation()
            } catch {
                XCTFail("Error thrown while executing \(function): \(error)", file: file, line: line)
                for symbol in Thread.callStackSymbols { print(symbol) }
            }
            expectation.fulfill()
        }
        self.wait(for: [expectation], timeout: timeout)
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
internal func XCTAssertThrowsError<T>(
    _ expression: @autoclosure () async throws -> T,
    verify: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expression did not throw error", file: file, line: line)
    } catch {
        verify(error)
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
internal func XCTAssertNoThrowWithResult<Result>(
    _ expression: @autoclosure () async throws -> Result,
    file: StaticString = #filePath,
    line: UInt = #line
) async -> Result? {
    do {
        return try await expression()
    } catch {
        XCTFail("Expression did throw: \(error)", file: file, line: line)
    }
    return nil
}
