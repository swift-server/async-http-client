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

import Logging
import NIOCore
import NIOEmbedded
import NIOHTTP2
import XCTest

@testable import AsyncHTTPClient

class HTTP2IdleHandlerTests: XCTestCase {
    func testReceiveSettingsWithMaxConcurrentStreamSetting() {
        let delegate = MockHTTP2IdleHandlerDelegate()
        let idleHandler = HTTP2IdleHandler(delegate: delegate, logger: Logger(label: "test"))
        let embedded = EmbeddedChannel(handlers: [idleHandler])
        XCTAssertNoThrow(try embedded.connect(to: .makeAddressResolvingHost("localhost", port: 0)).wait())

        let settingsFrame = HTTP2Frame(
            streamID: 0,
            payload: .settings(.settings([.init(parameter: .maxConcurrentStreams, value: 10)]))
        )
        XCTAssertEqual(delegate.maxStreams, nil)
        XCTAssertNoThrow(try embedded.writeInbound(settingsFrame))
        XCTAssertEqual(delegate.maxStreams, 10)
    }

    func testReceiveSettingsWithoutMaxConcurrentStreamSetting() {
        let delegate = MockHTTP2IdleHandlerDelegate()
        let idleHandler = HTTP2IdleHandler(delegate: delegate, logger: Logger(label: "test"))
        let embedded = EmbeddedChannel(handlers: [idleHandler])
        XCTAssertNoThrow(try embedded.connect(to: .makeAddressResolvingHost("localhost", port: 0)).wait())

        let settingsFrame = HTTP2Frame(streamID: 0, payload: .settings(.settings([])))
        XCTAssertEqual(delegate.maxStreams, nil)
        XCTAssertNoThrow(try embedded.writeInbound(settingsFrame))
        XCTAssertEqual(
            delegate.maxStreams,
            100,
            "Expected to assume 100 maxConcurrentConnection, if no setting was present"
        )
    }

    func testEmptySettingsDontOverwriteMaxConcurrentStreamSetting() {
        let delegate = MockHTTP2IdleHandlerDelegate()
        let idleHandler = HTTP2IdleHandler(delegate: delegate, logger: Logger(label: "test"))
        let embedded = EmbeddedChannel(handlers: [idleHandler])
        XCTAssertNoThrow(try embedded.connect(to: .makeAddressResolvingHost("localhost", port: 0)).wait())

        let settingsFrame = HTTP2Frame(
            streamID: 0,
            payload: .settings(.settings([.init(parameter: .maxConcurrentStreams, value: 10)]))
        )
        XCTAssertEqual(delegate.maxStreams, nil)
        XCTAssertNoThrow(try embedded.writeInbound(settingsFrame))
        XCTAssertEqual(delegate.maxStreams, 10)

        let emptySettings = HTTP2Frame(streamID: 0, payload: .settings(.settings([])))
        XCTAssertNoThrow(try embedded.writeInbound(emptySettings))
        XCTAssertEqual(delegate.maxStreams, 10)
    }

    func testOverwriteMaxConcurrentStreamSetting() {
        let delegate = MockHTTP2IdleHandlerDelegate()
        let idleHandler = HTTP2IdleHandler(delegate: delegate, logger: Logger(label: "test"))
        let embedded = EmbeddedChannel(handlers: [idleHandler])
        XCTAssertNoThrow(try embedded.connect(to: .makeAddressResolvingHost("localhost", port: 0)).wait())

        let settingsFrame = HTTP2Frame(
            streamID: 0,
            payload: .settings(.settings([.init(parameter: .maxConcurrentStreams, value: 10)]))
        )
        XCTAssertEqual(delegate.maxStreams, nil)
        XCTAssertNoThrow(try embedded.writeInbound(settingsFrame))
        XCTAssertEqual(delegate.maxStreams, 10)

        let emptySettings = HTTP2Frame(
            streamID: 0,
            payload: .settings(.settings([.init(parameter: .maxConcurrentStreams, value: 20)]))
        )
        XCTAssertNoThrow(try embedded.writeInbound(emptySettings))
        XCTAssertEqual(delegate.maxStreams, 20)
    }

    func testGoAwayReceivedBeforeSettings() {
        let delegate = MockHTTP2IdleHandlerDelegate()
        let idleHandler = HTTP2IdleHandler(delegate: delegate, logger: Logger(label: "test"))
        let embedded = EmbeddedChannel(handlers: [idleHandler])
        XCTAssertNoThrow(try embedded.connect(to: .makeAddressResolvingHost("localhost", port: 0)).wait())

        let randomStreamID = HTTP2StreamID((0..<Int32.max).randomElement()!)
        let goAwayFrame = HTTP2Frame(
            streamID: randomStreamID,
            payload: .goAway(lastStreamID: 0, errorCode: .http11Required, opaqueData: nil)
        )
        XCTAssertEqual(delegate.goAwayReceived, false)
        XCTAssertNoThrow(try embedded.writeInbound(goAwayFrame))
        XCTAssertEqual(delegate.goAwayReceived, true)
        XCTAssertEqual(delegate.maxStreams, nil)

        var inbound: HTTP2Frame?
        XCTAssertNoThrow(inbound = try embedded.readInbound(as: HTTP2Frame.self))
        XCTAssertEqual(randomStreamID, inbound?.streamID)
    }

    func testGoAwayReceivedAfterSettings() {
        let delegate = MockHTTP2IdleHandlerDelegate()
        let idleHandler = HTTP2IdleHandler(delegate: delegate, logger: Logger(label: "test"))
        let embedded = EmbeddedChannel(handlers: [idleHandler])
        XCTAssertNoThrow(try embedded.connect(to: .makeAddressResolvingHost("localhost", port: 0)).wait())

        let settingsFrame = HTTP2Frame(
            streamID: 0,
            payload: .settings(.settings([.init(parameter: .maxConcurrentStreams, value: 10)]))
        )
        XCTAssertEqual(delegate.maxStreams, nil)
        XCTAssertNoThrow(try embedded.writeInbound(settingsFrame))
        XCTAssertEqual(delegate.maxStreams, 10)

        let randomStreamID = HTTP2StreamID((0..<Int32.max).randomElement()!)
        let goAwayFrame = HTTP2Frame(
            streamID: randomStreamID,
            payload: .goAway(lastStreamID: 0, errorCode: .http11Required, opaqueData: nil)
        )
        XCTAssertEqual(delegate.goAwayReceived, false)
        XCTAssertNoThrow(try embedded.writeInbound(goAwayFrame))
        XCTAssertEqual(delegate.goAwayReceived, true)
        XCTAssertEqual(delegate.maxStreams, 10)

        var settingsInbound: HTTP2Frame?
        XCTAssertNoThrow(settingsInbound = try embedded.readInbound(as: HTTP2Frame.self))
        XCTAssertEqual(0, settingsInbound?.streamID)

        var goAwayInbound: HTTP2Frame?
        XCTAssertNoThrow(goAwayInbound = try embedded.readInbound(as: HTTP2Frame.self))
        XCTAssertEqual(randomStreamID, goAwayInbound?.streamID)
    }

    func testCloseEventBeforeFirstSettings() {
        let delegate = MockHTTP2IdleHandlerDelegate()
        let idleHandler = HTTP2IdleHandler(delegate: delegate, logger: Logger(label: "test"))
        let embedded = EmbeddedChannel(handlers: [idleHandler])
        XCTAssertNoThrow(try embedded.connect(to: .makeAddressResolvingHost("localhost", port: 0)).wait())

        XCTAssertTrue(embedded.isActive)
        embedded.pipeline.triggerUserOutboundEvent(HTTPConnectionEvent.shutdownRequested, promise: nil)
        XCTAssertFalse(embedded.isActive)
    }

    func testCloseEventWhileNoOpenStreams() {
        let delegate = MockHTTP2IdleHandlerDelegate()
        let idleHandler = HTTP2IdleHandler(delegate: delegate, logger: Logger(label: "test"))
        let embedded = EmbeddedChannel(handlers: [idleHandler])
        XCTAssertNoThrow(try embedded.connect(to: .makeAddressResolvingHost("localhost", port: 0)).wait())

        let settingsFrame = HTTP2Frame(
            streamID: 0,
            payload: .settings(.settings([.init(parameter: .maxConcurrentStreams, value: 10)]))
        )
        XCTAssertEqual(delegate.maxStreams, nil)
        XCTAssertNoThrow(try embedded.writeInbound(settingsFrame))
        XCTAssertEqual(delegate.maxStreams, 10)

        XCTAssertTrue(embedded.isActive)
        embedded.pipeline.triggerUserOutboundEvent(HTTPConnectionEvent.shutdownRequested, promise: nil)
        XCTAssertFalse(embedded.isActive)
    }

    func testCloseEventWhileThereAreOpenStreams() {
        let delegate = MockHTTP2IdleHandlerDelegate()
        let idleHandler = HTTP2IdleHandler(delegate: delegate, logger: Logger(label: "test"))
        let embedded = EmbeddedChannel(handlers: [idleHandler])
        XCTAssertNoThrow(try embedded.connect(to: .makeAddressResolvingHost("localhost", port: 0)).wait())

        let settingsFrame = HTTP2Frame(
            streamID: 0,
            payload: .settings(.settings([.init(parameter: .maxConcurrentStreams, value: 10)]))
        )
        XCTAssertEqual(delegate.maxStreams, nil)
        XCTAssertNoThrow(try embedded.writeInbound(settingsFrame))
        XCTAssertEqual(delegate.maxStreams, 10)

        var openStreams = Set<HTTP2StreamID>()

        for i in 0..<(1...100).randomElement()! {
            let streamID = HTTP2StreamID(i)
            let event = NIOHTTP2StreamCreatedEvent(
                streamID: streamID,
                localInitialWindowSize: nil,
                remoteInitialWindowSize: nil
            )
            embedded.pipeline.fireUserInboundEventTriggered(event)
            openStreams.insert(streamID)
        }

        embedded.pipeline.triggerUserOutboundEvent(HTTPConnectionEvent.shutdownRequested, promise: nil)
        XCTAssertTrue(embedded.isActive)

        while let streamID = openStreams.randomElement() {
            openStreams.remove(streamID)

            let event = StreamClosedEvent(streamID: streamID, reason: nil)
            XCTAssertTrue(embedded.isActive)
            embedded.pipeline.fireUserInboundEventTriggered(event)
            if openStreams.isEmpty {
                XCTAssertFalse(embedded.isActive)
            } else {
                XCTAssertTrue(embedded.isActive)
            }
        }
    }

    func testGoAwayWhileThereAreOpenStreams() {
        let delegate = MockHTTP2IdleHandlerDelegate()
        let idleHandler = HTTP2IdleHandler(delegate: delegate, logger: Logger(label: "test"))
        let embedded = EmbeddedChannel(handlers: [idleHandler])
        XCTAssertNoThrow(try embedded.connect(to: .makeAddressResolvingHost("localhost", port: 0)).wait())

        let settingsFrame = HTTP2Frame(
            streamID: 0,
            payload: .settings(.settings([.init(parameter: .maxConcurrentStreams, value: 10)]))
        )
        XCTAssertEqual(delegate.maxStreams, nil)
        XCTAssertNoThrow(try embedded.writeInbound(settingsFrame))
        XCTAssertEqual(delegate.maxStreams, 10)

        var openStreams = Set<HTTP2StreamID>()

        for i in 0..<(1...100).randomElement()! {
            let streamID = HTTP2StreamID(i)
            let event = NIOHTTP2StreamCreatedEvent(
                streamID: streamID,
                localInitialWindowSize: nil,
                remoteInitialWindowSize: nil
            )
            embedded.pipeline.fireUserInboundEventTriggered(event)
            openStreams.insert(streamID)
        }

        let goAwayStreamID = HTTP2StreamID(openStreams.count)
        let goAwayFrame = HTTP2Frame(
            streamID: goAwayStreamID,
            payload: .goAway(lastStreamID: 0, errorCode: .http11Required, opaqueData: nil)
        )
        XCTAssertEqual(delegate.goAwayReceived, false)
        XCTAssertNoThrow(try embedded.writeInbound(goAwayFrame))
        XCTAssertEqual(delegate.goAwayReceived, true)
        XCTAssertEqual(delegate.maxStreams, 10)

        while let streamID = openStreams.randomElement() {
            openStreams.remove(streamID)

            let event = StreamClosedEvent(streamID: streamID, reason: nil)
            XCTAssertTrue(embedded.isActive)
            embedded.pipeline.fireUserInboundEventTriggered(event)
            if openStreams.isEmpty {
                XCTAssertFalse(embedded.isActive)
            } else {
                XCTAssertTrue(embedded.isActive)
            }
        }
    }

    func testReceiveSettingsAndGoAwayAfterClientSideClose() {
        let delegate = MockHTTP2IdleHandlerDelegate()
        let idleHandler = HTTP2IdleHandler(delegate: delegate, logger: Logger(label: "test"))
        let embedded = EmbeddedChannel(handlers: [idleHandler])
        XCTAssertNoThrow(try embedded.connect(to: .makeAddressResolvingHost("localhost", port: 0)).wait())

        let settingsFrame = HTTP2Frame(
            streamID: 0,
            payload: .settings(.settings([.init(parameter: .maxConcurrentStreams, value: 10)]))
        )
        XCTAssertEqual(delegate.maxStreams, nil)
        XCTAssertNoThrow(try embedded.writeInbound(settingsFrame))
        XCTAssertEqual(delegate.maxStreams, 10)

        XCTAssertTrue(embedded.isActive)
        embedded.pipeline.triggerUserOutboundEvent(HTTPConnectionEvent.shutdownRequested, promise: nil)
        XCTAssertFalse(embedded.isActive)

        let newSettingsFrame = HTTP2Frame(
            streamID: 0,
            payload: .settings(.settings([.init(parameter: .maxConcurrentStreams, value: 20)]))
        )
        XCTAssertEqual(delegate.maxStreams, 10)
        XCTAssertNoThrow(try embedded.writeInbound(newSettingsFrame))
        XCTAssertEqual(delegate.maxStreams, 10, "Expected message to not be forwarded.")

        let goAwayFrame = HTTP2Frame(
            streamID: HTTP2StreamID(0),
            payload: .goAway(lastStreamID: 2, errorCode: .http11Required, opaqueData: nil)
        )
        XCTAssertEqual(delegate.goAwayReceived, false)
        XCTAssertNoThrow(try embedded.writeInbound(goAwayFrame))
        XCTAssertEqual(delegate.goAwayReceived, false, "Expected go away to not be forwarded.")
    }

    func testConnectionUseLimitTriggersGoAway() {
        let delegate = MockHTTP2IdleHandlerDelegate()
        let idleHandler = HTTP2IdleHandler(delegate: delegate, logger: Logger(label: "test"), maximumConnectionUses: 5)
        let embedded = EmbeddedChannel(handlers: [idleHandler])
        XCTAssertNoThrow(try embedded.connect(to: .makeAddressResolvingHost("localhost", port: 0)).wait())

        let settingsFrame = HTTP2Frame(
            streamID: 0,
            payload: .settings(.settings([.init(parameter: .maxConcurrentStreams, value: 100)]))
        )
        XCTAssertEqual(delegate.maxStreams, nil)
        XCTAssertNoThrow(try embedded.writeInbound(settingsFrame))
        XCTAssertEqual(delegate.maxStreams, 100)

        for streamID in HTTP2StreamID(1)..<HTTP2StreamID(5) {
            let event = NIOHTTP2StreamCreatedEvent(
                streamID: streamID,
                localInitialWindowSize: nil,
                remoteInitialWindowSize: nil
            )
            embedded.pipeline.fireUserInboundEventTriggered(event)
            XCTAssertFalse(delegate.goAwayReceived)
        }

        // Open one the last stream.
        let event = NIOHTTP2StreamCreatedEvent(
            streamID: HTTP2StreamID(5),
            localInitialWindowSize: nil,
            remoteInitialWindowSize: nil
        )
        embedded.pipeline.fireUserInboundEventTriggered(event)
        XCTAssertTrue(delegate.goAwayReceived)

        // Close the streams.
        for streamID in HTTP2StreamID(1)...HTTP2StreamID(5) {
            let event = StreamClosedEvent(streamID: streamID, reason: nil)
            embedded.pipeline.fireUserInboundEventTriggered(event)
        }

        // The channel should be closed, but we need to run the event loop for the close future
        // to complete.
        embedded.embeddedEventLoop.run()
        XCTAssertNoThrow(try embedded.closeFuture.wait())
    }
}

class MockHTTP2IdleHandlerDelegate: HTTP2IdleHandlerDelegate {
    private(set) var maxStreams: Int?
    private(set) var goAwayReceived: Bool = false

    private(set) var streamClosedHitCount: Int = 0

    func http2SettingsReceived(maxStreams: Int) {
        self.maxStreams = maxStreams
    }

    func http2GoAwayReceived() {
        self.goAwayReceived = true
    }

    func http2StreamClosed(availableStreams: Int) {
        self.streamClosedHitCount += 1
    }
}
