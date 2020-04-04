//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2018-2020 Apple Inc. and the AsyncHTTPClient project authors
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

/// Enum containing all the DNS errors
public enum NWDNSError: Error {
    case noError
    case unknown /* 0xFFFE FFFF */
    case noSuchName
    case noMemory
    case badParam
    case badReference
    case badState
    case badFlags
    case unsupported
    case notInitialized
    case alreadyRegistered
    case nameConflict
    case invalid
    case firewall
    case incompatible /* client library incompatible with daemon */
    case badInterfaceIndex
    case refused
    case noSuchRecord
    case noAuth
    case noSuchKey
    case NATTraversal
    case doubleNAT
    case badTime /* Codes up to here existed in Tiger */
    case badSig
    case badKey
    case transient
    case serviceNotRunning /* Background daemon not running */
    case NATPortMappingUnsupported /* NAT doesn't support PCP, NAT-PMP or UPnP */
    case NATPortMappingDisabled /* NAT supports PCP, NAT-PMP or UPnP, but it's disabled by the administrator */
    case noRouter /* No router currently configured (probably no network connectivity) */
    case pollingMode
    case timeout
    case defunctConnection /* Connection to daemon returned a SO_ISDEFUNCT error result */
    case other(DNSServiceErrorType)
}

extension NWDNSError {
    /// Initialize NWDNSError from DNSServiceErrorType
    /// - Parameter error: error type
    public init(from error: DNSServiceErrorType) {
        let errorInt = Int(error)
        switch (errorInt) {
        case kDNSServiceErr_NoError: self = .noError
        case kDNSServiceErr_Unknown: self = .unknown
        case kDNSServiceErr_NoSuchName: self = .noSuchName
        case kDNSServiceErr_NoMemory: self = .noMemory
        case kDNSServiceErr_BadParam: self = .badParam
        case kDNSServiceErr_BadReference: self = .badReference
        case kDNSServiceErr_BadState: self = .badState
        case kDNSServiceErr_BadFlags: self = .badFlags
        case kDNSServiceErr_Unsupported: self = .unsupported
        case kDNSServiceErr_NotInitialized: self = .notInitialized
        case kDNSServiceErr_AlreadyRegistered: self = .alreadyRegistered
        case kDNSServiceErr_NameConflict: self = .nameConflict
        case kDNSServiceErr_Invalid: self = .invalid
        case kDNSServiceErr_Firewall: self = .firewall
        case kDNSServiceErr_Incompatible: self = .incompatible
        case kDNSServiceErr_BadInterfaceIndex: self = .badInterfaceIndex
        case kDNSServiceErr_Refused: self = .refused
        case kDNSServiceErr_NoSuchRecord: self = .noSuchRecord
        case kDNSServiceErr_NoAuth: self = .noAuth
        case kDNSServiceErr_NoSuchKey: self = .noSuchKey
        case kDNSServiceErr_NATTraversal: self = .NATTraversal
        case kDNSServiceErr_DoubleNAT: self = .doubleNAT
        case kDNSServiceErr_BadTime: self = .badTime
        case kDNSServiceErr_BadSig: self = .badSig
        case kDNSServiceErr_BadKey: self = .badKey
        case kDNSServiceErr_Transient: self = .transient
        case kDNSServiceErr_ServiceNotRunning: self = .serviceNotRunning
        case kDNSServiceErr_NATPortMappingUnsupported: self = .NATPortMappingUnsupported
        case kDNSServiceErr_NATPortMappingDisabled: self = .NATPortMappingDisabled
        case kDNSServiceErr_NoRouter: self = .noRouter
        case kDNSServiceErr_PollingMode: self = .pollingMode
        case kDNSServiceErr_Timeout: self = .timeout
        case kDNSServiceErr_DefunctConnection: self = .defunctConnection
        default:
            self = .other(error)
        }
    }
}

public struct NWPOSIXError: Error {
    
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
}

extension NWPOSIXError: CustomStringConvertible {
    public var description: String { return reason }
}

public struct NWTLSError: Error {

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
}

extension NWTLSError: CustomStringConvertible {
    public var description: String { return reason }
}

@available (macOS 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
class NWErrorHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart
    
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.fireErrorCaught(NWErrorHandler.translateError(error))
    }
    
    static func translateError(_ error: Error) -> Error {
        
        if let error = error as? NWError {
            switch error {
            case .dns(let errorType):
                return NWDNSError(from: errorType)
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


#endif
