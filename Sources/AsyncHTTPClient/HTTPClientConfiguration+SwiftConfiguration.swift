import Configuration
import NIOCore

@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
extension HTTPClient.Configuration {
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
