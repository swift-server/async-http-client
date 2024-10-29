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

import XCTest

@testable import AsyncHTTPClient

class LRUCacheTests: XCTestCase {
    func testBasicsWork() {
        var cache = LRUCache<Int, Int>(capacity: 1)
        var requestedValueGens = 0
        for i in 0..<10 {
            let actual = cache.findOrAppend(key: i) { i in
                requestedValueGens += 1
                return i
            }
            XCTAssertEqual(i, actual)
        }
        XCTAssertEqual(10, requestedValueGens)

        let nine = cache.findOrAppend(key: 9) { i in
            XCTAssertEqual(9, i)
            XCTFail("9 should be in the cache")
            return -1
        }
        XCTAssertEqual(9, nine)
    }

    func testCachesTheRightThings() {
        var cache = LRUCache<Int, Int>(capacity: 3)

        for i in 0..<10 {
            let actual = cache.findOrAppend(key: i) { i in
                i
            }
            XCTAssertEqual(i, actual)

            let zero = cache.find(key: 0)
            XCTAssertEqual(0, zero, "at \(i), couldn't find 0")

            cache.append(key: -1, value: -1)
            XCTAssertEqual(-1, cache.find(key: -1))
        }

        XCTAssertEqual(0, cache.find(key: 0))
        XCTAssertEqual(9, cache.find(key: 9))

        for i in 1..<9 {
            XCTAssertNil(cache.find(key: i))
        }
    }

    func testAppendingTheSameDoesNotEvictButUpdates() {
        var cache = LRUCache<Int, Int>(capacity: 3)

        cache.append(key: 1, value: 1)
        cache.append(key: 3, value: 3)
        for i in (2...100).reversed() {
            cache.append(key: 2, value: i)
            XCTAssertEqual(i, cache.find(key: 2))
        }

        for i in 1...3 {
            XCTAssertEqual(i, cache.find(key: i))
        }

        cache.append(key: 4, value: 4)
        XCTAssertNil(cache.find(key: 1))
        for i in 2...4 {
            XCTAssertEqual(i, cache.find(key: i))
        }
    }
}
