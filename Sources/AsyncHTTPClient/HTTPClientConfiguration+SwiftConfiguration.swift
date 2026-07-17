//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2026 Apple Inc. and the AsyncHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if compiler(>=6.2)
import Configuration
import NIOCore

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension HTTPClient.Configuration {
    /// Initializes HTTPClient configuration from a ConfigReader.
    ///
    /// ## Configuration keys:
    /// - `dnsOverrides` (string array, optional): Colon-separated host:IP pairs for DNS overrides (e.g., "localhost:127.0.0.1").
    /// - `redirect` (scoped): Redirect handling configuration read by ``RedirectConfiguration/init(configReader:)``.
    /// - `timeout` (scoped): Timeout configuration read by ``Timeout/init(configReader:)``.
    /// - `connectionPool` (scoped): Connection pool configuration read by ``ConnectionPool/init(configReader:)``.
    /// - `proxy` (scoped, optional): Proxy configuration read by ``Proxy/init(configReader:)``. Only applied if `proxy.enabled` is `true`.
    /// - `httpVersion` (string, optional, default: automatic): HTTP version to use ( "automatic" or  "http1Only").
    /// - `maximumUsesPerConnection` (int, optional, default: nil, no limit): Maximum uses per connection.
    ///
    /// - Throws: `HTTPClientError.invalidRedirectConfiguration` if redirect mode is invalid.
    /// - Throws: `HTTPClientError.invalidHTTPVersionConfiguration` if httpVersion is specified but invalid.
    /// - Throws: `HTTPClientError.invalidProxyConfiguration` if proxy configuration is invalid.
    public init(configReader: ConfigReader) throws {
        self.init()

        // Each entry in the list should be a colon separated pair e.g. localhost:127.0.0.1 or localhost:::1
        if let dnsOverridesList = configReader.stringArray(forKey: "dnsOverrides") {
            for entry in dnsOverridesList {
                guard let separatorIndex = entry.firstIndex(of: ":") else {
                    throw HTTPClientError.invalidDNSOverridesConfiguration
                }
                let key = entry.prefix(upTo: separatorIndex)
                let value = entry.suffix(from: entry.index(after: separatorIndex))
                if key.isEmpty || value.isEmpty {
                    throw HTTPClientError.invalidDNSOverridesConfiguration
                }
                self.dnsOverride[String(key)] = String(value.filter { !$0.isWhitespace })
            }
        }

        self.redirectConfiguration = try .init(configReader: configReader.scoped(to: "redirect"))
        self.timeout = .init(configReader: configReader.scoped(to: "timeout"))
        self.connectionPool = .init(configReader: configReader.scoped(to: "connectionPool"))
        if let proxy = try Proxy(configReader: configReader.scoped(to: "proxy")) {
            self.proxy = proxy
        }
        if let version = try HTTPVersion(configReader: configReader) {
            self.httpVersion = version
        }
        self.maximumUsesPerConnection = configReader.int(forKey: "maximumUsesPerConnection")
    }
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension HTTPClient.Configuration.RedirectConfiguration {
    /// Initializes redirect configuration from a ConfigReader.
    ///
    /// ## Configuration keys:
    /// - `mode` (string, optional, default: "follow"): Redirect handling mode ("follow" or "disallow").
    /// - `maxRedirects` (int, optional, default: 5): Maximum allowed redirects when mode is "follow".
    /// - `allowCycles` (bool, optional, default: false): Allow cyclic redirects when mode is "follow".
    /// - `retainHTTPMethodAndBodyOn301` (bool, optional, default: false): Whether to retain the HTTP method and body when following a 301 redirect on a POST request. This should be false as per the fetch spec, but may be true according to RFC 9110. This does not affect non-POST requests.
    /// - `retainHTTPMethodAndBodyOn302` (bool, optional, default: false): Whether to retain the HTTP method and body when following a 302 redirect on a POST request. This should be false as per the fetch spec, but may be true according to RFC 9110. This does not affect non-POST requests.
    ///
    /// - Throws: `HTTPClientError.invalidRedirectConfiguration` if mode is specified but invalid.
    public init(configReader: ConfigReader) throws {
        guard let mode = configReader.string(forKey: "mode") else {
            // default
            self = .follow(max: 5, allowCycles: false)
            return
        }
        if mode == "follow" {
            let maxRedirects = configReader.int(forKey: "maxRedirects", default: 5)
            let allowCycles = configReader.bool(forKey: "allowCycles", default: false)
            let retainHTTPMethodAndBodyOn301 = configReader.bool(forKey: "retainHTTPMethodAndBodyOn301", default: false)
            let retainHTTPMethodAndBodyOn302 = configReader.bool(forKey: "retainHTTPMethodAndBodyOn302", default: false)
            self = .follow(
                configuration: .init(
                    max: maxRedirects,
                    allowCycles: allowCycles,
                    retainHTTPMethodAndBodyOn301: retainHTTPMethodAndBodyOn301,
                    retainHTTPMethodAndBodyOn302: retainHTTPMethodAndBodyOn302
                )
            )
        } else if mode == "disallow" {
            self = .disallow
        } else {
            throw HTTPClientError.invalidRedirectConfiguration
        }
    }
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension HTTPClient.Configuration.Timeout {
    /// Initializes timeout configuration from a ConfigReader.
    ///
    /// ## Configuration keys:
    /// - `connectionMs` (int, optional, default: 10,000): Connection timeout in milliseconds.
    /// - `readMs` (int, optional): Read timeout in milliseconds.
    /// - `writeMs` (int, optional): Write timeout in milliseconds.
    public init(configReader: ConfigReader) {
        self.init()
        self.connect = configReader.int(forKey: "connectionMs").map { TimeAmount.milliseconds(Int64($0)) }
        self.read = configReader.int(forKey: "readMs").map { TimeAmount.milliseconds(Int64($0)) }
        self.write = configReader.int(forKey: "writeMs").map { TimeAmount.milliseconds(Int64($0)) }
    }
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension HTTPClient.Configuration.ConnectionPool {
    /// Initializes connection pool configuration from a ConfigReader.
    ///
    /// ## Configuration keys:
    /// - `idleTimeoutMs` (int, optional, default: 60,000): Connection idle timeout in milliseconds.
    /// - `concurrentHTTP1ConnectionsPerHostSoftLimit` (int, optional, default: 8): Soft limit for concurrent HTTP/1.1 connections per host.
    /// - `retryConnectionEstablishment` (bool, optional, default: true): Retry failed connection establishment.
    /// - `preWarmedHTTP1ConnectionCount` (int, optional, default: 0): Number of pre-warmed HTTP/1.1 connections per host.
    public init(configReader: ConfigReader) {
        self.init()
        self.idleTimeout = TimeAmount.milliseconds(Int64(configReader.int(forKey: "idleTimeoutMs", default: 60000)))
        self.concurrentHTTP1ConnectionsPerHostSoftLimit = configReader.int(
            forKey: "concurrentHTTP1ConnectionsPerHostSoftLimit",
            default: 8
        )
        self.retryConnectionEstablishment = configReader.bool(forKey: "retryConnectionEstablishment", default: true)
        self.preWarmedHTTP1ConnectionCount = configReader.int(forKey: "preWarmedHTTP1ConnectionCount", default: 0)
    }
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension HTTPClient.Configuration.HTTPVersion {
    fileprivate init?(configReader: ConfigReader) throws {
        guard let rawValue = configReader.string(forKey: "httpVersion") else {
            // Unspecified is not an error. It's an optional prop.
            return nil
        }
        // Specified but invalid IS an error
        guard let base = Self.Configuration(rawValue: rawValue) else {
            throw HTTPClientError.invalidHTTPVersionConfiguration
        }
        self = .init(configuration: base)
    }
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension HTTPClient.Configuration.Proxy {
    /// Initializes proxy configuration from a ConfigReader.
    ///
    /// ## Configuration keys:
    /// - `enabled` (bool, optional, default: false): Whether proxy support is enabled. If `false`, the initializer returns `nil`.
    /// - `host` (string): Proxy server host. Required when `enabled` is `true`.
    /// - `port` (int): Proxy server port. Required for `http` proxies; defaults to `1080` for `socks` proxies.
    /// - `type` (string, optional, default: "http"): Proxy type ("http" or "socks").
    /// - `authorization` (scoped, optional): Authorization configuration read by ``HTTPClient/Authorization/init(configReader:)``.
    ///   Only supported for `http` proxies.
    ///
    /// - Throws: `HTTPClientError.invalidProxyConfiguration` if `enabled` is `true` but `host` is missing, `type` is unknown,
    ///   `port` is missing for an HTTP proxy, or `authorization` is specified for a SOCKS proxy, or `authorization` is invalid (see ``HTTPClient/Authorization/init(configReader:)``)
    public init?(configReader: ConfigReader) throws {
        guard configReader.bool(forKey: "enabled", default: false) else {
            return nil
        }
        let host = try configReader.requiredString(forKey: "host")
        let type = configReader.string(forKey: "type", default: "http")
        let authorization = try HTTPClient.Authorization(configReader: configReader.scoped(to: "authorization"))
        switch type {
        case "http":
            let port = try configReader.requiredInt(forKey: "port")
            self = .server(host: host, port: port, authorization: authorization)
        case "socks":
            if authorization != nil {
                throw HTTPClientError.invalidProxyConfiguration
            }
            let port = configReader.int(forKey: "port", default: 1080)
            self = .socksServer(host: host, port: port)
        default:
            throw HTTPClientError.invalidProxyConfiguration
        }
    }
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension HTTPClient.Authorization {
    /// Initializes HTTP authorization from a ConfigReader.
    ///
    /// ## Configuration keys:
    /// - `scheme` (string, optional): Authorization scheme ("basic" or "bearer"). If absent, the initializer returns `nil`.
    /// - `username` (string): Username for basic authentication. Required (alongside `password`) when `scheme` is "basic" and `credentials` is not set.
    /// - `password` (string): Password for basic authentication. Required (alongside `username`) when `scheme` is "basic" and `credentials` is not set.
    /// - `credentials` (string): Pre-encoded basic credentials. Used when `scheme` is "basic" and `username`/`password` are not both provided.
    /// - `token` (string): Bearer token. Required when `scheme` is "bearer".
    ///
    /// - Throws: `HTTPClientError.invalidProxyConfiguration` if `scheme` is unknown or required keys are missing.
    public init?(configReader: ConfigReader) throws {
        guard let scheme = configReader.string(forKey: "scheme") else {
            return nil
        }
        switch scheme {
        case "basic":
            if let username = configReader.string(forKey: "username"),
                let password = configReader.string(forKey: "password")
            {
                self = .basic(username: username, password: password)
            } else if let credentials = configReader.string(forKey: "credentials") {
                self = .basic(credentials: credentials)
            } else {
                throw HTTPClientError.invalidProxyConfiguration
            }
        case "bearer":
            guard let token = configReader.string(forKey: "token") else {
                throw HTTPClientError.invalidProxyConfiguration
            }
            self = .bearer(tokens: token)
        default:
            throw HTTPClientError.invalidProxyConfiguration
        }
    }
}
#endif
