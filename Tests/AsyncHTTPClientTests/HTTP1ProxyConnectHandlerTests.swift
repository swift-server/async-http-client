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

@testable import AsyncHTTPClient
import NIO
import NIOHTTP1
import XCTest

class HTTP1ProxyConnectHandlerTests: XCTestCase {
    func testProxyConnectWithoutAuthorizationSuccess() {
        let embedded = EmbeddedChannel()
        defer { XCTAssertNoThrow(try embedded.finish(acceptAlreadyClosed: false)) }

        let socketAddress = try! SocketAddress.makeAddressResolvingHost("localhost", port: 3000)
        XCTAssertNoThrow(try embedded.connect(to: socketAddress).wait())

        let connectPromise = embedded.eventLoop.makePromise(of: Void.self)
        let proxyConnectHandler = HTTP1ProxyConnectHandler(
            targetHost: "swift.org",
            targetPort: 443,
            proxyAuthorization: .none,
            connectPromise: connectPromise
        )

        XCTAssertNoThrow(try embedded.pipeline.syncOperations.addHandler(proxyConnectHandler))

        var maybeHead: HTTPClientRequestPart?
        XCTAssertNoThrow(maybeHead = try embedded.readOutbound(as: HTTPClientRequestPart.self))
        guard case .some(.head(let head)) = maybeHead else {
            return XCTFail("Expected the proxy connect handler to first send a http head part")
        }

        XCTAssertEqual(head.method, .CONNECT)
        XCTAssertEqual(head.uri, "swift.org:443")
        XCTAssertNil(head.headers["proxy-authorization"].first)
        XCTAssertEqual(try embedded.readOutbound(as: HTTPClientRequestPart.self), .end(nil))

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok)
        XCTAssertNoThrow(try embedded.writeInbound(HTTPClientResponsePart.head(responseHead)))
        XCTAssertNoThrow(try embedded.writeInbound(HTTPClientResponsePart.end(nil)))

        XCTAssertNoThrow(try connectPromise.futureResult.wait())
    }

    func testProxyConnectWithAuthorization() {
        let embedded = EmbeddedChannel()

        let socketAddress = try! SocketAddress.makeAddressResolvingHost("localhost", port: 3000)
        XCTAssertNoThrow(try embedded.connect(to: socketAddress).wait())

        let connectPromise = embedded.eventLoop.makePromise(of: Void.self)
        let proxyConnectHandler = HTTP1ProxyConnectHandler(
            targetHost: "swift.org",
            targetPort: 443,
            proxyAuthorization: .basic(credentials: "abc123"),
            connectPromise: connectPromise
        )

        XCTAssertNoThrow(try embedded.pipeline.syncOperations.addHandler(proxyConnectHandler))

        var maybeHead: HTTPClientRequestPart?
        XCTAssertNoThrow(maybeHead = try embedded.readOutbound(as: HTTPClientRequestPart.self))
        guard case .some(.head(let head)) = maybeHead else {
            return XCTFail("Expected the proxy connect handler to first send a http head part")
        }

        XCTAssertEqual(head.method, .CONNECT)
        XCTAssertEqual(head.uri, "swift.org:443")
        XCTAssertEqual(head.headers["proxy-authorization"].first, "Basic abc123")
        XCTAssertEqual(try embedded.readOutbound(as: HTTPClientRequestPart.self), .end(nil))

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok)
        XCTAssertNoThrow(try embedded.writeInbound(HTTPClientResponsePart.head(responseHead)))
        XCTAssertNoThrow(try embedded.writeInbound(HTTPClientResponsePart.end(nil)))

        connectPromise.succeed(())
    }

    func testProxyConnectWithoutAuthorizationFailure500() {
        let embedded = EmbeddedChannel()

        let socketAddress = try! SocketAddress.makeAddressResolvingHost("localhost", port: 3000)
        XCTAssertNoThrow(try embedded.connect(to: socketAddress).wait())

        let connectPromise = embedded.eventLoop.makePromise(of: Void.self)
        let proxyConnectHandler = HTTP1ProxyConnectHandler(
            targetHost: "swift.org",
            targetPort: 443,
            proxyAuthorization: .none,
            connectPromise: connectPromise
        )

        XCTAssertNoThrow(try embedded.pipeline.syncOperations.addHandler(proxyConnectHandler))

        var maybeHead: HTTPClientRequestPart?
        XCTAssertNoThrow(maybeHead = try embedded.readOutbound(as: HTTPClientRequestPart.self))
        guard case .some(.head(let head)) = maybeHead else {
            return XCTFail("Expected the proxy connect handler to first send a http head part")
        }

        XCTAssertEqual(head.method, .CONNECT)
        XCTAssertEqual(head.uri, "swift.org:443")
        XCTAssertNil(head.headers["proxy-authorization"].first)
        XCTAssertEqual(try embedded.readOutbound(as: HTTPClientRequestPart.self), .end(nil))

        let responseHead = HTTPResponseHead(version: .http1_1, status: .internalServerError)
        XCTAssertNoThrow(try embedded.writeInbound(HTTPClientResponsePart.head(responseHead)))
        XCTAssertEqual(embedded.isActive, false)
        XCTAssertNoThrow(try embedded.writeInbound(HTTPClientResponsePart.end(nil)))

        XCTAssertThrowsError(try connectPromise.futureResult.wait()) { error in
            XCTAssertEqual(error as? HTTPClientError, .invalidProxyResponse)
        }
    }

    func testProxyConnectWithoutAuthorizationButAuthorizationNeeded() {
        let embedded = EmbeddedChannel()

        let socketAddress = try! SocketAddress.makeAddressResolvingHost("localhost", port: 3000)
        XCTAssertNoThrow(try embedded.connect(to: socketAddress).wait())

        let connectPromise = embedded.eventLoop.makePromise(of: Void.self)
        let proxyConnectHandler = HTTP1ProxyConnectHandler(
            targetHost: "swift.org",
            targetPort: 443,
            proxyAuthorization: .none,
            connectPromise: connectPromise
        )

        XCTAssertNoThrow(try embedded.pipeline.syncOperations.addHandler(proxyConnectHandler))

        var maybeHead: HTTPClientRequestPart?
        XCTAssertNoThrow(maybeHead = try embedded.readOutbound(as: HTTPClientRequestPart.self))
        guard case .some(.head(let head)) = maybeHead else {
            return XCTFail("Expected the proxy connect handler to first send a http head part")
        }

        XCTAssertEqual(head.method, .CONNECT)
        XCTAssertEqual(head.uri, "swift.org:443")
        XCTAssertNil(head.headers["proxy-authorization"].first)
        XCTAssertEqual(try embedded.readOutbound(as: HTTPClientRequestPart.self), .end(nil))

        let responseHead = HTTPResponseHead(version: .http1_1, status: .proxyAuthenticationRequired)
        XCTAssertNoThrow(try embedded.writeInbound(HTTPClientResponsePart.head(responseHead)))
        XCTAssertEqual(embedded.isActive, false)
        XCTAssertNoThrow(try embedded.writeInbound(HTTPClientResponsePart.end(nil)))

        XCTAssertThrowsError(try connectPromise.futureResult.wait()) { error in
            XCTAssertEqual(error as? HTTPClientError, .proxyAuthenticationRequired)
        }
    }

    func testProxyConnectReceivesBody() {
        let embedded = EmbeddedChannel()

        let socketAddress = try! SocketAddress.makeAddressResolvingHost("localhost", port: 3000)
        XCTAssertNoThrow(try embedded.connect(to: socketAddress).wait())

        let connectPromise = embedded.eventLoop.makePromise(of: Void.self)
        let proxyConnectHandler = HTTP1ProxyConnectHandler(
            targetHost: "swift.org",
            targetPort: 443,
            proxyAuthorization: .none,
            connectPromise: connectPromise
        )

        XCTAssertNoThrow(try embedded.pipeline.syncOperations.addHandler(proxyConnectHandler))

        var maybeHead: HTTPClientRequestPart?
        XCTAssertNoThrow(maybeHead = try embedded.readOutbound(as: HTTPClientRequestPart.self))
        guard case .some(.head(let head)) = maybeHead else {
            return XCTFail("Expected the proxy connect handler to first send a http head part")
        }

        XCTAssertEqual(head.method, .CONNECT)
        XCTAssertEqual(head.uri, "swift.org:443")
        XCTAssertEqual(try embedded.readOutbound(as: HTTPClientRequestPart.self), .end(nil))

        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok)
        XCTAssertNoThrow(try embedded.writeInbound(HTTPClientResponsePart.head(responseHead)))
        XCTAssertNoThrow(try embedded.writeInbound(HTTPClientResponsePart.body(ByteBuffer(bytes: [0, 1, 2, 3]))))
        XCTAssertEqual(embedded.isActive, false)
        XCTAssertNoThrow(try embedded.writeInbound(HTTPClientResponsePart.end(nil)))

        XCTAssertThrowsError(try connectPromise.futureResult.wait()) { error in
            XCTAssertEqual(error as? HTTPClientError, .invalidProxyResponse)
        }
    }
}
