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
import NIOTLS
import NIOSSL
#if canImport(Network)
    import Network
    import NIOTransportServices
#endif

extension HTTPConnectionPool {
    
    class ConnectionBootstrap {
        
    }
    
    
}

extension HTTPConnectionPool.ConnectionBootstrap {
    
    struct StateMachine {
        
        enum Action {
            enum ConnectTarget {
                case tcp(host: String, port: Int)
                case unixDomainSocket(path: String)
            }
        
            case makeBootstrap(EventLoop)
            case makeSOCKSBootstrap(EventLoop)
            case makeHTTPProxyBootstrap(EventLoop)
            case makeTLSBootstrap(EventLoop, TLSConfiguration)
            
            case connect(NIOClientTCPBootstrapProtocol, ConnectTarget)
            
            case startHTTPProxyHandshake
            case startSOCKSProxyHandshake
            case addLateTLSHandshake
            
            case removeHTTPProxyHandlers
            case removeSOCKSHandlers
            case removeTLSEventsHandler
            
            case failConnectionCreation(Error)
        }
        
        enum State {
            case initialized
            case makingProxyBootstrap(HTTPClient.Configuration.Proxy)
            case makingBootstrap
            case connecting(HTTPClient.Configuration.Proxy?)
        }
        
        private var state: State = .initialized
        
        let eventLoop: EventLoop
        let key: ConnectionPool.Key
        let tlsConfiguration: TLSConfiguration?
        let proxyConfiguration: HTTPClient.Configuration.Proxy?
        let deadline: NIODeadline
        
        init(eventLoop: EventLoop,
             key: ConnectionPool.Key,
             tlsConfiguration: TLSConfiguration?,
             proxyConfiguration: HTTPClient.Configuration.Proxy?,
             deadline: NIODeadline)
        {
            self.eventLoop = eventLoop
            self.tlsConfiguration = tlsConfiguration
            self.proxyConfiguration = proxyConfiguration
            self.deadline = deadline
            self.key = key
        }
        
        mutating func start() -> Action {
            guard case .initialized = self.state else {
                preconditionFailure("Invalid state")
            }
            
            if self.key.scheme.isProxyable, let proxy = self.proxyConfiguration {
                self.state = .makingProxyBootstrap(proxy)
                return .makeBootstrap(self.eventLoop)
            }
            
            self.state = .makingBootstrap
            
            if let tlsConfiguration = self.tlsConfiguration {
                return .makeTLSBootstrap(self.eventLoop, tlsConfiguration)
            }
            
            return .makeBootstrap(self.eventLoop)
        }
        
        mutating func bootstrapCreated(_ bootstrap: NIOClientTCPBootstrapProtocol) -> Action {
            switch self.state {
            case .initialized, .connecting:
                preconditionFailure("Unexpected state")
                
            case .makingBootstrap:
                let connectTarget: Action.ConnectTarget
                switch self.key.scheme {
                case .https, .http:
                    connectTarget = .tcp(host: self.key.host, port: self.key.port)
                case .https_unix, .http_unix, .unix:
                    connectTarget = .unixDomainSocket(path: self.key.unixPath)
                }
                self.state = .connecting(nil)
                return .connect(bootstrap, connectTarget)
                
            case .makingProxyBootstrap(let proxy):
                self.state = .connecting(proxy)
                return .connect(bootstrap, .tcp(host: proxy.host, port: proxy.port))

            }
        }
        
        mutating func connected() -> Action {
            
            switch self.state {
            case .initialized, .connecting, .makingBootstrap, .makingProxyBootstrap:
                preconditionFailure("Unexpected state")

                
            case .connecting(.some(let proxy)):
                
                
            case .connecting(.none):
                
            
            }
            
        }
        
    }
    
}
