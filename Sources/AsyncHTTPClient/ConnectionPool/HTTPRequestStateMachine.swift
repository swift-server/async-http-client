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
        /// The initial state machine state. The only valid mutation is `start()`. The state will
        /// transitions to:
        ///  - `.waitForChannelToBecomeWritable`
        ///  - `.running(.streaming, .initialized)` (if the Channel is writable and if a request body is expected)
        ///  - `.running(.endSent, .initialized)` (if the Channel is writable and no request body is expected)
        case initialized
        /// Waiting for the channel to be writable. Valid transitions are:
        ///  - `.running(.streaming, .initialized)` (once the Channel is writable again and if a request body is expected)
        ///  - `.running(.endSent, .initialized)` (once the Channel is writable again and no request body is expected)
        ///  - `.failed` (if a connection error occurred)
        case waitForChannelToBecomeWritable(HTTPRequestHead, RequestFramingMetadata)
        /// A request is on the wire. Valid transitions are:
        ///  - `.finished`
        ///  - `.failed`
        case running(RequestState, ResponseState)
        /// The request has completed successfully
        case finished
        /// The request has failed
        case failed(Error)
    }

    /// A sub state for a running request. More specifically for sending a request body.
    fileprivate enum RequestState {
        /// A sub state for sending a request body. Stores whether a producer should produce more
        /// bytes or should pause.
        enum ProducerControlState: String {
            /// The request body producer should produce more body bytes. The channel is writable.
            case producing
            /// The request body producer should pause producing more bytes. The channel is not writable.
            case paused
        }

        /// The request is streaming its request body. `expectedBodyLength` has a value, if the request header contained
        /// a `"content-length"` header field. If the request header contained a `"transfer-encoding" = "chunked"`
        /// header field, the `expectedBodyLength` is `nil`.
        case streaming(expectedBodyLength: Int?, sentBodyBytes: Int, producer: ProducerControlState)
        /// The request has sent its request body and end.
        case endSent
    }

    fileprivate enum ResponseState {
        /// A sub state for receiving a response. Stores whether the consumer has either signaled demand for more data or
        /// is busy consuming the so far forwarded bytes
        enum ConsumerControlState {
            /// the state machine is in this state once it has passed down a request head or body part. If a read event
            /// occurs while in this state, the readPending flag will be set true. If the consumer signals more demand
            /// by invoking `forwardMoreBodyParts`, the state machine will forward the read event.
            case downstreamIsConsuming(readPending: Bool)
            /// the state machine is in this state once the consumer has signaled more demand by invoking
            /// `forwardMoreBodyParts`. If a read event occurs in this state the read event will be forwarded
            /// immediately.
            case downstreamHasDemand
        }

        /// A response head has not been received yet.
        case waitingForHead
        /// A response head has been received and we are ready to consume more data off the wire
        case receivingBody(HTTPResponseHead, ConsumerControlState)
        /// A response end has been received. We don't expect more bytes from the wire.
        case endReceived
    }

    enum Action {
        /// A action to execute, when we consider a request "done".
        enum FinalStreamAction {
            /// Close the connection
            case close
            /// Trigger a read event
            case read
            /// Do nothing. This is action is used, if the request failed, before we the request head was written onto the wire.
            /// This might happen if the request is cancelled, or the request failed the soundness check.
            case none
        }

        case sendRequestHead(HTTPRequestHead, startBody: Bool)
        case sendBodyPart(IOData)
        /// If the server has replied, with a status of 200...300 before all data was sent, a request is considered succeeded,
        /// as soon as we wrote the request end onto the wire. In this case the succeedRequest property is set.
        case sendRequestEnd(succeedRequest: FinalStreamAction?)

        case pauseRequestBodyStream
        case resumeRequestBodyStream

        case forwardResponseHead(HTTPResponseHead, pauseRequestBodyStream: Bool)
        case forwardResponseBodyPart(ByteBuffer)

        case failRequest(Error, FinalStreamAction)
        case succeedRequest(FinalStreamAction)

        case read
        case wait
    }

    private var state: State = .initialized

    private var isChannelWritable: Bool

    init(isChannelWritable: Bool) {
        self.isChannelWritable = isChannelWritable
    }

    mutating func startRequest(head: HTTPRequestHead, metadata: RequestFramingMetadata) -> Action {
        guard case .initialized = self.state else {
            preconditionFailure("`start()` must be called first, and exactly once. Invalid state: \(self.state)")
        }

        guard self.isChannelWritable else {
            self.state = .waitForChannelToBecomeWritable(head, metadata)
            return .wait
        }

        return self.startSendingRequest(head: head, metadata: metadata)
    }

    mutating func writabilityChanged(writable: Bool) -> Action {
        if writable {
            return self.channelIsWritable()
        } else {
            return self.channelIsNotWritable()
        }
    }

    private mutating func channelIsWritable() -> Action {
        self.isChannelWritable = true

        switch self.state {
        case .initialized,
             .running(.streaming(_, _, producer: .producing), _),
             .running(.endSent, _),
             .finished,
             .failed:
            return .wait

        case .waitForChannelToBecomeWritable(let head, let metadata):
            return self.startSendingRequest(head: head, metadata: metadata)

        case .running(.streaming(_, _, producer: .paused), .receivingBody(let head, _)) where head.status.code >= 300:
            // If we are receiving a response with a status of >= 300, we should not send out
            // further request body parts. The remote already signaled with status >= 300 that it
            // won't be interested. Let's save some bandwidth.
            return .wait

        case .running(.streaming(let expectedBody, let sentBodyBytes, producer: .paused), let responseState):
            let requestState: RequestState = .streaming(
                expectedBodyLength: expectedBody,
                sentBodyBytes: sentBodyBytes,
                producer: .producing
            )

            self.state = .running(requestState, responseState)
            return .resumeRequestBodyStream
        }
    }

    private mutating func channelIsNotWritable() -> Action {
        self.isChannelWritable = false

        switch self.state {
        case .initialized,
             .waitForChannelToBecomeWritable,
             .running(.streaming(_, _, producer: .paused), _),
             .running(.endSent, _),
             .finished,
             .failed:
            return .wait

        case .running(.streaming(let expectedBodyLength, let sentBodyBytes, producer: .producing), let responseState):
            let requestState: RequestState = .streaming(
                expectedBodyLength: expectedBodyLength,
                sentBodyBytes: sentBodyBytes,
                producer: .paused
            )
            self.state = .running(requestState, responseState)
            return .pauseRequestBodyStream
        }
    }

    mutating func readEventCaught() -> Action {
        switch self.state {
        case .initialized,
             .waitForChannelToBecomeWritable,
             .running(_, .waitingForHead),
             .running(_, .endReceived),
             .finished,
             .failed:
            // If we are not in the middle of streaming the response body, we always want to get
            // more data...
            return .read
        case .running(_, .receivingBody(_, .downstreamIsConsuming(readPending: true))):
            // We have caught another `read` event already. We don't need to change the state and
            // we should continue to wait for the consumer to call `forwardMoreBodyParts`
            return .wait
        case .running(let requestState, .receivingBody(let responseHead, .downstreamIsConsuming(readPending: false))):
            self.state = .running(requestState, .receivingBody(responseHead, .downstreamIsConsuming(readPending: true)))
            return .wait
        case .running(_, .receivingBody(_, .downstreamHasDemand)):
            // The consumer has signaled a demand for more response body bytes. If a `read` is
            // caught, we pass it on right away. The state machines does not transition into another
            // state.
            return .read
        }
    }

    mutating func errorHappened(_ error: Error) -> Action {
        switch self.state {
        case .initialized:
            preconditionFailure("After the state machine has been initialized, start must be called immediately. Thus this state is unreachable")
        case .waitForChannelToBecomeWritable:
            // the request failed, before it was sent onto the wire.
            self.state = .failed(error)
            return .failRequest(error, .none)
        case .running:
            self.state = .failed(error)
            return .failRequest(error, .close)
        case .finished, .failed:
            preconditionFailure("If the request is finished or failed, we expect the connection state machine to remove the request immediately from its state. Thus this state is unreachable.")
        }
    }

    mutating func requestStreamPartReceived(_ part: IOData) -> Action {
        switch self.state {
        case .initialized,
             .waitForChannelToBecomeWritable,
             .running(.endSent, _):
            preconditionFailure("We must be in the request streaming phase, if we receive further body parts. Invalid state: \(self.state)")

        case .running(.streaming(_, _, let producerState), .receivingBody(let head, _)) where head.status.code >= 300:
            // If we have already received a response head with status >= 300, we won't send out any
            // further request body bytes. Since the remote signaled with status >= 300, that it
            // won't be interested. We expect that the producer has been informed to pause
            // producing.
            assert(producerState == .paused)
            return .wait

        case .running(.streaming(let expectedBodyLength, var sentBodyBytes, let producerState), let responseState):
            // We don't check the producer state here:
            //
            // No matter if the `producerState` is either `.producing` or `.paused` any bytes we
            // receive shall be forwarded to the Channel right away. As long as we have not received
            // a response with status >= 300.
            //
            // More streamed data is accepted, even though the producer may have been asked to
            // pause. The reason for this is as follows: There might be thread synchronization
            // situations in which the producer might not have received the plea to pause yet.

            if let expected = expectedBodyLength, sentBodyBytes + part.readableBytes > expected {
                let error = HTTPClientError.bodyLengthMismatch

                return .failRequest(error, .close)
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
            // A request may be finished, before we have send all parts. This might be the case if
            // the server responded with an HTTP status code that is equal or larger to 300
            // (Redirection, Client Error or Server Error). In those cases we pause the request body
            // stream as soon as we have received the response head and we succeed the request as
            // when response end is received. This may mean, that we succeed a request, even though
            // we have not sent all it's body parts.

            // We may still receive something, here because of potential race conditions with the
            // producing thread.
            return .wait
        }
    }

    mutating func requestStreamFinished() -> Action {
        switch self.state {
        case .initialized,
             .waitForChannelToBecomeWritable,
             .running(.endSent, _):
            preconditionFailure("A request body stream end is only expected if we are in state request streaming. Invalid state: \(self.state)")

        case .running(.streaming(let expectedBodyLength, let sentBodyBytes, _), .waitingForHead):
            if let expected = expectedBodyLength, expected != sentBodyBytes {
                let error = HTTPClientError.bodyLengthMismatch
                self.state = .failed(error)
                return .failRequest(error, .close)
            }

            self.state = .running(.endSent, .waitingForHead)
            return .sendRequestEnd(succeedRequest: nil)

        case .running(.streaming(let expectedBodyLength, let sentBodyBytes, _), .receivingBody(let head, let streamState)):
            assert(head.status.code < 300)

            if let expected = expectedBodyLength, expected != sentBodyBytes {
                let error = HTTPClientError.bodyLengthMismatch
                self.state = .failed(error)
                return .failRequest(error, .close)
            }

            self.state = .running(.endSent, .receivingBody(head, streamState))
            return .sendRequestEnd(succeedRequest: nil)

        case .running(.streaming(let expectedBodyLength, let sentBodyBytes, _), .endReceived):
            if let expected = expectedBodyLength, expected != sentBodyBytes {
                let error = HTTPClientError.bodyLengthMismatch
                self.state = .failed(error)
                return .failRequest(error, .close)
            }

            self.state = .finished
            return .sendRequestEnd(succeedRequest: .some(.none))

        case .failed:
            return .wait

        case .finished:
            // A request may be finished, before we have send all parts. This might be the case if
            // the server responded with an HTTP status code that is equal or larger to 300
            // (Redirection, Client Error or Server Error). In those cases we pause the request body
            // stream as soon as we have received the response head and we succeed the request as
            // when response end is received. This may mean, that we succeed a request, even though
            // we have not sent all it's body parts.

            // We may still receive something, here because of potential race conditions with the
            // producing thread.
            return .wait
        }
    }

    mutating func requestCancelled() -> Action {
        switch self.state {
        case .initialized, .waitForChannelToBecomeWritable:
            let error = HTTPClientError.cancelled
            self.state = .failed(error)
            return .failRequest(error, .none)
        case .running:
            let error = HTTPClientError.cancelled
            self.state = .failed(error)
            return .failRequest(error, .close)
        case .finished:
            return .wait
        case .failed:
            return .wait
        }
    }

    mutating func channelInactive() -> Action {
        switch self.state {
        case .initialized, .waitForChannelToBecomeWritable, .running:
            let error = HTTPClientError.remoteConnectionClosed
            self.state = .failed(error)
            return .failRequest(error, .none)
        case .finished:
            return .wait
        case .failed:
            // don't overwrite error
            return .wait
        }
    }

    // MARK: - Response

    mutating func receivedHTTPResponseHead(_ head: HTTPResponseHead) -> Action {
        guard head.status.code >= 200 else {
            // we ignore any leading 1xx headers... No state change needed.
            return .wait
        }

        switch self.state {
        case .initialized, .waitForChannelToBecomeWritable:
            preconditionFailure("How can we receive a response head before sending a request head ourselves")

        case .running(.streaming(let expectedBodyLength, let sentBodyBytes, producer: .paused), .waitingForHead):
            self.state = .running(
                .streaming(expectedBodyLength: expectedBodyLength, sentBodyBytes: sentBodyBytes, producer: .paused),
                .receivingBody(head, .downstreamIsConsuming(readPending: false))
            )
            return .forwardResponseHead(head, pauseRequestBodyStream: false)

        case .running(.streaming(let expectedBodyLength, let sentBodyBytes, producer: .producing), .waitingForHead):
            if head.status.code >= 300 {
                self.state = .running(
                    .streaming(expectedBodyLength: expectedBodyLength, sentBodyBytes: sentBodyBytes, producer: .paused),
                    .receivingBody(head, .downstreamIsConsuming(readPending: false))
                )
                return .forwardResponseHead(head, pauseRequestBodyStream: true)
            } else {
                self.state = .running(
                    .streaming(expectedBodyLength: expectedBodyLength, sentBodyBytes: sentBodyBytes, producer: .producing),
                    .receivingBody(head, .downstreamIsConsuming(readPending: false))
                )
                return .forwardResponseHead(head, pauseRequestBodyStream: false)
            }

        case .running(.endSent, .waitingForHead):
            self.state = .running(.endSent, .receivingBody(head, .downstreamIsConsuming(readPending: false)))
            return .forwardResponseHead(head, pauseRequestBodyStream: false)

        case .running(_, .receivingBody), .running(_, .endReceived), .finished:
            preconditionFailure("How can we successfully finish the request, before having received a head. Invalid state: \(self.state)")
        case .failed:
            return .wait
        }
    }

    mutating func receivedHTTPResponseBodyPart(_ body: ByteBuffer) -> Action {
        switch self.state {
        case .initialized, .waitForChannelToBecomeWritable:
            preconditionFailure("How can we receive a response head before sending a request head ourselves. Invalid state: \(self.state)")

        case .running(_, .waitingForHead):
            preconditionFailure("How can we receive a response body, if we haven't received a head. Invalid state: \(self.state)")

        case .running(let requestState, .receivingBody(let head, .downstreamHasDemand)):
            self.state = .running(requestState, .receivingBody(head, .downstreamIsConsuming(readPending: false)))
            return .forwardResponseBodyPart(body)

        case .running(_, .receivingBody(_, .downstreamIsConsuming)):
            // the state doesn't need to be changed. we are already in the correct state.
            // just forward the data.
            return .forwardResponseBodyPart(body)

        case .running(_, .endReceived), .finished:
            preconditionFailure("How can we successfully finish the request, before having received a head. Invalid state: \(self.state)")
        case .failed:
            return .wait
        }
    }

    mutating func receivedHTTPResponseEnd() -> Action {
        switch self.state {
        case .initialized, .waitForChannelToBecomeWritable:
            preconditionFailure("How can we receive a response head before sending a request head ourselves. Invalid state: \(self.state)")

        case .running(_, .waitingForHead):
            preconditionFailure("How can we receive a response end, if we haven't a received a head. Invalid state: \(self.state)")

        case .running(.streaming(let expectedBodyLength, let sentBodyBytes, let producerState), .receivingBody(let head, let consumerState)) where head.status.code < 300:
            self.state = .running(
                .streaming(expectedBodyLength: expectedBodyLength, sentBodyBytes: sentBodyBytes, producer: producerState),
                .endReceived
            )

            switch consumerState {
            case .downstreamHasDemand, .downstreamIsConsuming(readPending: false):
                return .wait
            case .downstreamIsConsuming(readPending: true):
                // If we have a received a read event before, we must ensure that the read event
                // eventually gets onto the channel pipeline again. The end of the request gives
                // us an opportunity for this clean up task.
                // It is very unlikely that we can see this in the real world. If we have swallowed
                // a read event we don't expect to receive further data from the channel incl.
                // response ends.

                return .read
            }

        case .running(.streaming(_, _, let producerState), .receivingBody(let head, _)):
            assert(head.status.code >= 300)
            assert(producerState == .paused, "Expected to have paused the request body stream, when the head was received. Invalid state: \(self.state)")
            self.state = .finished
            return .succeedRequest(.close)

        case .running(.endSent, .receivingBody(_, .downstreamIsConsuming(readPending: true))):
            // If we have a received a read event before, we must ensure that the read event
            // eventually gets onto the channel pipeline again. The end of the request gives
            // us an opportunity for this clean up task.
            // It is very unlikely that we can see this in the real world. If we have swallowed
            // a read event we don't expect to receive further data from the channel incl.
            // response ends.
            self.state = .finished
            return .succeedRequest(.read)

        case .running(.endSent, .receivingBody(_, .downstreamIsConsuming(readPending: false))),
             .running(.endSent, .receivingBody(_, .downstreamHasDemand)):
            self.state = .finished
            return .succeedRequest(.none)

        case .running(_, .endReceived), .finished:
            preconditionFailure("How can we receive a response end, if another one was already received. Invalid state: \(self.state)")
        case .failed:
            return .wait
        }
    }

    mutating func forwardMoreBodyParts() -> Action {
        switch self.state {
        case .initialized,
             .running(_, .waitingForHead),
             .waitForChannelToBecomeWritable:
            preconditionFailure("The response is expected to only ask for more data after the response head was forwarded")
        case .running(let requestState, .receivingBody(let head, .downstreamIsConsuming(readPending: false))):
            self.state = .running(requestState, .receivingBody(head, .downstreamHasDemand))
            return .wait
        case .running(let requestState, .receivingBody(let head, .downstreamIsConsuming(readPending: true))):
            self.state = .running(requestState, .receivingBody(head, .downstreamIsConsuming(readPending: false)))
            return .read
        case .running(_, .receivingBody(_, .downstreamHasDemand)):
            // We have received a request for more data before. Normally we only expect one request
            // for more data, but a race can come into play here.
            return .wait
        case .running(_, .endReceived),
             .finished,
             .failed:
            return .wait
        }
    }

    mutating func idleReadTimeoutTriggered() -> Action {
        switch self.state {
        case .initialized,
             .waitForChannelToBecomeWritable,
             .running(.streaming, _):
            preconditionFailure("We only schedule idle read timeouts after we have sent the complete request. Invalid state: \(self.state)")

        case .running(.endSent, .waitingForHead), .running(.endSent, .receivingBody):
            let error = HTTPClientError.readTimeout
            self.state = .failed(error)
            return .failRequest(error, .close)

        case .running(.endSent, .endReceived):
            preconditionFailure("Invalid state. This state should be: .finished")

        case .finished, .failed:
            return .wait
        }
    }

    private mutating func startSendingRequest(head: HTTPRequestHead, metadata: RequestFramingMetadata) -> Action {
        switch metadata.body {
        case .stream:
            self.state = .running(.streaming(expectedBodyLength: nil, sentBodyBytes: 0, producer: .producing), .waitingForHead)
            return .sendRequestHead(head, startBody: true)
        case .fixedSize(let length) where length > 0:
            self.state = .running(.streaming(expectedBodyLength: length, sentBodyBytes: 0, producer: .producing), .waitingForHead)
            return .sendRequestHead(head, startBody: true)
        case .none, .fixedSize:
            // fallback if fixed size is 0
            self.state = .running(.endSent, .waitingForHead)
            return .sendRequestHead(head, startBody: false)
        }
    }
}

extension HTTPRequestStateMachine: CustomStringConvertible {
    var description: String {
        switch self.state {
        case .initialized:
            return "HTTPRequestStateMachine(.initialized, isWritable: \(self.isChannelWritable))"
        case .waitForChannelToBecomeWritable:
            return "HTTPRequestStateMachine(.waitForChannelToBecomeWritable, isWritable: \(self.isChannelWritable))"
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
        case .streaming(expectedBodyLength: let expected, let sent, producer: let producer):
            return ".streaming(sent: \(expected != nil ? String(expected!) : "-"), sent: \(sent), producer: \(producer)"
        case .endSent:
            return ".endSent"
        }
    }
}

extension HTTPRequestStateMachine.ResponseState: CustomStringConvertible {
    var description: String {
        switch self {
        case .waitingForHead:
            return ".waitingForHead"
        case .receivingBody(let head, let streamState):
            return ".receivingBody(\(head), streamState: \(streamState))"
        case .endReceived:
            return ".endReceived"
        }
    }
}
