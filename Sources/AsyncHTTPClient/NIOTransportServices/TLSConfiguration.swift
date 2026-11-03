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

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Dispatch
import Network
import NIOCore
import NIOSSL
import NIOTransportServices

extension TLSVersion {
    /// return Network framework TLS protocol version
    @available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
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

extension TLSVersion {
    /// return as SSL protocol
    @available(macOS, deprecated: 10.15, message: "legacy functionality")
    @available(iOS, deprecated: 13.0, message: "legacy functionality")
    @available(tvOS, deprecated: 13.0, message: "legacy functionality")
    @available(watchOS, deprecated: 6.0, message: "legacy functionality")
    var sslProtocol: SSLProtocol {
        switch self {
        case .tlsv1:
            return .tlsProtocol1
        case .tlsv11:
            return .tlsProtocol11
        case .tlsv12:
            return .tlsProtocol12
        case .tlsv13:
            return .tlsProtocol13
        }
    }
}

/// Wraps a non-`Sendable` value that is, in practice, safe to hand across threads — used to satisfy the
/// compiler when passing the C-provided `sec_protocol_verify_complete_t` completion handler into a
/// `@Sendable` closure. Network.framework's own contract for `sec_protocol_verify_block_t` guarantees
/// this handler may be invoked from any queue.
private struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
}

@available(macOS 10.14, iOS 12.0, tvOS 12.0, watchOS 5.0, *)
extension TLSConfiguration {
    /// Dispatch queue used by Network framework TLS to control certificate verification
    static let tlsDispatchQueue = DispatchQueue(label: "TLSDispatch")

    /// create NWProtocolTLS.Options for use with NIOTransportServices from the NIOSSL TLSConfiguration
    ///
    /// - Parameter eventLoop: EventLoop to wait for creation of options on
    /// - Parameter customVerification: When non-nil, overrides *all* of Network.framework's certificate
    ///   verification (including trust-root validation) with this callback — see
    ///   ``HTTPClient/Configuration/tlsCustomVerificationNetworkFramework``.
    /// - Parameter localIdentity: A client identity (certificate + private key) to present for mTLS —
    ///   see ``HTTPClient/Configuration/tlsLocalIdentityNetworkFramework``.
    /// - Returns: Future holding NWProtocolTLS Options
    func getNWProtocolTLSOptions(
        on eventLoop: EventLoop,
        serverNameIndicatorOverride: String?,
        customVerification: (@Sendable (SecTrust, @escaping @Sendable (Bool) -> Void) -> Void)? = nil,
        localIdentity: SecIdentity? = nil
    ) -> EventLoopFuture<NWProtocolTLS.Options> {
        let promise = eventLoop.makePromise(of: NWProtocolTLS.Options.self)
        Self.tlsDispatchQueue.async {
            do {
                let options = try self.getNWProtocolTLSOptions(
                    serverNameIndicatorOverride: serverNameIndicatorOverride,
                    customVerification: customVerification,
                    localIdentity: localIdentity
                )
                promise.succeed(options)
            } catch {
                promise.fail(error)
            }
        }
        return promise.futureResult
    }

    /// create NWProtocolTLS.Options for use with NIOTransportServices from the NIOSSL TLSConfiguration
    ///
    /// - Parameter customVerification: When non-nil, overrides *all* of Network.framework's certificate
    ///   verification (including trust-root validation) with this callback — see
    ///   ``HTTPClient/Configuration/tlsCustomVerificationNetworkFramework``.
    /// - Parameter localIdentity: A client identity (certificate + private key) to present for mTLS —
    ///   see ``HTTPClient/Configuration/tlsLocalIdentityNetworkFramework``.
    /// - Returns: Equivalent NWProtocolTLS Options
    func getNWProtocolTLSOptions(
        serverNameIndicatorOverride: String?,
        customVerification: (@Sendable (SecTrust, @escaping @Sendable (Bool) -> Void) -> Void)? = nil,
        localIdentity: SecIdentity? = nil
    ) throws -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()

        let useMTELGExplainer = """
            You can still use this configuration option on macOS if you initialize HTTPClient \
            with a MultiThreadedEventLoopGroup. Please note that using MultiThreadedEventLoopGroup \
            will make AsyncHTTPClient use NIO on BSD Sockets and not Network.framework (which is the preferred \
            platform networking stack).
            """

        if let serverNameIndicatorOverride = serverNameIndicatorOverride {
            serverNameIndicatorOverride.withCString { serverNameIndicatorOverride in
                sec_protocol_options_set_tls_server_name(options.securityProtocolOptions, serverNameIndicatorOverride)
            }
        }

        // minimum TLS protocol
        if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *) {
            sec_protocol_options_set_min_tls_protocol_version(
                options.securityProtocolOptions,
                self.minimumTLSVersion.nwTLSProtocolVersion
            )
        } else {
            sec_protocol_options_set_tls_min_version(
                options.securityProtocolOptions,
                self.minimumTLSVersion.sslProtocol
            )
        }

        // maximum TLS protocol
        if let maximumTLSVersion = self.maximumTLSVersion {
            if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *) {
                sec_protocol_options_set_max_tls_protocol_version(
                    options.securityProtocolOptions,
                    maximumTLSVersion.nwTLSProtocolVersion
                )
            } else {
                sec_protocol_options_set_tls_max_version(options.securityProtocolOptions, maximumTLSVersion.sslProtocol)
            }
        }

        // application protocols
        for applicationProtocol in self.applicationProtocols {
            applicationProtocol.withCString { buffer in
                sec_protocol_options_add_tls_application_protocol(options.securityProtocolOptions, buffer)
            }
        }

        // cipher suites
        if self.cipherSuites.count > 0 {
            // TODO: Requires NIOSSL to provide list of cipher values before we can continue
            // https://github.com/apple/swift-nio-ssl/issues/207
        }

        // key log callback
        if self.keyLogCallback != nil {
            preconditionFailure("TLSConfiguration.keyLogCallback is not supported. \(useMTELGExplainer)")
        }

        // the certificate chain
        if self.certificateChain.count > 0 {
            preconditionFailure("TLSConfiguration.certificateChain is not supported. \(useMTELGExplainer)")
        }

        // private key
        if self.privateKey != nil {
            preconditionFailure("TLSConfiguration.privateKey is not supported. \(useMTELGExplainer)")
        }

        // local identity (mTLS) — the Network.framework equivalent of certificateChain/privateKey
        // above, which this backend doesn't support directly (see HTTPClient.Configuration's
        // tlsLocalIdentityNetworkFramework doc comment for why: there's no way to build a SecIdentity
        // from raw bytes without a Keychain round-trip, which is the caller's responsibility, not
        // AsyncHTTPClient's).
        if let localIdentity {
            guard let identity = sec_identity_create(localIdentity) else {
                throw NWLocalIdentityError.identityCreationFailed
            }
            sec_protocol_options_set_local_identity(options.securityProtocolOptions, identity)
        }

        // renegotiation support key is unsupported

        // trust roots
        var secTrustRoots: [SecCertificate]?
        switch trustRoots {
        case .some(.certificates(let certificates)):
            secTrustRoots = try certificates.compactMap { certificate in
                try SecCertificateCreateWithData(nil, Data(certificate.toDERBytes()) as CFData)
            }
        case .some(.file(let file)):
            let certificates = try NIOSSLCertificate.fromPEMFile(file)
            secTrustRoots = try certificates.compactMap { certificate in
                try SecCertificateCreateWithData(nil, Data(certificate.toDERBytes()) as CFData)
            }

        case .some(.default), .none:
            break
        }

        // A custom verification callback takes over the accept/reject decision entirely, so the
        // limitations around the built-in trust-root/hostname logic below no longer apply.
        precondition(
            customVerification != nil || self.certificateVerification != .noHostnameVerification,
            "TLSConfiguration.certificateVerification = .noHostnameVerification is not supported. \(useMTELGExplainer)"
        )

        if let customVerification {
            // A caller-supplied callback overrides all of Network.framework's verification logic,
            // including trust-root validation — same contract as NIOSSLCustomVerificationCallback on
            // the NIOSSL backend. The callback owns the accept/reject decision entirely.
            sec_protocol_options_set_verify_block(
                options.securityProtocolOptions,
                { _, sec_trust, sec_protocol_verify_complete in
                    let trust = sec_trust_copy_ref(sec_trust).takeRetainedValue()
                    let completeBox = UncheckedSendableBox(value: sec_protocol_verify_complete)
                    customVerification(trust) { accepted in
                        completeBox.value(accepted)
                    }
                },
                Self.tlsDispatchQueue
            )
        } else if certificateVerification != .fullVerification || trustRoots != nil {
            // add verify block to control certificate verification
            sec_protocol_options_set_verify_block(
                options.securityProtocolOptions,
                { _, sec_trust, sec_protocol_verify_complete in
                    guard self.certificateVerification != .none else {
                        sec_protocol_verify_complete(true)
                        return
                    }

                    let trust = sec_trust_copy_ref(sec_trust).takeRetainedValue()
                    if let trustRootCertificates = secTrustRoots {
                        SecTrustSetAnchorCertificates(trust, trustRootCertificates as CFArray)
                    }
                    if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *) {
                        dispatchPrecondition(condition: .onQueue(Self.tlsDispatchQueue))
                        SecTrustEvaluateAsyncWithError(trust, Self.tlsDispatchQueue) { _, result, error in
                            if let error = error {
                                print("Trust failed: \(error.localizedDescription)")
                            }
                            sec_protocol_verify_complete(result)
                        }
                    } else {
                        SecTrustEvaluateAsync(trust, Self.tlsDispatchQueue) { _, result in
                            switch result {
                            case .proceed, .unspecified:
                                sec_protocol_verify_complete(true)
                            default:
                                sec_protocol_verify_complete(false)
                            }
                        }
                    }
                },
                Self.tlsDispatchQueue
            )
        }
        return options
    }
}

enum NWLocalIdentityError: Error, CustomStringConvertible {
    case identityCreationFailed

    var description: String {
        "sec_identity_create(_:) returned nil for the SecIdentity passed as tlsLocalIdentityNetworkFramework."
    }
}

#endif
