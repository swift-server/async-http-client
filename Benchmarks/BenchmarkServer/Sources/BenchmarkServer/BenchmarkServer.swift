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

import BasicContainers
import Crypto
import Foundation
import HTTPTypes
import NIOHTTPServer
import X509

@main
struct BenchmarkServer {
    static func main() async throws {
        let server = NIOHTTPServer(
            configuration: try .init(
                bindTarget: .hostAndPort(host: "127.0.0.1", port: 8443),
                supportedHTTPVersions: [.http2()],
                transportSecurity: .tls(credentials: try Self.selfSignedCredentials())
            )
        )

        try await server.serve { request, _, reader, responseSender in
            var body = UniqueArray<UInt8>()
            _ = try await reader.collect(into: &body, maximumSize: 1 << 20)

            var response = HTTPResponse(status: .ok)
            switch request.path {
            case "/echo":
                break
            case "/upload":
                body = UniqueArray()
            case let path? where path.hasPrefix("/download/"):
                body = UniqueArray(repeating: UInt8(ascii: "a"), count: Int(path.dropFirst(10)) ?? 0)
            default:
                response.status = .notFound
                body = UniqueArray()
            }
            try await responseSender.sendAndFinish(response, buffer: &body)
        }
    }

    private static func selfSignedCredentials() throws -> NIOHTTPServerConfiguration.TransportSecurity.TLSCredentials {
        let privateKey = Certificate.PrivateKey(P256.Signing.PrivateKey())
        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: privateKey.publicKey,
            notValidBefore: .now.addingTimeInterval(-60),
            notValidAfter: .now.addingTimeInterval(60 * 60 * 24),
            issuer: DistinguishedName(),
            subject: DistinguishedName(),
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: Certificate.Extensions(),
            issuerPrivateKey: privateKey
        )
        return .x509(.certificates(chain: [certificate], privateKey: privateKey))
    }
}
