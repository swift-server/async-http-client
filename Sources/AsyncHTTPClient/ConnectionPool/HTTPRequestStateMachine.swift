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

struct HTTPRequestStateMachine {
    fileprivate enum State {
        case initialized
        case running(RequestState, ResponseState)
        case finished

        case failed(Error)
    }

    fileprivate enum RequestState {
        enum ExpectedBody {
            case length(Int)
            case stream
        }

        enum ProducerControlState: Equatable {
            case producing
            case paused
        }

        case verifyRequest
        case streaming(expectedBodyLength: Int?, sentBodyBytes: Int, producer: ProducerControlState)
        case endSent
    }

    fileprivate enum ResponseState {
        enum StreamControlState {
            case downstreamHasDemand
            case readEventPending
            case waiting
        }

        case initialized
        case receivingBody(StreamControlState)
        case endReceived
    }

    enum Action {
        enum NextMessageToSend {
            case sendEnd
            case startBodyStream
        }

        case verifyRequest

        case sendRequestHead(HTTPRequestHead, startBody: Bool, startReadTimeoutTimer: TimeAmount?)
        case sendBodyPart(IOData)
        case sendRequestEnd(startReadTimeoutTimer: TimeAmount?)

        case pauseRequestBodyStream
        case resumeRequestBodyStream

        case forwardResponseHead(HTTPResponseHead)
        case forwardResponseBodyPart(ByteBuffer, resetReadTimeoutTimer: TimeAmount?)
        case forwardResponseEnd(readPending: Bool, clearReadTimeoutTimer: Bool)

        case failRequest(Error, closeStream: Bool)

        case read
        case wait
    }

    private var state: State = .initialized

    private var isChannelWritable: Bool
    private let idleReadTimeout: TimeAmount?

    init(isChannelWritable: Bool, idleReadTimeout: TimeAmount?) {
        self.isChannelWritable = isChannelWritable
        self.idleReadTimeout = idleReadTimeout
    }

    mutating func writabilityChanged(writable: Bool) -> Action {
        self.isChannelWritable = writable

        switch self.state {
        case .initialized,
             .finished,
             .failed:
            return .wait

        case .running(.verifyRequest, _), .running(.endSent, _):
            return .wait

        case .running(.streaming(let expectedBody, let sentBodyBytes, producer: .paused), let responseState):
            if writable {
                let requestState: RequestState = .streaming(
                    expectedBodyLength: expectedBody,
                    sentBodyBytes: sentBodyBytes,
                    producer: .producing
                )

                self.state = .running(requestState, responseState)
                return .resumeRequestBodyStream
            } else {
                // no state change needed
                return .wait
            }

        case .running(.streaming(let expectedBodyLength, let sentBodyBytes, producer: .producing), let responseState):
            if !writable {
                let requestState: RequestState = .streaming(
                    expectedBodyLength: expectedBodyLength,
                    sentBodyBytes: sentBodyBytes,
                    producer: .paused
                )
                self.state = .running(requestState, responseState)
                return .pauseRequestBodyStream
            } else {
                // no state change needed
                return .wait
            }
        }
    }

    mutating func readEventCaught() -> Action {
        return .read
    }

    mutating func errorHappened(_ error: Error) -> Action {
        switch self.state {
        case .initialized:
            preconditionFailure("After the state machine has been initialized, start must be called immediately. Thus this state is unreachable")
        case .running:
            self.state = .failed(error)
            return .failRequest(error, closeStream: true)
        case .finished, .failed:
            preconditionFailure("If the request is finished or failed, we expect the connection state machine to remove the request immediately from its state. Thus this state is unreachable.")
        }
    }

    mutating func start() -> Action {
        guard case .initialized = self.state else {
            preconditionFailure("Invalid state")
        }

        self.state = .running(.verifyRequest, .initialized)
        return .verifyRequest
    }

    mutating func requestVerified(_ head: HTTPRequestHead) -> Action {
        guard case .running(.verifyRequest, .initialized) = self.state else {
            preconditionFailure("Invalid state")
        }

        guard self.isChannelWritable else {
            preconditionFailure("Unimplemented. Wait with starting the request here!")
        }

        if let value = head.headers.first(name: "content-length"), let length = Int(value), length > 0 {
            self.state = .running(.streaming(expectedBodyLength: length, sentBodyBytes: 0, producer: .producing), .initialized)
            return .sendRequestHead(head, startBody: true, startReadTimeoutTimer: nil)
        } else if head.headers.contains(name: "transfer-encoding") {
            self.state = .running(.streaming(expectedBodyLength: nil, sentBodyBytes: 0, producer: .producing), .initialized)
            return .sendRequestHead(head, startBody: true, startReadTimeoutTimer: nil)
        } else {
            self.state = .running(.endSent, .initialized)
            return .sendRequestHead(head, startBody: false, startReadTimeoutTimer: self.idleReadTimeout)
        }
    }

    mutating func requestVerificationFailed(_ error: Error) -> Action {
        guard case .running(.verifyRequest, .initialized) = self.state else {
            preconditionFailure("Invalid state")
        }

        self.state = .failed(error)
        return .failRequest(error, closeStream: false)
    }

    mutating func requestStreamPartReceived(_ part: IOData) -> Action {
        switch self.state {
        case .initialized:
            preconditionFailure("Invalid state: \(self.state)")

        case .running(.verifyRequest, _),
             .running(.endSent, _):
            preconditionFailure("Invalid state: \(self.state)")

        case .running(.streaming(let expectedBodyLength, var sentBodyBytes, let producerState), let responseState):
            // More streamed data is accepted, even though the producer should stop. However
            // there might be thread syncronisations situations in which the producer might not
            // be aware that it needs to stop yet.

            if let expected = expectedBodyLength {
                if sentBodyBytes + part.readableBytes > expected {
                    let error = HTTPClientError.bodyLengthMismatch

                    switch responseState {
                    case .initialized, .receivingBody:
                        self.state = .failed(error)
                    case .endReceived:
                        #warning("TODO: This needs to be fixed. @Cory: What does this mean here?")
                        preconditionFailure("Unimplemented")
                    }

                    return .failRequest(error, closeStream: true)
                }
            }

            sentBodyBytes += part.readableBytes

            let requestState: RequestState = .streaming(
                expectedBodyLength: expectedBodyLength,
                sentBodyBytes: sentBodyBytes,
                producer: producerState
            )

            self.state = .running(requestState, responseState)

            return .sendBodyPart(part)

        case .failed:
            return .wait

        case .finished:
            // a request may be finished, before we send all parts. We may still receive something
            // here because of a thread race
            return .wait
        }
    }

    mutating func requestStreamFinished() -> Action {
        switch self.state {
        case .initialized:
            preconditionFailure("Invalid state")
        case .running(.streaming(let expectedBodyLength, let sentBodyBytes, _), let responseState):
            if let expected = expectedBodyLength, expected != sentBodyBytes {
                let error = HTTPClientError.bodyLengthMismatch

                switch responseState {
                case .initialized, .receivingBody:
                    self.state = .failed(error)
                case .endReceived:
                    #warning("TODO: This needs to be fixed. @Cory: What does this mean here?")
                    preconditionFailure("Unimplemented")
                }

                return .failRequest(error, closeStream: true)
            }

            self.state = .running(.endSent, responseState)
            return .sendRequestEnd(startReadTimeoutTimer: self.idleReadTimeout)

        case .running(.verifyRequest, _),
             .running(.endSent, _):
            preconditionFailure("Invalid state")

        case .finished:
            return .wait

        case .failed:
            return .wait
        }
    }

    mutating func requestCancelled() -> Action {
        switch self.state {
        case .initialized, .running:
            let error = HTTPClientError.cancelled
            self.state = .failed(error)
            return .failRequest(error, closeStream: true)
        case .finished:
            return .wait
        case .failed:
            return .wait
        }
    }

    mutating func channelInactive() -> Action {
        switch self.state {
        case .initialized, .running:
            let error = HTTPClientError.remoteConnectionClosed
            self.state = .failed(error)
            return .failRequest(error, closeStream: false)
        case .finished:
            return .wait
        case .failed:
            // don't overwrite error
            return .wait
        }
    }

    // MARK: - Response

    mutating func receivedHTTPResponseHead(_ head: HTTPResponseHead) -> Action {
        switch self.state {
        case .initialized:
            preconditionFailure("How can we receive a response head before sending a request head ourselves")

        case .running(let requestState, .initialized):
            switch requestState {
            case .verifyRequest:
                preconditionFailure("How can we receive a response head before sending a request head ourselves")
            case .streaming, .endSent:
                break
            }

            self.state = .running(requestState, .receivingBody(.waiting))
            return .forwardResponseHead(head)

        case .running(_, .receivingBody), .running(_, .endReceived), .finished:
            preconditionFailure("How can we sucessfully finish the request, before having received a head")
        case .failed:
            return .wait
        }
    }

    mutating func receivedHTTPResponseBodyPart(_ body: ByteBuffer) -> Action {
        switch self.state {
        case .initialized:
            preconditionFailure("How can we receive a response head before sending a request head ourselves")

        case .running(_, .initialized):
            preconditionFailure("How can we receive a response body, if we haven't received a head")

        case .running(let requestState, .receivingBody(let streamState)):
            switch streamState {
            case .waiting, .readEventPending:
                break
            case .downstreamHasDemand:
                self.state = .running(requestState, .receivingBody(.waiting))
            }

            return .forwardResponseBodyPart(body, resetReadTimeoutTimer: self.idleReadTimeout)

        case .running(_, .endReceived), .finished:
            preconditionFailure("How can we sucessfully finish the request, before having received a head")
        case .failed:
            return .wait
        }
    }

    mutating func receivedHTTPResponseEnd() -> Action {
        switch self.state {
        case .initialized:
            preconditionFailure("How can we receive a response head before sending a request head ourselves")

        case .running(_, .initialized):
            preconditionFailure("How can we receive a response body, if we haven't a received a head")

        case .running(.streaming, .receivingBody(let streamState)):
            preconditionFailure("Unimplemented")
            #warning("@Fabian: We received response end, before sending our own request's end.")

        case .running(.endSent, .receivingBody(let streamState)):
            let readPending: Bool
            switch streamState {
            case .readEventPending:
                readPending = true
            case .downstreamHasDemand, .waiting:
                readPending = false
            }

            self.state = .finished
            return .forwardResponseEnd(readPending: readPending, clearReadTimeoutTimer: self.idleReadTimeout != nil)

        case .running(.verifyRequest, .receivingBody),
             .running(_, .endReceived), .finished:
            preconditionFailure("invalid state")
        case .failed:
            return .wait
        }
    }

    mutating func forwardMoreBodyParts() -> Action {
        guard case .running(let requestState, .receivingBody(let streamControl)) = self.state else {
            preconditionFailure("Invalid state")
        }

        switch streamControl {
        case .waiting:
            self.state = .running(requestState, .receivingBody(.downstreamHasDemand))
            return .wait
        case .readEventPending:
            self.state = .running(requestState, .receivingBody(.waiting))
            return .read
        case .downstreamHasDemand:
            // We have received a request for more data before. Normally we only expect one request
            // for more data, but a race can come into play here.
            return .wait
        }
    }

    mutating func idleReadTimeoutTriggered() -> Action {
        guard case .running(.endSent, let responseState) = self.state else {
            preconditionFailure("We only schedule idle read timeouts after we have sent the complete request")
        }

        if case .endReceived = responseState {
            preconditionFailure("Invalid state: If we have received everything, we must not schedule further timeout timers")
        }

        let error = HTTPClientError.readTimeout
        self.state = .failed(error)
        return .failRequest(error, closeStream: true)
    }
}

extension HTTPRequestStateMachine: CustomStringConvertible {
    var description: String {
        switch self.state {
        case .initialized:
            return "HTTPRequestStateMachine(.initialized, isWritable: \(self.isChannelWritable))"
        case .running(let requestState, let responseState):
            return "HTTPRequestStateMachine(.running(request: \(requestState), response: \(responseState)), isWritable: \(self.isChannelWritable))"
        case .finished:
            return "HTTPRequestStateMachine(.finished, isWritable: \(self.isChannelWritable))"
        case .failed(let error):
            return "HTTPRequestStateMachine(.failed(\(error)), isWritable: \(self.isChannelWritable))"
        }
    }
}

extension HTTPRequestStateMachine.RequestState: CustomStringConvertible {
    var description: String {
        switch self {
        case .verifyRequest:
            return ".verifyRequest"
        case .streaming(expectedBodyLength: let expected, let sent, producer: let producer):
            return ".sendingHead(sent: \(expected != nil ? String(expected!) : "-"), sent: \(sent), producer: \(producer)"
        case .endSent:
            return ".endSent"
        }
    }
}

extension HTTPRequestStateMachine.RequestState.ProducerControlState {
    var description: String {
        switch self {
        case .paused:
            return ".paused"
        case .producing:
            return ".producing"
        }
    }
}

extension HTTPRequestStateMachine.ResponseState: CustomStringConvertible {
    var description: String {
        switch self {
        case .initialized:
            return ".initialized"
        case .receivingBody(let streamState):
            return ".receivingBody(streamState: \(streamState))"
        case .endReceived:
            return ".endReceived"
        }
    }
}
