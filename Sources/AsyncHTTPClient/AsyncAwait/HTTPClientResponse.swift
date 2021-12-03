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

#if compiler(>=5.5) && canImport(_Concurrency)
import NIOCore
import NIOHTTP1

@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
struct HTTPClientResponse {
    var version: HTTPVersion
    var status: HTTPResponseStatus
    var headers: HTTPHeaders
    var body: Body

    struct Body {
        private let bag: AsyncRequestBag

        fileprivate init(_ bag: AsyncRequestBag) {
            self.bag = bag
        }
    }

    init(
        bag: AsyncRequestBag,
        version: HTTPVersion,
        status: HTTPResponseStatus,
        headers: HTTPHeaders
    ) {
        self.body = .init(bag)
        self.version = version
        self.status = status
        self.headers = headers
    }
}

@available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
extension HTTPClientResponse.Body: AsyncSequence {
    typealias Element = ByteBuffer
    typealias AsyncIterator = Iterator

    struct Iterator: AsyncIteratorProtocol {
        typealias Element = ByteBuffer

        private let stream: IteratorStream

        fileprivate init(stream: IteratorStream) {
            self.stream = stream
        }

        func next() async throws -> ByteBuffer? {
            try await self.stream.next()
        }
    }

    func makeAsyncIterator() -> Iterator {
        Iterator(stream: IteratorStream(bag: self.bag))
    }

    internal class IteratorStream {
        struct ID: Hashable {
            private let objectID: ObjectIdentifier

            init(_ object: IteratorStream) {
                self.objectID = ObjectIdentifier(object)
            }
        }

        var id: ID { ID(self) }
        private let bag: AsyncRequestBag

        init(bag: AsyncRequestBag) {
            self.bag = bag
        }

        deinit {
            self.bag.cancelResponseStream(streamID: self.id)
        }

        func next() async throws -> ByteBuffer? {
            try await self.bag.nextResponsePart(streamID: self.id)
        }
    }
}

#endif
