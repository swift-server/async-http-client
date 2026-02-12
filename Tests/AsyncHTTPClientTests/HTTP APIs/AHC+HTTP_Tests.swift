//
//  AHC+HTTP_Tests.swift
//  async-http-client
//
//  Created by Fabian Fett on 02.12.25.
//

#if compiler(>=6.2)
import NIOCore
import HTTPTypes
import HTTPAPIs
import Testing
import AsyncHTTPClient

@Suite
struct AbstractHTTPClientTest {

    @available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
    @Test func testGet() async throws {

        let bin = HTTPBin(.http1_1(ssl: false))
        defer { try! bin.shutdown() }

        let request = HTTPRequest(method: .post, scheme: "http", authority: "127.0.0.1:\(bin.port)", path: "/trailers")

        try await HTTPClient.shared.perform(
            request: request,
            body: nil,
            options: .init(),
        ) { response, responseReader in
            print("status: \(response.status)")
            for header in response.headerFields {
                print("\(header.name): \(header.value)")
            }

            let trailers = try await responseReader.collect(upTo: 1024) { span in
                span.withUnsafeBufferPointer { buffer in
                    print(String(decoding: buffer, as: Unicode.UTF8.self))
                }
            }

            print(trailers)
        }

    }

    @available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
    @Test func testPost() async throws {

        let bin = HTTPBin(.http1_1(ssl: false)) { _ in HTTPEchoHandler() }
        defer { try! bin.shutdown() }

        let request = HTTPRequest(method: .post, scheme: "http", authority: "127.0.0.1:\(bin.port)", path: "/")

        try await HTTPClient.shared.perform(
            request: request,
            body: .restartable { (writer: consuming AsyncHTTPClient.HTTPClient.RequestWriter) in
                var mwriter = writer

                for i in 0..<100 {
                    try await mwriter.write { outputSpan in
                        outputSpan.append("\(i)\n".utf8)
                    }
                }

                return [HTTPField.Name("foo")!: "bar"]
            },
            options: .init(),
        ) { response, responseReader in
            print("status: \(response.status)")
            for header in response.headerFields {
                print("\(header.name): \(header.value)")
            }

            let trailers = try await responseReader.consumeAndConclude { bodyReader in
                var bodyReader = bodyReader
                var `continue` = true
                while `continue` {
                    try await bodyReader.read(maximumCount: 1024) { span in
                        if span.count == 0 { `continue` = false }

                        span.withUnsafeBufferPointer { buffer in
                            print(String(decoding: buffer, as: Unicode.UTF8.self), terminator: "")
                        }
                    }
                }
            }

            print(trailers)
        }
    }
}

extension OutputSpan<UInt8> {

    mutating func append(_ sequence: some Sequence<UInt8>) {
        for element in sequence {
            self.append(element)
        }
    }

}

#endif
