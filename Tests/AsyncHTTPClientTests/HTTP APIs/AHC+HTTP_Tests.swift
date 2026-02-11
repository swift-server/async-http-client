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
    @Test func testExample() async throws {

        let bin = HTTPBin(.http1_1(ssl: false))
        defer { try! bin.shutdown() }

        let client = HTTPClient()
        defer { try! client.shutdown().wait() }

        let request = HTTPRequest(method: .get, scheme: "http", authority: "127.0.0.1:\(bin.port)", path: "/trailers")
//        let body = HTTPClientRequestBody.restartable { (writer: consuming AsyncHTTPClient.HTTPClient.RequestWriter) in
//            try await writer.produceAndConclude { writer in
//
//                var mwriter = writer
//
//                try await mwriter.write { outputSpan in
//                    outputSpan.append(repeating: UInt8(ascii: "X"), count: 10)
//                }
//
//                return ((), nil)
//            }
//        }


        try await client.perform(
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

}

#endif
