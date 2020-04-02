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

import Foundation
import Network
import NIOSSL
import NIOTransportServices

internal extension TLSVersion {
    /// return Network framework TLS protocol version
    var nwTLSProtocolVersion: tls_protocol_version_t {
        switch self {
        case .tlsv1:
            return .TLSv10
        case .tlsv11:
            return .TLSv11
        case .tlsv12:
            return .TLSv12
        case .tlsv13:
            return .TLSv13
        }
    }
}

@available (macOS 10.14, iOS 12.0, tvOS 12.0, watchOS 6.0, *)
internal extension TLSConfiguration {
    
    /// Dispatch queue used by Network framework TLS to control certificate verification
    static var tlsDispatchQueue = DispatchQueue(label: "TLSDispatch")

    /// create NWProtocolTLS.Options for use with NIOTransportServices from the NIOSSL TLSConfiguration
    ///
    /// - Parameter queue: Dispatch queue to run `sec_protocol_options_set_verify_block` on.
    /// - Returns: Equivalent NWProtocolTLS Options
    func getNWProtocolTLSOptions() -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        
        // minimum TLS protocol
        if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *) {
            sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, self.minimumTLSVersion.nwTLSProtocolVersion)
        }
        
        // maximum TLS protocol
        if let maximumTLSVersion = self.maximumTLSVersion {
            if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *) {
                sec_protocol_options_set_max_tls_protocol_version(options.securityProtocolOptions, maximumTLSVersion.nwTLSProtocolVersion)
            } else {
                precondition(self.maximumTLSVersion != nil, "TLSConfiguration.maximumTLSVersion is not supported")
            }
        }

        // application protocols
        if self.applicationProtocols.count > 0 {
            preconditionFailure("TLSConfiguration.applicationProtocols is not supported")
        }
        /*for applicationProtocol in self.applicationProtocols {
            applicationProtocol.utf8.withContiguousStorageIfAvailable { buffer in
                guard let opaquePointer = OpaquePointer(buffer.baseAddress) else { return }
                let int8Pointer = UnsafePointer<Int8>(opaquePointer)
                sec_protocol_options_add_tls_application_protocol(options.securityProtocolOptions, int8Pointer)
            }
        }*/

        // the certificate chain
        if self.certificateChain.count > 0 {
            preconditionFailure("TLSConfiguration.certificateChain is not supported")
        }
        
        // cipher suites
        if self.cipherSuites.count > 0 {
            //preconditionFailure("TLSConfiguration.cipherSuites is not supported")
        }
        
        // key log callback
        if let _ = self.keyLogCallback {
            preconditionFailure("TLSConfiguration.keyLogCallback is not supported")
        }
        
        // private key
        if let _ = self.privateKey {
            preconditionFailure("TLSConfiguration.privateKey is not supported")
        }
        
        // renegotiation support key is unsupported
        
        // trust roots
        if let trustRoots = self.trustRoots {
            guard case .default = trustRoots else {
                preconditionFailure("TLSConfiguration.trustRoots != .default is not supported")
            }
        }
        
        switch self.certificateVerification {
        case .none:
            // add verify block to control certificate verification
            sec_protocol_options_set_verify_block(options.securityProtocolOptions, { (sec_protocol_metadata, sec_trust, sec_protocol_verify_complete) in
                //let trust = sec_trust_copy_ref(sec_trust).takeRetainedValue()
                //var error: CFError?
                //if SecTrustEvaluateWithError(trust, &error) {                
                sec_protocol_verify_complete(true)
            }, TLSConfiguration.tlsDispatchQueue)

        case .noHostnameVerification:
            precondition(self.certificateVerification != .noHostnameVerification, "TLSConfiguration.certificateVerification = .noHostnameVerification is not supported")

        case .fullVerification:
            break
        }

        return options
    }
}

#endif
