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

import NIO
import NIOHTTP1

struct HTTP1ConnectionStateMachine {
    enum State {
        case initialized
        case idle
        case inRequest(HTTPRequestStateMachine, close: Bool)
        case closing
        case closed
    }

    enum Action {
        case verifyRequest

        case sendRequestHead(HTTPRequestHead, startBody: Bool, startReadTimeoutTimer: TimeAmount?)
        case sendBodyPart(IOData)
        case sendRequestEnd(startReadTimeoutTimer: TimeAmount?)

        case pauseRequestBodyStream
        case resumeRequestBodyStream

        case forwardResponseHead(HTTPResponseHead)
        case forwardResponseBodyPart(ByteBuffer, resetReadTimeoutTimer: TimeAmount?)
        case forwardResponseEnd(readPending: Bool, clearReadTimeoutTimer: Bool, closeConnection: Bool)
        case forwardError(Error, closeConnection: Bool, fireChannelError: Bool)

        case fireChannelActive
        case fireChannelInactive
        case fireChannelError(Error, closeConnection: Bool)
        case read
        case close
        case wait
    }

    var state: State
    var isChannelWritable: Bool = true

    init() {
        self.state = .initialized
    }

    #if DEBUG
        /// for tests only
        init(state: State) {
            self.state = state
        }
    #endif

    mutating func channelActive(isWritable: Bool) -> Action {
        switch self.state {
        case .initialized:
            self.isChannelWritable = isWritable
            self.state = .idle
            return .fireChannelActive
        case .idle, .inRequest, .closing, .closed:
            // Since NIO triggers promise before pipeline, the handler might have been added to the
            // pipeline, before the channelActive callback was triggered. For this reason, we might
            // get the channelActive call twice
            return .wait
        }
    }

    mutating func channelInactive() -> Action {
        switch self.state {
        case .initialized:
            preconditionFailure("Invalid state")

        case .inRequest(var requestStateMachine, close: _):
            self.state = .closed
            return self.modify(with: requestStateMachine.channelInactive())

        case .idle, .closing:
            self.state = .closed
            return .fireChannelInactive

        case .closed:
            return .wait
        }
    }

    mutating func errorHappened(_ error: Error) -> Action {
        switch self.state {
        case .initialized:
            self.state = .closed
            return .fireChannelError(error, closeConnection: false)

        case .inRequest(var requestStateMachine, close: _):
            self.state = .closed
            return self.modify(with: requestStateMachine.errorHappened(error))

        case .idle:
            self.state = .closing
            return .fireChannelError(error, closeConnection: true)

        case .closing:
            return .fireChannelError(error, closeConnection: false)

        case .closed:
            return .fireChannelError(error, closeConnection: false)
        }
    }

    mutating func writabilityChanged(writable: Bool) -> Action {
        self.isChannelWritable = writable

        switch self.state {
        case .initialized, .idle, .closing, .closed:
            return .wait
        case .inRequest(var requestStateMachine, _):
            return self.modify(with: requestStateMachine.writabilityChanged(writable: writable))
        }
    }

    mutating func readEventCaught() -> Action {
        switch self.state {
        case .initialized:
            preconditionFailure("Why should we read something, if we are not connected yet")
        case .idle:
            return .read
        case .inRequest(var requestStateMachine, _):
            return self.modify(with: requestStateMachine.readEventCaught())
        case .closing, .closed:
            // there might be a race in us closing the connection and receiving another read event
            return .read
        }
    }

    mutating func runNewRequest(idleReadTimeout: TimeAmount?) -> Action {
        guard case .idle = self.state else {
            preconditionFailure("Invalid state")
        }

        var requestStateMachine = HTTPRequestStateMachine(
            isChannelWritable: self.isChannelWritable,
            idleReadTimeout: idleReadTimeout
        )
        let action = requestStateMachine.start()

        // by default we assume a persistent connection. however in `requestVerified`, we read the
        // "connection" header.
        self.state = .inRequest(requestStateMachine, close: false)
        return self.modify(with: action)
    }

    mutating func requestVerified(_ head: HTTPRequestHead) -> Action {
        guard case .inRequest(var requestStateMachine, _) = self.state else {
            preconditionFailure("Invalid state")
        }
        let action = requestStateMachine.requestVerified(head)

        let closeAfterRequest = head.headers[canonicalForm: "connection"].contains(where: { $0.lowercased() == "close" })

        self.state = .inRequest(requestStateMachine, close: closeAfterRequest)
        return self.modify(with: action)
    }

    mutating func requestVerificationFailed(_ error: Error) -> Action {
        guard case .inRequest(var requestStateMachine, _) = self.state else {
            preconditionFailure("Invalid state")
        }

        return self.modify(with: requestStateMachine.requestVerificationFailed(error))
    }

    mutating func requestStreamPartReceived(_ part: IOData) -> Action {
        guard case .inRequest(var requestStateMachine, let close) = self.state else {
            preconditionFailure("Invalid state")
        }
        let action = requestStateMachine.requestStreamPartReceived(part)
        self.state = .inRequest(requestStateMachine, close: close)
        return self.modify(with: action)
    }

    mutating func requestStreamFinished() -> Action {
        guard case .inRequest(var requestStateMachine, let close) = self.state else {
            preconditionFailure("Invalid state")
        }
        let action = requestStateMachine.requestStreamFinished()
        self.state = .inRequest(requestStateMachine, close: close)
        return self.modify(with: action)
    }

    mutating func requestCancelled() -> Action {
        guard case .inRequest(var requestStateMachine, _) = self.state else {
            preconditionFailure("Invalid state: \(self.state)")
        }
        let action = requestStateMachine.requestCancelled()
        return self.modify(with: action)
    }

    mutating func cancelRequestForClose() -> Action {
        switch self.state {
        case .initialized:
            preconditionFailure("This event must only happen, if the connection is leased. During startup this is impossible")
        case .idle:
            self.state = .closing
            return .close
        case .inRequest(var requestStateMachine, close: _):
            let action = self.modify(with: requestStateMachine.requestCancelled())
            return action
        case .closing:
            return .wait
        case .closed:
            return .wait
        }
    }

    // MARK: - Response

    mutating func receivedHTTPResponseHead(_ head: HTTPResponseHead) -> Action {
        switch self.state {
        case .initialized:
            preconditionFailure("Invalid state")
        case .inRequest(var requestStateMachine, let close):
            let action = requestStateMachine.receivedHTTPResponseHead(head)
            let closeAfterRequest = close || head.headers[canonicalForm: "connection"].contains(where: { $0.lowercased() == "close" })

            self.state = .inRequest(requestStateMachine, close: closeAfterRequest)
            return self.modify(with: action)
        case .idle:
            preconditionFailure("Invalid state")
        case .closing, .closed:
            return .wait
        }
    }

    mutating func receivedHTTPResponseBodyPart(_ body: ByteBuffer) -> Action {
        switch self.state {
        case .initialized:
            preconditionFailure("Invalid state")
        case .inRequest(var requestStateMachine, let close):
            let action = requestStateMachine.receivedHTTPResponseBodyPart(body)
            self.state = .inRequest(requestStateMachine, close: close)
            return self.modify(with: action)
        case .idle:
            preconditionFailure("Invalid state")
        case .closing, .closed:
            return .wait
        }
    }

    mutating func receivedHTTPResponseEnd() -> Action {
        switch self.state {
        case .initialized:
            preconditionFailure("Invalid state")
        case .inRequest(var requestStateMachine, let close):
            let action = requestStateMachine.receivedHTTPResponseEnd()
            self.state = .inRequest(requestStateMachine, close: close)
            return self.modify(with: action)
        case .idle:
            preconditionFailure("Invalid state")
        case .closing, .closed:
            return .wait
        }
    }

    mutating func forwardMoreBodyParts() -> Action {
        guard case .inRequest(var requestStateMachine, let close) = self.state else {
            preconditionFailure("Invalid state: \(self.state)")
        }
        let action = requestStateMachine.forwardMoreBodyParts()
        self.state = .inRequest(requestStateMachine, close: close)
        return self.modify(with: action)
    }

    mutating func idleReadTimeoutTriggered() -> Action {
        guard case .inRequest(var requestStateMachine, let close) = self.state else {
            preconditionFailure("Invalid state: \(self.state)")
        }
        let action = requestStateMachine.idleReadTimeoutTriggered()
        self.state = .inRequest(requestStateMachine, close: close)
        return self.modify(with: action)
    }
}

extension HTTP1ConnectionStateMachine {
    mutating func modify(with action: HTTPRequestStateMachine.Action) -> Action {
        switch action {
        case .verifyRequest:
            return .verifyRequest
        case .sendRequestHead(let head, let startBody, let startReadTimeoutTimer):
            return .sendRequestHead(head, startBody: startBody, startReadTimeoutTimer: startReadTimeoutTimer)
        case .pauseRequestBodyStream:
            return .pauseRequestBodyStream
        case .resumeRequestBodyStream:
            return .resumeRequestBodyStream
        case .sendBodyPart(let part):
            return .sendBodyPart(part)
        case .sendRequestEnd(let startReadTimeoutTimer):
            return .sendRequestEnd(startReadTimeoutTimer: startReadTimeoutTimer)
        case .forwardResponseHead(let head):
            return .forwardResponseHead(head)
        case .forwardResponseBodyPart(let part, let resetReadTimeoutTimer):
            return .forwardResponseBodyPart(part, resetReadTimeoutTimer: resetReadTimeoutTimer)
        case .forwardResponseEnd(let readPending, let clearReadTimeoutTimer):
            guard case .inRequest(_, close: let close) = self.state else {
                preconditionFailure("Invalid state")
            }

            if close {
                self.state = .closed
            } else {
                self.state = .idle
            }
            return .forwardResponseEnd(readPending: readPending, clearReadTimeoutTimer: clearReadTimeoutTimer, closeConnection: close)
        case .read:
            return .read

        case .failRequest(let error, closeStream: let closeStream):
            switch self.state {
            case .initialized:
                preconditionFailure("Invalid state")
            case .idle:
                preconditionFailure("How can we fail a task, if we are idle")
            case .inRequest(_, close: let close):
                if close || closeStream {
                    self.state = .closing
                    return .forwardError(error, closeConnection: true, fireChannelError: false)
                } else {
                    self.state = .idle
                    return .forwardError(error, closeConnection: false, fireChannelError: false)
                }

            case .closing:
                return .forwardError(error, closeConnection: false, fireChannelError: false)
            case .closed:
                // this state can be reached, if the connection was unexpectedly closed by remote
                return .forwardError(error, closeConnection: false, fireChannelError: false)
            }

        case .wait:
            return .wait
        }
    }
}

extension HTTP1ConnectionStateMachine: CustomStringConvertible {
    var description: String {
        switch self.state {
        case .initialized:
            return ".initialized"
        case .idle:
            return ".idle"
        case .inRequest(let request, close: let close):
            return ".inRequest(\(request), closeAfterRequest: \(close))"
        case .closing:
            return ".closing"
        case .closed:
            return ".closed"
        }
    }
}
