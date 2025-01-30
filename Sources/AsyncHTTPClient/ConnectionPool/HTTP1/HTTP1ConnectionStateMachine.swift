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
        enum FinalSuccessfulStreamAction {
            /// Close the connection
            case close
            /// If the server has replied, with a status of 200...300 before all data was sent, a request is considered succeeded,
            /// as soon as we wrote the request end onto the wire.
            ///
            /// The promise is an optional write promise.
            ///
            /// `shouldClose` records whether we have attached a Connection: close header to this request, and so the connection should
            /// be terminated
            case sendRequestEnd(EventLoopPromise<Void>?, shouldClose: Bool)
            /// Inform an observer that the connection has become idle
            case informConnectionIsIdle
        }

        /// A action to execute, when we consider a request "done".
        enum FinalFailedStreamAction {
            /// Close the connection
            ///
            /// The promise is an optional write promise.
            case close(EventLoopPromise<Void>?)
            /// Inform an observer that the connection has become idle
            case informConnectionIsIdle
            /// Fail the write promise
            case failWritePromise(EventLoopPromise<Void>?)
            /// Do nothing.
            case none
        }

        case sendRequestHead(HTTPRequestHead, sendEnd: Bool)
        case notifyRequestHeadSendSuccessfully(
            resumeRequestBodyStream: Bool,
            startIdleTimer: Bool
        )
        case sendBodyPart(IOData, EventLoopPromise<Void>?)
        case sendRequestEnd(EventLoopPromise<Void>?)
        case failSendBodyPart(Error, EventLoopPromise<Void>?)
        case failSendStreamFinished(Error, EventLoopPromise<Void>?)

        case pauseRequestBodyStream
        case resumeRequestBodyStream

        case forwardResponseHead(HTTPResponseHead, pauseRequestBodyStream: Bool)
        case forwardResponseBodyParts(CircularBuffer<ByteBuffer>)

        case failRequest(Error, FinalFailedStreamAction)
        case succeedRequest(FinalSuccessfulStreamAction, CircularBuffer<ByteBuffer>)

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
            fatalError("Invalid state: \(self.state)")
        }
    }

    mutating func channelInactive() -> Action {
        switch self.state {
        case .initialized:
            fatalError("A channel that isn't active, must not become inactive")

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
            fatalError("Invalid state: \(self.state)")
        }
    }

    mutating func errorHappened(_ error: Error) -> Action {
        switch self.state {
        case .initialized:
            self.state = .closed
            return .fireChannelError(error, closeConnection: false)

        case .inRequest(var requestStateMachine, let close):
            return self.avoidingStateMachineCoW { state -> Action in
                let action = requestStateMachine.errorHappened(error)
                state = .inRequest(requestStateMachine, close: close)
                return state.modify(with: action)
            }

        case .idle:
            self.state = .closing
            return .fireChannelError(error, closeConnection: true)

        case .closing, .closed:
            return .fireChannelError(error, closeConnection: false)

        case .modifying:
            fatalError("Invalid state: \(self.state)")
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
            fatalError("Invalid state: \(self.state)")
        }
    }

    mutating func runNewRequest(
        head: HTTPRequestHead,
        metadata: RequestFramingMetadata
    ) -> Action {
        switch self.state {
        case .initialized, .inRequest:
            // These states are unreachable as the connection pool state machine has put the
            // connection into these states. In other words the connection pool state machine must
            // be aware about these states before the connection itself. For this reason the
            // connection pool state machine must not send a new request to the connection, if the
            // connection is `.initialized`, `.closing` or `.inRequest`
            fatalError("Invalid state: \(self.state)")

        case .closing, .closed:
            // The remote may have closed the connection and the connection pool state machine
            // was not updated yet because of a race condition. New request vs. marking connection
            // as closed.
            //
            // TODO: AHC should support a fast rescheduling mechanism here.
            return .failRequest(HTTPClientError.remoteConnectionClosed, .none)

        case .idle:
            var requestStateMachine = HTTPRequestStateMachine(isChannelWritable: self.isChannelWritable)
            let action = requestStateMachine.startRequest(head: head, metadata: metadata)

            // by default we assume a persistent connection. however in `requestVerified`, we read the
            // "connection" header.
            self.state = .inRequest(requestStateMachine, close: metadata.connectionClose)
            return self.state.modify(with: action)

        case .modifying:
            fatalError("Invalid state: \(self.state)")
        }
    }

    mutating func requestStreamPartReceived(_ part: IOData, promise: EventLoopPromise<Void>?) -> Action {
        guard case .inRequest(var requestStateMachine, let close) = self.state else {
            fatalError("Invalid state: \(self.state)")
        }

        return self.avoidingStateMachineCoW { state -> Action in
            let action = requestStateMachine.requestStreamPartReceived(part, promise: promise)
            state = .inRequest(requestStateMachine, close: close)
            return state.modify(with: action)
        }
    }

    mutating func requestStreamFinished(promise: EventLoopPromise<Void>?) -> Action {
        guard case .inRequest(var requestStateMachine, let close) = self.state else {
            fatalError("Invalid state: \(self.state)")
        }

        return self.avoidingStateMachineCoW { state -> Action in
            let action = requestStateMachine.requestStreamFinished(promise: promise)
            state = .inRequest(requestStateMachine, close: close)
            return state.modify(with: action)
        }
    }

    mutating func requestCancelled(closeConnection: Bool) -> Action {
        switch self.state {
        case .initialized:
            fatalError(
                "This event must only happen, if the connection is leased. During startup this is impossible. Invalid state: \(self.state)"
            )

        case .idle:
            if closeConnection {
                self.state = .closing
                return .close
            } else {
                return .wait
            }

        case .inRequest(var requestStateMachine, let close):
            return self.avoidingStateMachineCoW { state -> Action in
                let action = requestStateMachine.requestCancelled()
                state = .inRequest(requestStateMachine, close: close || closeConnection)
                return state.modify(with: action)
            }

        case .closing, .closed:
            return .wait

        case .modifying:
            fatalError("Invalid state: \(self.state)")
        }
    }

    // MARK: - Response

    mutating func read() -> Action {
        switch self.state {
        case .initialized:
            fatalError("Why should we read something, if we are not connected yet")
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
            fatalError("Invalid state: \(self.state)")
        }
    }

    mutating func channelRead(_ part: HTTPClientResponsePart) -> Action {
        switch self.state {
        case .initialized, .idle:
            fatalError("Invalid state: \(self.state)")

        case .inRequest(var requestStateMachine, var close):
            return self.avoidingStateMachineCoW { state -> Action in
                let action = requestStateMachine.channelRead(part)

                if case .head(let head) = part, close == false {
                    // since the HTTPClient does not support protocol switching, we must close any
                    // connection that has received a status `.switchingProtocols`
                    close = !head.isKeepAlive || head.status == .switchingProtocols
                }
                state = .inRequest(requestStateMachine, close: close)
                return state.modify(with: action)
            }

        case .closing, .closed:
            return .wait

        case .modifying:
            fatalError("Invalid state: \(self.state)")
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
            fatalError("Invalid state: \(self.state)")
        }
    }

    mutating func demandMoreResponseBodyParts() -> Action {
        guard case .inRequest(var requestStateMachine, let close) = self.state else {
            fatalError("Invalid state: \(self.state)")
        }

        return self.avoidingStateMachineCoW { state -> Action in
            let action = requestStateMachine.demandMoreResponseBodyParts()
            state = .inRequest(requestStateMachine, close: close)
            return state.modify(with: action)
        }
    }

    mutating func idleReadTimeoutTriggered() -> Action {
        guard case .inRequest(var requestStateMachine, let close) = self.state else {
            fatalError("Invalid state: \(self.state)")
        }

        return self.avoidingStateMachineCoW { state -> Action in
            let action = requestStateMachine.idleReadTimeoutTriggered()
            state = .inRequest(requestStateMachine, close: close)
            return state.modify(with: action)
        }
    }

    mutating func idleWriteTimeoutTriggered() -> Action {
        guard case .inRequest(var requestStateMachine, let close) = self.state else {
            return .wait
        }

        return self.avoidingStateMachineCoW { state -> Action in
            let action = requestStateMachine.idleWriteTimeoutTriggered()
            state = .inRequest(requestStateMachine, close: close)
            return state.modify(with: action)
        }
    }

    mutating func headSent() -> Action {
        guard case .inRequest(var requestStateMachine, let close) = self.state else {
            return .wait
        }
        return self.avoidingStateMachineCoW { state in
            let action = requestStateMachine.headSent()
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
    fileprivate mutating func modify(with action: HTTPRequestStateMachine.Action) -> HTTP1ConnectionStateMachine.Action
    {
        switch action {
        case .sendRequestHead(let head, let sendEnd):
            return .sendRequestHead(head, sendEnd: sendEnd)
        case .notifyRequestHeadSendSuccessfully(let resumeRequestBodyStream, let startIdleTimer):
            return .notifyRequestHeadSendSuccessfully(
                resumeRequestBodyStream: resumeRequestBodyStream,
                startIdleTimer: startIdleTimer
            )
        case .pauseRequestBodyStream:
            return .pauseRequestBodyStream
        case .resumeRequestBodyStream:
            return .resumeRequestBodyStream
        case .sendBodyPart(let part, let writePromise):
            return .sendBodyPart(part, writePromise)
        case .sendRequestEnd(let writePromise):
            return .sendRequestEnd(writePromise)
        case .forwardResponseHead(let head, let pauseRequestBodyStream):
            return .forwardResponseHead(head, pauseRequestBodyStream: pauseRequestBodyStream)
        case .forwardResponseBodyParts(let parts):
            return .forwardResponseBodyParts(parts)
        case .succeedRequest(let finalAction, let finalParts):
            guard case .inRequest(_, close: let close) = self else {
                fatalError("Invalid state: \(self)")
            }

            let newFinalAction: HTTP1ConnectionStateMachine.Action.FinalSuccessfulStreamAction
            switch finalAction {
            case .close:
                self = .closing
                newFinalAction = .close
            case .sendRequestEnd(let writePromise):
                self = .idle
                newFinalAction = .sendRequestEnd(writePromise, shouldClose: close)
            case .none:
                self = .idle
                newFinalAction = close ? .close : .informConnectionIsIdle
            }
            return .succeedRequest(newFinalAction, finalParts)

        case .failRequest(let error, let finalAction):
            switch self {
            case .initialized:
                fatalError("Invalid state: \(self)")
            case .idle:
                fatalError("How can we fail a task, if we are idle")
            case .inRequest(_, let close):
                if case .close(let promise) = finalAction {
                    self = .closing
                    return .failRequest(error, .close(promise))
                } else if close {
                    self = .closing
                    return .failRequest(error, .close(nil))
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
                fatalError("Invalid state: \(self)")
            }

        case .read:
            return .read

        case .wait:
            return .wait

        case .failSendBodyPart(let error, let writePromise):
            return .failSendBodyPart(error, writePromise)

        case .failSendStreamFinished(let error, let writePromise):
            return .failSendStreamFinished(error, writePromise)
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
        case .inRequest(let request, let close):
            return ".inRequest(\(request), closeAfterRequest: \(close))"
        case .closing:
            return ".closing"
        case .closed:
            return ".closed"
        case .modifying:
            fatalError("Invalid state: \(self.state)")
        }
    }
}
