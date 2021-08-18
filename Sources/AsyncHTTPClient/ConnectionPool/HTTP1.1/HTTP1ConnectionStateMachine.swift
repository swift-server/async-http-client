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
import NIOHTTP1

struct HTTP1ConnectionStateMachine {
    fileprivate enum State {
        case initialized
        case idle
        case inRequest(HTTPRequestStateMachine, close: Bool)
        case closing
        case closed

        case modifying
    }

    enum Action {
        /// A action to execute, when we consider a request "done".
        enum FinalStreamAction {
            /// Close the connection
            case close
            /// If the server has replied, with a status of 200...300 before all data was sent, a request is considered succeeded,
            /// as soon as we wrote the request end onto the wire.
            case sendRequestEnd
            /// Inform an observer that the connection has become idle
            case informConnectionIsIdle
            /// Do nothing.
            case none
        }

        case sendRequestHead(HTTPRequestHead, startBody: Bool)
        case sendBodyPart(IOData)
        case sendRequestEnd

        case pauseRequestBodyStream
        case resumeRequestBodyStream

        case forwardResponseHead(HTTPResponseHead, pauseRequestBodyStream: Bool)
        case forwardResponseBodyParts(CircularBuffer<ByteBuffer>)

        case failRequest(Error, FinalStreamAction)
        case succeedRequest(FinalStreamAction, CircularBuffer<ByteBuffer>)

        case read
        case close
        case wait

        case fireChannelActive
        case fireChannelInactive
        case fireChannelError(Error, closeConnection: Bool)
    }

    private var state: State
    private var isChannelWritable: Bool = true

    init() {
        self.state = .initialized
    }

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

        case .modifying:
            preconditionFailure("Invalid state: \(self.state)")
        }
    }

    mutating func channelInactive() -> Action {
        switch self.state {
        case .initialized:
            preconditionFailure("A channel that isn't active, must not become inactive")

        case .inRequest(var requestStateMachine, close: _):
            return self.avoidingStateMachineCoW { state -> Action in
                let action = requestStateMachine.channelInactive()
                state = .closed
                return state.modify(with: action)
            }

        case .idle, .closing:
            self.state = .closed
            return .fireChannelInactive

        case .closed:
            return .wait

        case .modifying:
            preconditionFailure("Invalid state: \(self.state)")
        }
    }

    mutating func errorHappened(_ error: Error) -> Action {
        switch self.state {
        case .initialized:
            self.state = .closed
            return .fireChannelError(error, closeConnection: false)

        case .inRequest(var requestStateMachine, close: _):
            return self.avoidingStateMachineCoW { state -> Action in
                let action = requestStateMachine.errorHappened(error)
                state = .closed
                return state.modify(with: action)
            }

        case .idle:
            self.state = .closing
            return .fireChannelError(error, closeConnection: true)

        case .closing, .closed:
            return .fireChannelError(error, closeConnection: false)

        case .modifying:
            preconditionFailure("Invalid state: \(self.state)")
        }
    }

    mutating func writabilityChanged(writable: Bool) -> Action {
        self.isChannelWritable = writable

        switch self.state {
        case .initialized, .idle, .closing, .closed:
            return .wait
        case .inRequest(var requestStateMachine, let close):
            return self.avoidingStateMachineCoW { state -> Action in
                let action = requestStateMachine.writabilityChanged(writable: writable)
                state = .inRequest(requestStateMachine, close: close)
                return state.modify(with: action)
            }

        case .modifying:
            preconditionFailure("Invalid state: \(self.state)")
        }
    }

    mutating func runNewRequest(head: HTTPRequestHead, metadata: RequestFramingMetadata) -> Action {
        guard case .idle = self.state else {
            preconditionFailure("Invalid state")
        }

        var requestStateMachine = HTTPRequestStateMachine(
            isChannelWritable: self.isChannelWritable
        )
        let action = requestStateMachine.startRequest(head: head, metadata: metadata)

        // by default we assume a persistent connection. however in `requestVerified`, we read the
        // "connection" header.
        self.state = .inRequest(requestStateMachine, close: metadata.connectionClose)
        return self.state.modify(with: action)
    }

    mutating func requestStreamPartReceived(_ part: IOData) -> Action {
        guard case .inRequest(var requestStateMachine, let close) = self.state else {
            preconditionFailure("Invalid state")
        }

        return self.avoidingStateMachineCoW { state -> Action in
            let action = requestStateMachine.requestStreamPartReceived(part)
            state = .inRequest(requestStateMachine, close: close)
            return state.modify(with: action)
        }
    }

    mutating func requestStreamFinished() -> Action {
        guard case .inRequest(var requestStateMachine, let close) = self.state else {
            preconditionFailure("Invalid state")
        }

        return self.avoidingStateMachineCoW { state -> Action in
            let action = requestStateMachine.requestStreamFinished()
            state = .inRequest(requestStateMachine, close: close)
            return state.modify(with: action)
        }
    }

    mutating func requestCancelled(closeConnection: Bool) -> Action {
        switch self.state {
        case .initialized:
            preconditionFailure("This event must only happen, if the connection is leased. During startup this is impossible")

        case .idle:
            if closeConnection {
                self.state = .closing
                return .close
            } else {
                return .wait
            }

        case .inRequest(var requestStateMachine, close: let close):
            return self.avoidingStateMachineCoW { state -> Action in
                let action = requestStateMachine.requestCancelled()
                state = .inRequest(requestStateMachine, close: close || closeConnection)
                return state.modify(with: action)
            }

        case .closing, .closed:
            return .wait

        case .modifying:
            preconditionFailure("Invalid state: \(self.state)")
        }
    }

    // MARK: - Response

    mutating func read() -> Action {
        switch self.state {
        case .initialized:
            preconditionFailure("Why should we read something, if we are not connected yet")
        case .idle:
            return .read
        case .inRequest(var requestStateMachine, let close):
            return self.avoidingStateMachineCoW { state -> Action in
                let action = requestStateMachine.read()
                state = .inRequest(requestStateMachine, close: close)
                return state.modify(with: action)
            }

        case .closing, .closed:
            // there might be a race in us closing the connection and receiving another read event
            return .read

        case .modifying:
            preconditionFailure("Invalid state: \(self.state)")
        }
    }

    mutating func channelRead(_ part: HTTPClientResponsePart) -> Action {
        switch self.state {
        case .initialized, .idle:
            preconditionFailure("Invalid state")

        case .inRequest(var requestStateMachine, var close):
            return self.avoidingStateMachineCoW { state -> Action in
                let action = requestStateMachine.channelRead(part)

                if case .head(let head) = part, close == false {
                    close = head.headers[canonicalForm: "connection"].contains(where: { $0.lowercased() == "close" })
                }
                state = .inRequest(requestStateMachine, close: close)
                return state.modify(with: action)
            }

        case .closing, .closed:
            return .wait

        case .modifying:
            preconditionFailure("Invalid state: \(self.state)")
        }
    }

    mutating func channelReadComplete() -> Action {
        switch self.state {
        case .initialized, .idle, .closing, .closed:
            return .wait

        case .inRequest(var requestStateMachine, let close):
            return self.avoidingStateMachineCoW { state -> Action in
                let action = requestStateMachine.channelReadComplete()
                state = .inRequest(requestStateMachine, close: close)
                return state.modify(with: action)
            }

        case .modifying:
            preconditionFailure("Invalid state: \(self.state)")
        }
    }

    mutating func demandMoreResponseBodyParts() -> Action {
        guard case .inRequest(var requestStateMachine, let close) = self.state else {
            preconditionFailure("Invalid state: \(self.state)")
        }

        return self.avoidingStateMachineCoW { state -> Action in
            let action = requestStateMachine.demandMoreResponseBodyParts()
            state = .inRequest(requestStateMachine, close: close)
            return state.modify(with: action)
        }
    }

    mutating func idleReadTimeoutTriggered() -> Action {
        guard case .inRequest(var requestStateMachine, let close) = self.state else {
            preconditionFailure("Invalid state: \(self.state)")
        }

        return self.avoidingStateMachineCoW { state -> Action in
            let action = requestStateMachine.idleReadTimeoutTriggered()
            state = .inRequest(requestStateMachine, close: close)
            return state.modify(with: action)
        }
    }
}

extension HTTP1ConnectionStateMachine {
    /// So, uh...this function needs some explaining.
    ///
    /// While the state machine logic above is great, there is a downside to having all of the state machine data in
    /// associated data on enumerations: any modification of that data will trigger copy on write for heap-allocated
    /// data. That means that for _every operation on the state machine_ we will CoW our underlying state, which is
    /// not good.
    ///
    /// The way we can avoid this is by using this helper function. It will temporarily set state to a value with no
    /// associated data, before attempting the body of the function. It will also verify that the state machine never
    /// remains in this bad state.
    ///
    /// A key note here is that all callers must ensure that they return to a good state before they exit.
    ///
    /// Sadly, because it's generic and has a closure, we need to force it to be inlined at all call sites, which is
    /// not ideal.
    @inline(__always)
    private mutating func avoidingStateMachineCoW<ReturnType>(_ body: (inout State) -> ReturnType) -> ReturnType {
        self.state = .modifying
        defer {
            assert(!self.isModifying)
        }

        return body(&self.state)
    }

    private var isModifying: Bool {
        if case .modifying = self.state {
            return true
        } else {
            return false
        }
    }
}

extension HTTP1ConnectionStateMachine.State {
    fileprivate mutating func modify(with action: HTTPRequestStateMachine.Action) -> HTTP1ConnectionStateMachine.Action {
        switch action {
        case .sendRequestHead(let head, let startBody):
            return .sendRequestHead(head, startBody: startBody)
        case .pauseRequestBodyStream:
            return .pauseRequestBodyStream
        case .resumeRequestBodyStream:
            return .resumeRequestBodyStream
        case .sendBodyPart(let part):
            return .sendBodyPart(part)
        case .sendRequestEnd:
            return .sendRequestEnd
        case .forwardResponseHead(let head, let pauseRequestBodyStream):
            return .forwardResponseHead(head, pauseRequestBodyStream: pauseRequestBodyStream)
        case .forwardResponseBodyParts(let parts):
            return .forwardResponseBodyParts(parts)
        case .succeedRequest(let finalAction, let finalParts):
            guard case .inRequest(_, close: let close) = self else {
                preconditionFailure("Invalid state")
            }

            let newFinalAction: HTTP1ConnectionStateMachine.Action.FinalStreamAction
            switch finalAction {
            case .close:
                self = .closing
                newFinalAction = .close
            case .sendRequestEnd:
                newFinalAction = .sendRequestEnd
            case .none:
                self = .idle
                newFinalAction = close ? .close : .informConnectionIsIdle
            }
            return .succeedRequest(newFinalAction, finalParts)

        case .failRequest(let error, let finalAction):
            switch self {
            case .initialized:
                preconditionFailure("Invalid state")
            case .idle:
                preconditionFailure("How can we fail a task, if we are idle")
            case .inRequest(_, close: let close):
                if close || finalAction == .close {
                    self = .closing
                    return .failRequest(error, .close)
                } else {
                    self = .idle
                    return .failRequest(error, .informConnectionIsIdle)
                }

            case .closing:
                return .failRequest(error, .none)
            case .closed:
                // this state can be reached, if the connection was unexpectedly closed by remote
                return .failRequest(error, .none)

            case .modifying:
                preconditionFailure("Invalid state: \(self)")
            }

        case .read:
            return .read

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
        case .modifying:
            preconditionFailure(".modifying")
        }
    }
}
