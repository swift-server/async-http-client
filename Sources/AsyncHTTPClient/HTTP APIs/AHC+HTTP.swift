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
        var byteBuffer: ByteBuffer
        var rigidArray: RigidArray<UInt8>

        init(transaction: Transaction) {
            self.transaction = transaction
            self.byteBuffer = ByteBuffer()
            self.byteBuffer.reserveCapacity(2^16)
            self.rigidArray = RigidArray(capacity: 2^16) // ~ 65k bytes
        }

        public mutating func write<Result, Failure>(
            _ body: nonisolated(nonsending) (inout OutputSpan<UInt8>) async throws(Failure) -> Result
        ) async throws(AsyncStreaming.EitherError<WriteFailure, Failure>) -> Result where Failure : Error {
            let result: Result
            do {
                self.rigidArray.reserveCapacity(1024)
                result = try await self.rigidArray.append(count: 1024) { (span) async throws(Failure) -> Result in
                    try await body(&span)
                }
            } catch {
                throw .second(error)
            }

            do {
                self.byteBuffer.clear()

                // we need to use an uninitilized helper rigidarray here to make the compiler happy
                // with regards overlapping memory access.
                var localArray = RigidArray<UInt8>(capacity: 0)
                swap(&localArray, &self.rigidArray)
                localArray.span.withUnsafeBufferPointer { bufferPtr in
                    self.byteBuffer.withUnsafeMutableWritableBytes { byteBufferPtr in
                        byteBufferPtr.copyBytes(from: bufferPtr)
                    }
                    self.byteBuffer.moveWriterIndex(forwardBy: bufferPtr.count)
                }

                swap(&localArray, &self.rigidArray)
                try await self.transaction.writeRequestBodyPart(self.byteBuffer)
            } catch {
                throw .first(error)
            }

            return result
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

        var result: Result<Return, any Error>?
        await withTaskGroup(of: Void.self) { taskGroup in

            var ahcRequest = HTTPClientRequest(url: url.absoluteString)
            ahcRequest.method = .init(rawValue: request.method.rawValue)
            if !request.headerFields.isEmpty {
                let sequence = request.headerFields.lazy.map({ ($0.name.rawName, $0.value) })
                ahcRequest.headers.add(contentsOf: sequence)
            }
            if let body {
                let length = body.knownLength.map { RequestBodyLength.known($0) } ?? .unknown
                let (asyncStream, startUploadContinuation) = AsyncStream.makeStream(of: Transaction.self)

                taskGroup.addTask {
                    // TODO: We might want to allow multiple body restarts here.

                    for await transaction in asyncStream {
                        do {
                            let writer = RequestWriter(transaction: transaction)
                            let maybeTrailers = try await body.produce(into: writer)
                            let trailers: HTTPHeaders? = if let trailers = maybeTrailers {
                                HTTPHeaders(.init(trailers.lazy.map({ ($0.name.rawName, $0.value) })))
                            } else {
                                nil
                            }
                            transaction.requestBodyStreamFinished(trailers: trailers)
                            break // the loop
                        } catch {
                            fatalError("TODO: Better error handling here: \(error)")
                        }
                    }
                }

                ahcRequest.body = .init(.httpClientRequestBody(length: length, startUpload: startUploadContinuation))
            }

            do {
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

                result = .success(try await responseHandler(response, .init(underlying: ahcResponse.body)))
            } catch {
                result = .failure(error)
            }
        }

        return try result!.get()
    }
}

#endif
