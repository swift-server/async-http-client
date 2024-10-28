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

struct LRUCache<Key: Equatable, Value> {
    private typealias Generation = UInt64
    private struct Element {
        var generation: Generation
        var key: Key
        var value: Value
    }

    private let capacity: Int
    private var generation: Generation = 0
    private var elements: [Element]

    init(capacity: Int = 8) {
        precondition(capacity > 0, "capacity needs to be > 0")
        self.capacity = capacity
        self.elements = []
        self.elements.reserveCapacity(capacity)
    }

    private mutating func bumpGenerationAndFindIndex(key: Key) -> Int? {
        self.generation += 1

        let found = self.elements.firstIndex { element in
            element.key == key
        }

        return found
    }

    mutating func find(key: Key) -> Value? {
        if let found = self.bumpGenerationAndFindIndex(key: key) {
            self.elements[found].generation = self.generation
            return self.elements[found].value
        } else {
            return nil
        }
    }

    @discardableResult
    mutating func append(key: Key, value: Value) -> Value {
        let newElement = Element(
            generation: self.generation,
            key: key,
            value: value
        )
        if let found = self.bumpGenerationAndFindIndex(key: key) {
            self.elements[found] = newElement
            return value
        }

        if self.elements.count < self.capacity {
            self.elements.append(newElement)
            return value
        }
        assert(self.elements.count == self.capacity)
        assert(self.elements.count > 0)

        let minIndex = self.elements.minIndex { l, r in
            l.generation < r.generation
        }!

        self.elements.swapAt(minIndex, self.elements.endIndex - 1)
        self.elements.removeLast()
        self.elements.append(newElement)

        return value
    }

    mutating func findOrAppend(key: Key, _ valueGenerator: (Key) -> Value) -> Value {
        if let found = self.find(key: key) {
            return found
        }

        return self.append(key: key, value: valueGenerator(key))
    }
}

extension Array {
    func minIndex(by areInIncreasingOrder: (Element, Element) throws -> Bool) rethrows -> Index? {
        guard var minSoFar: (Index, Element) = self.first.map({ (0, $0) }) else {
            return nil
        }

        for indexElement in self.enumerated() {
            if try areInIncreasingOrder(indexElement.1, minSoFar.1) {
                minSoFar = indexElement
            }
        }

        return minSoFar.0
    }
}
