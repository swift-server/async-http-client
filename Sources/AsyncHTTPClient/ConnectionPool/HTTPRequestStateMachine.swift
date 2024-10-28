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
import NIOSSL

struct HTTPRequestStateMachine {
    fileprivate enum State {
        /// The initial state machine state. The only valid mutation is `start()`. The state will
        /// transitions to:
        ///  - `.waitForChannelToBecomeWritable` (if the channel becomes non writable while sending the header)
        ///  - `.sendingHead` if the channel is writable
        case initialized

        /// Waiting for the channel to be writable. Valid transitions are:
        ///  - `.running(.streaming, .waitingForHead)` (once the Channel is writable again and if a request body is expected)
        ///  - `.running(.endSent, .waitingForHead)` (once the Channel is writable again and no request body is expected)
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

        case modifying
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
        case streaming(expectedBodyLength: Int64?, sentBodyBytes: Int64, producer: ProducerControlState)
        /// The request has sent its request body and end.
        case endSent
    }

    fileprivate enum ResponseState {
        /// A response head has not been received yet.
        case waitingForHead
        /// A response head has been received and we are ready to consume more data off the wire
        case receivingBody(HTTPResponseHead, ResponseStreamState)
        /// A response end has been received. We don't expect more bytes from the wire.
        case endReceived
    }

    enum Action {
        /// A action to execute, when we consider a successful request "done".
        enum FinalSuccessfulRequestAction {
            /// Close the connection
            case close
            /// If the server has replied, with a status of 200...300 before all data was sent, a request is considered succeeded,
            /// as soon as we wrote the request end onto the wire.
            ///
            /// The promise is an optional write promise.
            case sendRequestEnd(EventLoopPromise<Void>?)
            /// Do nothing. This is action is used, if the request failed, before we the request head was written onto the wire.
            /// This might happen if the request is cancelled, or the request failed the soundness check.
            case none
        }

        /// A action to execute, when we consider a failed request "done".
        enum FinalFailedRequestAction {
            /// Close the connection
            case close(EventLoopPromise<Void>?)
            /// Do nothing. This is action is used, if the request failed, before we the request head was written onto the wire.
            /// This might happen if the request is cancelled, or the request failed the soundness check.
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

        case failRequest(Error, FinalFailedRequestAction)
        case succeedRequest(FinalSuccessfulRequestAction, CircularBuffer<ByteBuffer>)

        case read
        case wait
    }

    private var state: State = .initialized

    private var isChannelWritable: Bool

    init(isChannelWritable: Bool) {
        self.isChannelWritable = isChannelWritable
    }

    mutating func startRequest(head: HTTPRequestHead, metadata: RequestFramingMetadata) -> Action {
        switch self.state {
        case .initialized:
            guard self.isChannelWritable else {
                self.state = .waitForChannelToBecomeWritable(head, metadata)
                return .wait
            }
            return self.startSendingRequest(head: head, metadata: metadata)

        case .failed:
            // The request state machine is marked as failed before the request is started, if
            // the request was cancelled before hitting the channel handler. Before `startRequest`
            // is called on the state machine, `willExecuteRequest` is called on
            // `HTTPExecutableRequest`, which might loopback to state machines cancel method.
            return .wait

        case .running, .finished, .waitForChannelToBecomeWritable, .modifying:
            preconditionFailure("`startRequest()` must be called first, and exactly once. Invalid state: \(self.state)")
        }
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

        case .modifying:
            preconditionFailure("Invalid state: \(self.state)")
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

        case .modifying:
            preconditionFailure("Invalid state: \(self.state)")
        }
    }

    mutating func errorHappened(_ error: Error) -> Action {
        if let error = error as? NIOSSLError,
            error == .uncleanShutdown,
            let action = self.handleNIOSSLUncleanShutdownError()
        {
            return action
        }
        switch self.state {
        case .initialized:
            preconditionFailure(
                "After the state machine has been initialized, start must be called immediately. Thus this state is unreachable"
            )
        case .waitForChannelToBecomeWritable:
            // the request failed, before it was sent onto the wire.
            self.state = .failed(error)
            return .failRequest(error, .none)

        case .running:
            self.state = .failed(error)
            return .failRequest(error, .close(nil))

        case .finished, .failed:
            // ignore error
            return .wait

        case .modifying:
            preconditionFailure("Invalid state: \(self.state)")
        }
    }

    private mutating func handleNIOSSLUncleanShutdownError() -> Action? {
        switch self.state {
        case .running(.streaming, .waitingForHead),
            .running(.endSent, .waitingForHead):
            // if we received a NIOSSL.uncleanShutdown before we got an answer we should handle
            // this like a normal connection close. We will receive a call to channelInactive after
            // this error.
            return .wait

        case .running(.streaming, .receivingBody(let responseHead, _)),
            .running(.endSent, .receivingBody(let responseHead, _)):
            // This code is only reachable for request and responses, which we expect to have a body.
            // We depend on logic from the HTTPResponseDecoder here. The decoder will emit an
            // HTTPResponsePart.end right after the HTTPResponsePart.head, for every request with a
            // CONNECT or HEAD method and every response with a 1xx, 204 or 304 response status.
            //
            // For this reason we only need to check the "content-length" or "transfer-encoding"
            // headers here to determine if we are potentially in an EOF terminated response.

            if responseHead.headers.contains(name: "content-length")
                || responseHead.headers.contains(name: "transfer-encoding")
            {
                // If we have already received the response head, the parser will ensure that we
                // receive a complete response, if the content-length or transfer-encoding header
                // was set. In this case we can ignore the NIOSSLError.uncleanShutdown. We will see
                // a HTTPParserError very soon.
                return .wait
            }

            // If the response is EOF terminated, we need to rely on a clean tls shutdown to be sure
            // we have received all necessary bytes. For this reason we forward the uncleanShutdown
            // error to the user.
            self.state = .failed(NIOSSLError.uncleanShutdown)
            return .failRequest(NIOSSLError.uncleanShutdown, .close(nil))

        case .waitForChannelToBecomeWritable, .running, .finished, .failed, .initialized, .modifying:
            return nil
        }
    }

    mutating func requestStreamPartReceived(_ part: IOData, promise: EventLoopPromise<Void>?) -> Action {
        switch self.state {
        case .initialized,
            .waitForChannelToBecomeWritable,
            .running(.endSent, _):
            preconditionFailure(
                "We must be in the request streaming phase, if we receive further body parts. Invalid state: \(self.state)"
            )

        case .running(.streaming(_, _, let producerState), .receivingBody(let head, _)) where head.status.code >= 300:
            // If we have already received a response head with status >= 300, we won't send out any
            // further request body bytes. Since the remote signaled with status >= 300, that it
            // won't be interested. We expect that the producer has been informed to pause
            // producing.
            assert(producerState == .paused)
            return .failSendBodyPart(HTTPClientError.requestStreamCancelled, promise)

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

            if let expected = expectedBodyLength, sentBodyBytes + Int64(part.readableBytes) > expected {
                let error = HTTPClientError.bodyLengthMismatch
                self.state = .failed(error)
                return .failRequest(error, .close(promise))
            }

            sentBodyBytes += Int64(part.readableBytes)

            let requestState: RequestState = .streaming(
                expectedBodyLength: expectedBodyLength,
                sentBodyBytes: sentBodyBytes,
                producer: producerState
            )

            self.state = .running(requestState, responseState)

            return .sendBodyPart(part, promise)

        case .failed(let error):
            return .failSendBodyPart(error, promise)

        case .finished:
            // A request may be finished, before we have send all parts. This might be the case if
            // the server responded with an HTTP status code that is equal or larger to 300
            // (Redirection, Client Error or Server Error). In those cases we pause the request body
            // stream as soon as we have received the response head and we succeed the request as
            // when response end is received. This may mean, that we succeed a request, even though
            // we have not sent all it's body parts.

            // We may still receive something, here because of potential race conditions with the
            // producing thread.
            return .failSendBodyPart(HTTPClientError.requestStreamCancelled, promise)

        case .modifying:
            preconditionFailure("Invalid state: \(self.state)")
        }
    }

    mutating func requestStreamFinished(promise: EventLoopPromise<Void>?) -> Action {
        switch self.state {
        case .initialized,
            .waitForChannelToBecomeWritable,
            .running(.endSent, _):
            preconditionFailure(
                "A request body stream end is only expected if we are in state request streaming. Invalid state: \(self.state)"
            )

        case .running(.streaming(let expectedBodyLength, let sentBodyBytes, _), .waitingForHead):
            if let expected = expectedBodyLength, expected != sentBodyBytes {
                let error = HTTPClientError.bodyLengthMismatch
                self.state = .failed(error)
                return .failRequest(error, .close(promise))
            }

            self.state = .running(.endSent, .waitingForHead)
            return .sendRequestEnd(promise)

        case .running(
            .streaming(let expectedBodyLength, let sentBodyBytes, _),
            .receivingBody(let head, let streamState)
        ):
            assert(head.status.code < 300)

            if let expected = expectedBodyLength, expected != sentBodyBytes {
                let error = HTTPClientError.bodyLengthMismatch
                self.state = .failed(error)
                return .failRequest(error, .close(promise))
            }

            self.state = .running(.endSent, .receivingBody(head, streamState))
            return .sendRequestEnd(promise)

        case .running(.streaming(let expectedBodyLength, let sentBodyBytes, _), .endReceived):
            if let expected = expectedBodyLength, expected != sentBodyBytes {
                let error = HTTPClientError.bodyLengthMismatch
                self.state = .failed(error)
                return .failRequest(error, .close(promise))
            }

            self.state = .finished
            return .succeedRequest(.sendRequestEnd(promise), .init())

        case .failed(let error):
            return .failSendStreamFinished(error, promise)

        case .finished:
            // A request may be finished, before we have send all parts. This might be the case if
            // the server responded with an HTTP status code that is equal or larger to 300
            // (Redirection, Client Error or Server Error). In those cases we pause the request body
            // stream as soon as we have received the response head and we succeed the request as
            // when response end is received. This may mean, that we succeed a request, even though
            // we have not sent all it's body parts.

            // We may still receive something, here because of potential race conditions with the
            // producing thread.
            return .failSendStreamFinished(HTTPClientError.requestStreamCancelled, promise)

        case .modifying:
            preconditionFailure("Invalid state: \(self.state)")
        }
    }

    mutating func requestCancelled() -> Action {
        switch self.state {
        case .initialized, .waitForChannelToBecomeWritable:
            let error = HTTPClientError.cancelled
            self.state = .failed(error)
            // Okay, this has different semantics for HTTP/1 and HTTP/2. In HTTP/1 we don't want to
            // close the connection, if we haven't sent anything yet, to reuse the connection for
            // another request. In HTTP/2 we must close the channel to ensure it is released from
            // HTTP/2 multiplexer.
            return .failRequest(error, .none)

        case .running:
            let error = HTTPClientError.cancelled
            self.state = .failed(error)
            return .failRequest(error, .close(nil))

        case .finished:
            return .wait

        case .failed:
            return .wait

        case .modifying:
            preconditionFailure("Invalid state: \(self.state)")
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

        case .modifying:
            preconditionFailure("Invalid state: \(self.state)")
        }
    }

    // MARK: - Response

    mutating func read() -> Action {
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

        case .running(let requestState, .receivingBody(let head, var streamState)):
            // This should never happen. But we don't want to precondition this behavior. Let's just
            // pass the read event on
            return self.avoidingStateMachineCoW { state -> Action in
                let action = streamState.read()
                state = .running(requestState, .receivingBody(head, streamState))
                return action.toRequestAction()
            }

        case .modifying:
            preconditionFailure("Invalid state: \(self.state)")
        }
    }

    mutating func channelRead(_ part: HTTPClientResponsePart) -> Action {
        switch part {
        case .head(let head):
            return self.receivedHTTPResponseHead(head)
        case .body(let body):
            return self.receivedHTTPResponseBodyPart(body)
        case .end:
            return self.receivedHTTPResponseEnd()
        }
    }

    mutating func channelReadComplete() -> Action {
        switch self.state {
        case .initialized,
            .waitForChannelToBecomeWritable,
            .running(_, .waitingForHead),
            .running(_, .endReceived),
            .finished,
            .failed:
            return .wait

        case .running(let requestState, .receivingBody(let head, var streamState)):
            // This should never happen. But we don't want to precondition this behavior. Let's just
            // pass the read event on
            return self.avoidingStateMachineCoW { state -> Action in
                let buffer = streamState.channelReadComplete()
                state = .running(requestState, .receivingBody(head, streamState))
                if let buffer = buffer {
                    return .forwardResponseBodyParts(buffer)
                } else {
                    return .wait
                }
            }

        case .modifying:
            preconditionFailure("Invalid state: \(self.state)")
        }
    }

    private mutating func receivedHTTPResponseHead(_ head: HTTPResponseHead) -> Action {
        guard head.status.code >= 200 || head.status == .switchingProtocols else {
            // We ignore any leading 1xx headers except for 101 (switching protocols). The
            // HTTP1ConnectionStateMachine ensures the connection close for 101 after the `.end` is
            // received.
            return .wait
        }

        switch self.state {
        case .initialized, .waitForChannelToBecomeWritable:
            preconditionFailure(
                "How can we receive a response head before sending a request head ourselves \(self.state)"
            )

        case .running(.streaming(let expectedBodyLength, let sentBodyBytes, producer: .paused), .waitingForHead):
            self.state = .running(
                .streaming(expectedBodyLength: expectedBodyLength, sentBodyBytes: sentBodyBytes, producer: .paused),
                .receivingBody(head, .init())
            )
            return .forwardResponseHead(head, pauseRequestBodyStream: false)

        case .running(.streaming(let expectedBodyLength, let sentBodyBytes, producer: .producing), .waitingForHead):
            if head.status.code >= 300 {
                self.state = .running(
                    .streaming(expectedBodyLength: expectedBodyLength, sentBodyBytes: sentBodyBytes, producer: .paused),
                    .receivingBody(head, .init())
                )
                return .forwardResponseHead(head, pauseRequestBodyStream: true)
            } else {
                self.state = .running(
                    .streaming(
                        expectedBodyLength: expectedBodyLength,
                        sentBodyBytes: sentBodyBytes,
                        producer: .producing
                    ),
                    .receivingBody(head, .init())
                )
                return .forwardResponseHead(head, pauseRequestBodyStream: false)
            }

        case .running(.endSent, .waitingForHead):
            self.state = .running(.endSent, .receivingBody(head, .init()))
            return .forwardResponseHead(head, pauseRequestBodyStream: false)

        case .running(_, .receivingBody), .running(_, .endReceived), .finished:
            preconditionFailure(
                "How can we successfully finish the request, before having received a head. Invalid state: \(self.state)"
            )
        case .failed:
            return .wait

        case .modifying:
            preconditionFailure("Invalid state: \(self.state)")
        }
    }

    mutating func receivedHTTPResponseBodyPart(_ body: ByteBuffer) -> Action {
        switch self.state {
        case .initialized, .waitForChannelToBecomeWritable:
            preconditionFailure(
                "How can we receive a response head before completely sending a request head ourselves. Invalid state: \(self.state)"
            )

        case .running(_, .waitingForHead):
            preconditionFailure(
                "How can we receive a response body, if we haven't received a head. Invalid state: \(self.state)"
            )

        case .running(let requestState, .receivingBody(let head, var responseStreamState)):
            return self.avoidingStateMachineCoW { state -> Action in
                responseStreamState.receivedBodyPart(body)
                state = .running(requestState, .receivingBody(head, responseStreamState))
                return .wait
            }

        case .running(_, .endReceived), .finished:
            preconditionFailure(
                "How can we successfully finish the request, before having received a head. Invalid state: \(self.state)"
            )

        case .failed:
            return .wait

        case .modifying:
            preconditionFailure("Invalid state: \(self.state)")
        }
    }

    private mutating func receivedHTTPResponseEnd() -> Action {
        switch self.state {
        case .initialized, .waitForChannelToBecomeWritable:
            preconditionFailure(
                "How can we receive a response end before completely sending a request head ourselves. Invalid state: \(self.state)"
            )

        case .running(_, .waitingForHead):
            preconditionFailure(
                "How can we receive a response end, if we haven't a received a head. Invalid state: \(self.state)"
            )

        case .running(
            .streaming(let expectedBodyLength, let sentBodyBytes, let producerState),
            .receivingBody(let head, var responseStreamState)
        )
        where head.status.code < 300:

            return self.avoidingStateMachineCoW { state -> Action in
                let (remainingBuffer, connectionAction) = responseStreamState.end()
                switch connectionAction {
                case .none:
                    state = .running(
                        .streaming(
                            expectedBodyLength: expectedBodyLength,
                            sentBodyBytes: sentBodyBytes,
                            producer: producerState
                        ),
                        .endReceived
                    )
                    return .forwardResponseBodyParts(remainingBuffer)
                case .close:
                    // If we receive a `.close` as a connectionAction from the responseStreamState
                    // this means, that the response end was signaled by a connection close. Since
                    // the request is still uploading, we will not be able to finish the upload. For
                    // this reason we can fail the request here.
                    state = .failed(HTTPClientError.remoteConnectionClosed)
                    return .failRequest(HTTPClientError.remoteConnectionClosed, .close(nil))
                }
            }

        case .running(.streaming(_, _, let producerState), .receivingBody(let head, var responseStreamState)):
            assert(head.status.code >= 300)
            assert(
                producerState == .paused,
                "Expected to have paused the request body stream, when the head was received. Invalid state: \(self.state)"
            )

            return self.avoidingStateMachineCoW { state -> Action in
                // We can ignore the connectionAction from the responseStreamState, since the
                // connection should be closed anyway.
                let (remainingBuffer, _) = responseStreamState.end()
                state = .finished
                return .succeedRequest(.close, remainingBuffer)
            }

        case .running(.endSent, .receivingBody(_, var responseStreamState)):
            return self.avoidingStateMachineCoW { state -> Action in
                let (remainingBuffer, action) = responseStreamState.end()
                state = .finished
                switch action {
                case .none:
                    return .succeedRequest(.none, remainingBuffer)
                case .close:
                    return .succeedRequest(.close, remainingBuffer)
                }
            }

        case .running(_, .endReceived), .finished:
            preconditionFailure(
                "How can we receive a response end, if another one was already received. Invalid state: \(self.state)"
            )

        case .failed:
            return .wait

        case .modifying:
            preconditionFailure("Invalid state: \(self.state)")
        }
    }

    mutating func demandMoreResponseBodyParts() -> Action {
        switch self.state {
        case .initialized,
            .running(_, .waitingForHead),
            .waitForChannelToBecomeWritable:
            preconditionFailure(
                "The response is expected to only ask for more data after the response head was forwarded \(self.state)"
            )

        case .running(let requestState, .receivingBody(let head, var responseStreamState)):
            return self.avoidingStateMachineCoW { state -> Action in
                let action = responseStreamState.demandMoreResponseBodyParts()
                state = .running(requestState, .receivingBody(head, responseStreamState))
                return action.toRequestAction()
            }

        case .running(_, .endReceived),
            .finished,
            .failed:
            return .wait

        case .modifying:
            preconditionFailure("Invalid state: \(self.state)")
        }
    }

    mutating func idleReadTimeoutTriggered() -> Action {
        switch self.state {
        case .initialized,
            .waitForChannelToBecomeWritable,
            .running(.streaming, _):
            preconditionFailure(
                "We only schedule idle read timeouts after we have sent the complete request. Invalid state: \(self.state)"
            )

        case .running(.endSent, .waitingForHead), .running(.endSent, .receivingBody):
            let error = HTTPClientError.readTimeout
            self.state = .failed(error)
            return .failRequest(error, .close(nil))

        case .running(.endSent, .endReceived):
            preconditionFailure("Invalid state. This state should be: .finished")

        case .finished, .failed:
            return .wait

        case .modifying:
            preconditionFailure("Invalid state: \(self.state)")
        }
    }

    mutating func idleWriteTimeoutTriggered() -> Action {
        switch self.state {
        case .initialized,
            .waitForChannelToBecomeWritable:
            preconditionFailure(
                "We only schedule idle write timeouts while the request is being sent. Invalid state: \(self.state)"
            )

        case .running(.streaming, _):
            let error = HTTPClientError.writeTimeout
            self.state = .failed(error)
            return .failRequest(error, .close(nil))

        case .running(.endSent, _):
            preconditionFailure("Invalid state. This state should be: .finished")

        case .finished, .failed:
            return .wait

        case .modifying:
            preconditionFailure("Invalid state: \(self.state)")
        }
    }

    private mutating func startSendingRequest(head: HTTPRequestHead, metadata: RequestFramingMetadata) -> Action {
        let length = metadata.body.expectedLength
        if length == 0 {
            // no body
            self.state = .running(.endSent, .waitingForHead)
            return .sendRequestHead(head, sendEnd: true)
        } else {
            self.state = .running(
                .streaming(expectedBodyLength: length, sentBodyBytes: 0, producer: .paused),
                .waitingForHead
            )
            return .sendRequestHead(head, sendEnd: false)
        }
    }

    mutating func headSent() -> Action {
        switch self.state {
        case .initialized, .waitForChannelToBecomeWritable, .finished:
            preconditionFailure("Not a valid transition after `.sendingHeader`: \(self.state)")

        case .running(.streaming(let expectedBodyLength, let sentBodyBytes, producer: .paused), let responseState):
            let startProducing = self.isChannelWritable && expectedBodyLength != sentBodyBytes
            self.state = .running(
                .streaming(
                    expectedBodyLength: expectedBodyLength,
                    sentBodyBytes: sentBodyBytes,
                    producer: startProducing ? .producing : .paused
                ),
                responseState
            )
            return .notifyRequestHeadSendSuccessfully(
                resumeRequestBodyStream: startProducing,
                startIdleTimer: false
            )
        case .running(.endSent, _):
            return .notifyRequestHeadSendSuccessfully(resumeRequestBodyStream: false, startIdleTimer: true)
        case .running(.streaming(_, _, producer: .producing), _):
            preconditionFailure(
                "request body producing can not start before we have successfully send the header \(self.state)"
            )
        case .failed:
            return .wait

        case .modifying:
            preconditionFailure("Invalid state: \(self.state)")
        }
    }
}

extension RequestFramingMetadata.Body {
    var expectedLength: Int64? {
        switch self {
        case .fixedSize(let length): return length
        case .stream: return nil
        }
    }
}

extension HTTPRequestStateMachine {
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

extension HTTPRequestStateMachine.ResponseStreamState.Action {
    func toRequestAction() -> HTTPRequestStateMachine.Action {
        switch self {
        case .read:
            return .read
        case .wait:
            return .wait
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
            return
                "HTTPRequestStateMachine(.running(request: \(requestState), response: \(responseState)), isWritable: \(self.isChannelWritable))"
        case .finished:
            return "HTTPRequestStateMachine(.finished, isWritable: \(self.isChannelWritable))"
        case .failed(let error):
            return "HTTPRequestStateMachine(.failed(\(error)), isWritable: \(self.isChannelWritable))"
        case .modifying:
            return "HTTPRequestStateMachine(.modifying, isWritable: \(self.isChannelWritable))"
        }
    }
}

extension HTTPRequestStateMachine.RequestState: CustomStringConvertible {
    var description: String {
        switch self {
        case .streaming(expectedBodyLength: let expected, let sent, let producer):
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
