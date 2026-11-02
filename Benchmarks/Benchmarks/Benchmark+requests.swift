//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2026 Apple Inc. and the AsyncHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import AsyncHTTPClient
import Benchmark
import NIOCore
import NIOHTTP1
import NIOSSL

extension Benchmark {
    func measureRequests(
        _ method: HTTPMethod,
        _ path: String,
        body: ByteBuffer? = nil,
        reusingConnection: Bool = true
    ) async throws {
        var request = HTTPClientRequest(url: "https://127.0.0.1:8443\(path)")
        request.method = method
        request.body = body.map { .bytes($0) }

        var configuration = HTTPClient.Configuration()
        configuration.tlsConfiguration = .makeClientConfiguration()
        configuration.tlsConfiguration?.certificateVerification = .none
        if !reusingConnection {
            configuration.maximumUsesPerConnection = 1
        }

        try await HTTPClient.withHTTPClient(configuration: configuration) { client in
            do {
                try await Self.send(request, on: client)
            } catch let error as BenchmarkError {
                throw error
            } catch {
                throw BenchmarkError.serverNotReachable(underlying: error)
            }

            self.startMeasurement()
            for _ in self.scaledIterations {
                try await Self.send(request, on: client)
            }
            self.stopMeasurement()
        }
    }

    private static func send(_ request: HTTPClientRequest, on client: HTTPClient) async throws {
        let response = try await client.execute(request, timeout: .seconds(30))
        guard response.status == .ok else {
            throw BenchmarkError.unexpectedStatus(response.status.code)
        }
        for try await _ in response.body {}
    }
}
