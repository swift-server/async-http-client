//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2025 Apple Inc. and the AsyncHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if compiler(>=6.2)
import HTTPAPIs
import HTTPTypes
import NIOHTTP1
import Foundation
import NIOCore
import Synchronization
import BasicContainers

@available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, *)
extension AsyncHTTPClient.HTTPClient: HTTPAPIs.HTTPClient {
    public typealias RequestConcludingWriter = RequestWriter
    public typealias ResponseConcludingReader = ResponseReader

    public struct RequestWriter: ConcludingAsyncWriter, ~Copyable, SendableMetatype {
        public typealias Underlying = RequestBodyWriter
        public typealias FinalElement = HTTPFields?

        final class Storage: Sendable {
            struct StateMachine: ~Copyable {

                enum State: ~Copyable {
                    case buffer(CheckedContinuation<Void, any Error>?)
                    case demand(CheckedContinuation<Void, any Error>)
                    case done(HTTPFields?)
                }

                var state: State = .buffer(nil)

                init() {

                }

            }

            let stateMutex = Mutex(StateMachine())

            nonisolated(nonsending) func write<Result, Failure>(
                _ body: nonisolated(nonsending) (inout OutputSpan<UInt8>) async throws(Failure) -> Result) async throws(AsyncStreaming.EitherError<any Error, Failure>
            ) -> Result where Failure : Error {

                fatalError()
//                do {
//
//                    self.stateMutex.withLock { state in
//                        
//                    }
//
//                    let updated = try await self.buffer.edit { (outputSpan) async throws(Failure) -> Result in
//                        try await body(&outputSpan)
//                    }
//
//
//
//                    return updated
//                } catch {
//                    throw .first(error)
//                }
            }

            func next() -> ByteBuffer {
                fatalError()
            }
        }

        let storage: Storage

        init() {
            self.storage = .init()
        }

        public consuming func produceAndConclude<Return>(
            body: nonisolated(nonsending) (consuming sending HTTPClient.RequestBodyWriter) async throws -> (Return, HTTPFields?)
        ) async throws -> Return {
            let bodyWriter = RequestBodyWriter(storage: self.storage)
            do {
                let (ret, fields) = try await body(bodyWriter)
                return ret
            } catch {
                throw error
            }
        }
    }

    public struct RequestBodyWriter: AsyncWriter, ~Copyable {
        public typealias WriteElement = UInt8
        public typealias WriteFailure = any Error

        let storage: RequestWriter.Storage

        public mutating func write<Result, Failure>(
            _ body: nonisolated(nonsending) (inout OutputSpan<UInt8>) async throws(Failure) -> Result) async throws(AsyncStreaming.EitherError<any Error, Failure>
        ) -> Result where Failure : Error {
            try await self.storage.write(body)
        }
    }

    public struct ResponseReader: ConcludingAsyncReader {
        public typealias Underlying = ResponseBodyReader

        let underlying: HTTPClientResponse.Body

        public typealias FinalElement = HTTPFields?

        init(underlying: HTTPClientResponse.Body) {
            self.underlying = underlying
        }

        public consuming func consumeAndConclude<Return, Failure>(
            body: nonisolated(nonsending) (consuming sending HTTPClient.ResponseBodyReader) async throws(Failure) -> Return
        ) async throws(Failure) -> (Return, HTTPFields?) where Failure : Error {
            let iterator = self.underlying.makeAsyncIterator()
            let reader = ResponseBodyReader(underlying: iterator)
            let returnValue = try await body(reader)
            return (returnValue, nil)
        }

    }

    public struct ResponseBodyReader: AsyncReader, ~Copyable {
        public typealias ReadElement = UInt8
        public typealias ReadFailure = any Error

        var underlying: HTTPClientResponse.Body.AsyncIterator

        public mutating func read<Return, Failure>(
            maximumCount: Int?,
            body: nonisolated(nonsending) (consuming Span<UInt8>) async throws(Failure) -> Return
        ) async throws(AsyncStreaming.EitherError<ReadFailure, Failure>) -> Return where Failure : Error {

            do {
                let buffer = try await self.underlying.next(isolation: #isolation)
                if let buffer {
                    var array = RigidArray<UInt8>()
                    array.reserveCapacity(buffer.readableBytes)
                    buffer.withUnsafeReadableBytes { rawBufferPtr in
                        let usbptr = rawBufferPtr.assumingMemoryBound(to: UInt8.self)
                        array.append(copying: usbptr)
                    }
                    return try await body(array.span)
                } else {
                    let array = InlineArray<0, UInt8> { _ in }
                    return try await body(array.span)
                }
            } catch let error as Failure {
                throw .second(error)
            } catch {
                throw .first(error)
            }
        }
    }

    public func perform<Return>(
        request: HTTPRequest,
        body: consuming HTTPClientRequestBody<RequestWriter>?,
        configuration: HTTPClientConfiguration,
        eventHandler: borrowing some HTTPClientEventHandler & ~Copyable & ~Escapable,
        responseHandler: nonisolated(nonsending) (HTTPResponse, consuming ResponseReader) async throws -> Return
    ) async throws -> Return {
        guard let url = request.url else {
            fatalError()
        }

        var ahcRequest = HTTPClientRequest(url: url.absoluteString)
        ahcRequest.method = .init(rawValue: request.method.rawValue)
        if !request.headerFields.isEmpty {
            let sequence = request.headerFields.lazy.map({ ($0.name.rawName, $0.value) })
            ahcRequest.headers.add(contentsOf: sequence)
        }

        let result = try await withThrowingTaskGroup { taskGroup in
            switch body {
            case .none:
                break

            case .restartable(let handler):
                taskGroup.addTask {
                    let writer = RequestWriter()
                    try await handler(writer)
                }
            case .some(.seekable(_)):
                fatalError()
            }

            let ahcResponse = try await self.execute(ahcRequest, timeout: .seconds(30))

            var responseFields = HTTPFields()
            for (name, value) in ahcResponse.headers {
                if let name = HTTPField.Name(name) {
                    responseFields[name] = value
                }
            }

            let response = HTTPResponse(
                status: .init(code: Int(ahcResponse.status.code)),
                headerFields: responseFields
            )

            return try await responseHandler(response, .init(underlying: ahcResponse.body))

        }

        return result
    }
}

//private struct ClosureAsyncSequence: AsyncSequence {
//    var body:
//
//}

#endif
