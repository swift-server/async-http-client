import Configuration
import NIOCore

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension HTTPClient.Configuration {
    /// Initializes HTTPClient configuration from a ConfigReader.
    ///
    /// ## Configuration keys:
    /// - `dnsOverrides` (string array, optional): Colon-separated host:IP pairs for DNS overrides (e.g., "localhost:127.0.0.1").
    /// - `redirect.mode` (string, optional, default: "follow"): Redirect handling mode ("follow" or "disallow").
    /// - `redirect.maxRedirects` (int, optional, default: 5): Maximum allowed redirects (used when mode is "follow").
    /// - `redirect.allowCycles` (bool, optional, default: false): Allow cyclic redirects (used when mode is "follow").
    /// - `timeout.connectionMs` (int, optional): Connection timeout in milliseconds.
    /// - `timeout.readMs` (int, optional): Read timeout in milliseconds.
    /// - `timeout.writeMs` (int, optional): Write timeout in milliseconds.
    /// - `connectionPool.idleTimeoutMs` (int, optional, default: 60000): Connection idle timeout in milliseconds.
    /// - `connectionPool.concurrentHTTP1ConnectionsPerHostSoftLimit` (int, optional, default: 8): Soft limit for concurrent HTTP/1.1 connections per host.
    /// - `connectionPool.retryConnectionEstablishment` (bool, optional, default: true): Retry failed connection establishment.
    /// - `connectionPool.preWarmedHTTP1ConnectionCount` (int, optional, default: 0): Number of pre-warmed HTTP/1.1 connections per host.
    /// - `httpVersion` (string, optional): HTTP version to use ( "automatic" or  "http1Only").
    /// - `maximumUsesPerConnection` (int, optional): Maximum uses per connection.
    public init(configReader: ConfigReader) throws {
        self.init()

        // Each entry in the list should be a colon separated pair e.g. localhost:127.0.0.1 or localhost:::1
        if let dnsOverridesList = configReader.stringArray(forKey: "dnsOverrides") {
            for entry in dnsOverridesList {
                guard let separatorIndex = entry.firstIndex(of: ":") else {
                    continue
                }
                let key = entry.prefix(upTo: separatorIndex)
                let value = entry.suffix(from: entry.index(after: separatorIndex))
                self.dnsOverride[String(key)] = String(value)
            }
        }

        self.redirectConfiguration = try .init(configReader: configReader.scoped(to: "redirect"))
        self.timeout = .init(configReader: configReader.scoped(to: "timeout"))
        self.connectionPool = .init(configReader: configReader.scoped(to: "connectionPool"))
        if let version = try HTTPVersion(configReader: configReader) {
            self.httpVersion = version
        }
        self.maximumUsesPerConnection = configReader.int(forKey: "maximumUsesPerConnection")
    }
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension HTTPClient.Configuration.RedirectConfiguration {
    fileprivate init(configReader: ConfigReader) throws {
        guard let mode = configReader.string(forKey: "mode") else {
            // default
            self = .follow(max: 5, allowCycles: false)
            return
        }
        if mode == "follow" {
            let maxRedirects = configReader.int(forKey: "maxRedirects", default: 5)
            let allowCycles = configReader.bool(forKey: "allowCycles", default: false)
            self = .follow(max: maxRedirects, allowCycles: allowCycles)
        } else if mode == "disallow" {
            self = .disallow
        } else {
            throw HTTPClientError.invalidRedirectConfiguration
        }
    }
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension HTTPClient.Configuration.Timeout {
    fileprivate init(configReader: ConfigReader) {
        self.init()
        self.connect = configReader.int(forKey: "connectionMs").map { TimeAmount.milliseconds(Int64($0)) }
        self.read = configReader.int(forKey: "readMs").map { TimeAmount.milliseconds(Int64($0)) }
        self.write = configReader.int(forKey: "writeMs").map { TimeAmount.milliseconds(Int64($0)) }
    }
}

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension HTTPClient.Configuration.ConnectionPool {
    fileprivate init(configReader: ConfigReader) {
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
