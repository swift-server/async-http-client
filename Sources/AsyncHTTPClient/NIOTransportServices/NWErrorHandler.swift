//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2020 Apple Inc. and the AsyncHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if canImport(Network)

    import Network
    import NIO
    import NIOHTTP1
    import NIOTransportServices

    extension HTTPClient {
        public struct NWPOSIXError: Error, CustomStringConvertible {
            /// POSIX error code (enum)
            public let errorCode: POSIXErrorCode

            /// actual reason, in human readable form
            private let reason: String

            /// Initialise a NWPOSIXError
            /// - Parameters:
            ///   - errorType: posix error type
            ///   - reason: String describing reason for error
            public init(_ errorCode: POSIXErrorCode, reason: String) {
                self.errorCode = errorCode
                self.reason = reason
            }

            public var description: String { return self.reason }
        }

        public struct NWTLSError: Error, CustomStringConvertible {
            /// TLS error status. List of TLS errors can be found in <Security/SecureTransport.h>
            public let status: OSStatus

            /// actual reason, in human readable form
            private let reason: String

            /// initialise a NWTLSError
            /// - Parameters:
            ///   - status: TLS status
            ///   - reason: String describing reason for error
            public init(_ status: OSStatus, reason: String) {
                self.status = status
                self.reason = reason
            }

            public var description: String { return self.reason }
        }

        @available(macOS 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
        class NWErrorHandler: ChannelInboundHandler {
            typealias InboundIn = HTTPClientResponsePart

            func errorCaught(context: ChannelHandlerContext, error: Error) {
                context.fireErrorCaught(NWErrorHandler.translateError(error))
            }

            static func translateError(_ error: Error) -> Error {
                if let error = error as? NWError {
                    switch error {
                    case .tls(let status):
                        return NWTLSError(status, reason: error.localizedDescription)
                    case .posix(let errorCode):
                        return NWPOSIXError(errorCode, reason: error.localizedDescription)
                    default:
                        return error
                    }
                }
                return error
            }
        }
    }
#endif
