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

import NIOCore
import NIOEmbedded
import NIOHTTP1
import XCTest

@testable import AsyncHTTPClient

class HTTP1ProxyConnectHandlerTests: XCTestCase {
    func testProxyConnectWithoutAuthorizationSuccess() {
        let embedded = EmbeddedChannel()
        defer { XCTAssertNoThrow(try embedded.finish(acceptAlreadyClosed: false)) }

        let socketAddress = try! SocketAddress.makeAddressResolvingHost("localhost", port: 0)
        XCTAssertNoThrow(try embedded.connect(to: socketAddress).wait())

        let proxyConnectHandler = HTTP1ProxyConnectHandler(
            targetHost: "swift.org",
            targetPort: 443,
            proxyAuthorization: .none,
            deadline: .now() + .seconds(10)
        )

        XCTAssertNoThrow(try embedded.pipeline.syncOperations.addHandler(proxyConnectHandler))

        var maybeHead: HTTPClientRequestPart?
        XCTAssertNoThrow(maybeHead = try embedded.readOutbound(as: HTTPClientRequestPart.self))
        guard case .some(.head(let head)) = maybeHead else {
            return XCTFail("Expected the proxy connect handler to first send a http head part")
        }

        XCTAssertEqual(head.method, .CONNECT)
        XCTAssertEqual(head.uri, "swift.org:443")
        XCTAssertEqual(head.headers["host"].first, "swift.org")
        XCTAssertNil(head.headers["proxy-authorization"].first)
        XCTAssertEqual(try embedded.readOutbound(as: HTTPClientRequestPart.self), .end(nil))

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok)
        XCTAssertNoThrow(try embedded.writeInbound(HTTPClientResponsePart.head(responseHead)))
        XCTAssertNoThrow(try embedded.writeInbound(HTTPClientResponsePart.end(nil)))

        XCTAssertNoThrow(try XCTUnwrap(proxyConnectHandler.proxyEstablishedFuture).wait())
    }

    func testProxyConnectWithAuthorization() {
        let embedded = EmbeddedChannel()

        let socketAddress = try! SocketAddress.makeAddressResolvingHost("localhost", port: 0)
        XCTAssertNoThrow(try embedded.connect(to: socketAddress).wait())

        let proxyConnectHandler = HTTP1ProxyConnectHandler(
            targetHost: "swift.org",
            targetPort: 443,
            proxyAuthorization: .basic(credentials: "abc123"),
            deadline: .now() + .seconds(10)
        )

        XCTAssertNoThrow(try embedded.pipeline.syncOperations.addHandler(proxyConnectHandler))

        var maybeHead: HTTPClientRequestPart?
        XCTAssertNoThrow(maybeHead = try embedded.readOutbound(as: HTTPClientRequestPart.self))
        guard case .some(.head(let head)) = maybeHead else {
            return XCTFail("Expected the proxy connect handler to first send a http head part")
        }

        XCTAssertEqual(head.method, .CONNECT)
        XCTAssertEqual(head.uri, "swift.org:443")
        XCTAssertEqual(head.headers["host"].first, "swift.org")
        XCTAssertEqual(head.headers["proxy-authorization"].first, "Basic abc123")
        XCTAssertEqual(try embedded.readOutbound(as: HTTPClientRequestPart.self), .end(nil))

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok)
        XCTAssertNoThrow(try embedded.writeInbound(HTTPClientResponsePart.head(responseHead)))
        XCTAssertNoThrow(try embedded.writeInbound(HTTPClientResponsePart.end(nil)))

        XCTAssertNoThrow(try XCTUnwrap(proxyConnectHandler.proxyEstablishedFuture).wait())
    }

    func testProxyConnectWithoutAuthorizationFailure500() {
        let embedded = EmbeddedChannel()

        let socketAddress = try! SocketAddress.makeAddressResolvingHost("localhost", port: 0)
        XCTAssertNoThrow(try embedded.connect(to: socketAddress).wait())

        let proxyConnectHandler = HTTP1ProxyConnectHandler(
            targetHost: "swift.org",
            targetPort: 443,
            proxyAuthorization: .none,
            deadline: .now() + .seconds(10)
        )

        XCTAssertNoThrow(try embedded.pipeline.syncOperations.addHandler(proxyConnectHandler))

        var maybeHead: HTTPClientRequestPart?
        XCTAssertNoThrow(maybeHead = try embedded.readOutbound(as: HTTPClientRequestPart.self))
        guard case .some(.head(let head)) = maybeHead else {
            return XCTFail("Expected the proxy connect handler to first send a http head part")
        }

        XCTAssertEqual(head.method, .CONNECT)
        XCTAssertEqual(head.uri, "swift.org:443")
        XCTAssertEqual(head.headers["host"].first, "swift.org")
        XCTAssertNil(head.headers["proxy-authorization"].first)
        XCTAssertEqual(try embedded.readOutbound(as: HTTPClientRequestPart.self), .end(nil))

        let responseHead = HTTPResponseHead(version: .http1_1, status: .internalServerError)
        // answering with 500 should lead to a triggered error in pipeline
        XCTAssertThrowsError(try embedded.writeInbound(HTTPClientResponsePart.head(responseHead))) {
            XCTAssertEqual($0 as? HTTPClientError, .invalidProxyResponse)
        }
        XCTAssertFalse(embedded.isActive, "Channel should be closed in response to the error")
        XCTAssertNoThrow(try embedded.writeInbound(HTTPClientResponsePart.end(nil)))

        XCTAssertThrowsError(try XCTUnwrap(proxyConnectHandler.proxyEstablishedFuture).wait()) {
            XCTAssertEqual($0 as? HTTPClientError, .invalidProxyResponse)
        }
    }

    func testProxyConnectWithoutAuthorizationButAuthorizationNeeded() {
        let embedded = EmbeddedChannel()

        let socketAddress = try! SocketAddress.makeAddressResolvingHost("localhost", port: 0)
        XCTAssertNoThrow(try embedded.connect(to: socketAddress).wait())

        let proxyConnectHandler = HTTP1ProxyConnectHandler(
            targetHost: "swift.org",
            targetPort: 443,
            proxyAuthorization: .none,
            deadline: .now() + .seconds(10)
        )

        XCTAssertNoThrow(try embedded.pipeline.syncOperations.addHandler(proxyConnectHandler))

        var maybeHead: HTTPClientRequestPart?
        XCTAssertNoThrow(maybeHead = try embedded.readOutbound(as: HTTPClientRequestPart.self))
        guard case .some(.head(let head)) = maybeHead else {
            return XCTFail("Expected the proxy connect handler to first send a http head part")
        }

        XCTAssertEqual(head.method, .CONNECT)
        XCTAssertEqual(head.uri, "swift.org:443")
        XCTAssertEqual(head.headers["host"].first, "swift.org")
        XCTAssertNil(head.headers["proxy-authorization"].first)
        XCTAssertEqual(try embedded.readOutbound(as: HTTPClientRequestPart.self), .end(nil))

        let responseHead = HTTPResponseHead(version: .http1_1, status: .proxyAuthenticationRequired)
        // answering with 500 should lead to a triggered error in pipeline
        XCTAssertThrowsError(try embedded.writeInbound(HTTPClientResponsePart.head(responseHead))) {
            XCTAssertEqual($0 as? HTTPClientError, .proxyAuthenticationRequired)
        }
        XCTAssertFalse(embedded.isActive, "Channel should be closed in response to the error")
        XCTAssertNoThrow(try embedded.writeInbound(HTTPClientResponsePart.end(nil)))

        XCTAssertThrowsError(try XCTUnwrap(proxyConnectHandler.proxyEstablishedFuture).wait()) {
            XCTAssertEqual($0 as? HTTPClientError, .proxyAuthenticationRequired)
        }
    }

    func testProxyConnectReceivesBody() {
        let embedded = EmbeddedChannel()

        let socketAddress = try! SocketAddress.makeAddressResolvingHost("localhost", port: 0)
        XCTAssertNoThrow(try embedded.connect(to: socketAddress).wait())

        let proxyConnectHandler = HTTP1ProxyConnectHandler(
            targetHost: "swift.org",
            targetPort: 443,
            proxyAuthorization: .none,
            deadline: .now() + .seconds(10)
        )

        XCTAssertNoThrow(try embedded.pipeline.syncOperations.addHandler(proxyConnectHandler))

        var maybeHead: HTTPClientRequestPart?
        XCTAssertNoThrow(maybeHead = try embedded.readOutbound(as: HTTPClientRequestPart.self))
        guard case .some(.head(let head)) = maybeHead else {
            return XCTFail("Expected the proxy connect handler to first send a http head part")
        }

        XCTAssertEqual(head.method, .CONNECT)
        XCTAssertEqual(head.uri, "swift.org:443")
        XCTAssertEqual(head.headers["host"].first, "swift.org")
        XCTAssertEqual(try embedded.readOutbound(as: HTTPClientRequestPart.self), .end(nil))

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok)
        XCTAssertNoThrow(try embedded.writeInbound(HTTPClientResponsePart.head(responseHead)))
        // answering with a body should lead to a triggered error in pipeline
        XCTAssertThrowsError(try embedded.writeInbound(HTTPClientResponsePart.body(ByteBuffer(bytes: [0, 1, 2, 3])))) {
            XCTAssertEqual($0 as? HTTPClientError, .invalidProxyResponse)
        }
        XCTAssertEqual(embedded.isActive, false)
        XCTAssertNoThrow(try embedded.writeInbound(HTTPClientResponsePart.end(nil)))

        XCTAssertThrowsError(try XCTUnwrap(proxyConnectHandler.proxyEstablishedFuture).wait()) {
            XCTAssertEqual($0 as? HTTPClientError, .invalidProxyResponse)
        }
    }
}
