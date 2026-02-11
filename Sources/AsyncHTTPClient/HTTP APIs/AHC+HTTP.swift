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
    public typealias RequestWriter = RequestBodyWriter
    public typealias ResponseConcludingReader = ResponseReader

    public struct RequestOptions: HTTPClientCapability.RequestOptions {
        public init() {}
    }

    public struct RequestBodyWriter: AsyncWriter, ~Copyable {
        public typealias WriteElement = UInt8
        public typealias WriteFailure = any Error

        let transaction: Transaction

        public mutating func write<Result, Failure>(
            _ body: nonisolated(nonsending) (inout OutputSpan<UInt8>) async throws(Failure) -> Result) async throws(AsyncStreaming.EitherError<any Error, Failure>
        ) -> Result where Failure : Error {
//            try await self.storage.write(body)
            fatalError()
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

            let trailers: HTTPFields?
            switch underlying.storage {
            case .transaction(_, let transaction, _):
                if let t = transaction.trailers {
                    let sequence = t.lazy.compactMap({
                        if let name = HTTPField.Name($0.name) {
                            HTTPField(name: name, value: $0.value)
                        } else {
                            nil
                        }
                    })
                    trailers = HTTPFields(sequence)
                } else {
                    trailers = nil
                }

            case .anyAsyncSequence:
                trailers = nil
            }
            return (returnValue, trailers)
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

    public func perform<Return: ~Copyable>(
        request: HTTPRequest,
        body: consuming HTTPClientRequestBody<RequestBodyWriter>?,
        options: HTTPClient.RequestOptions,
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
        if let body {
            ahcRequest.body = .init(.httpClientRequestBody(body))
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

        let result: Result<Return, any Error>
        do {
            result = .success(try await responseHandler(response, .init(underlying: ahcResponse.body)))
        } catch {
            result = .failure(error)
        }

        return try result.get()
    }
}

#endif
