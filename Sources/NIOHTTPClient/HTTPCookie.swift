//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIOHTTPClient open source project
//
// Copyright (c) 2018-2019 Swift Server Working Group and the SwiftNIOHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIOHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation
import NIOHTTP1

public struct HTTPCookie {
    public var name: String
    public var value: String
    public var path: String
    public var domain: String?
    public var expires: Date?
    public var maxAge: Int?
    public var httpOnly: Bool
    public var secure: Bool

    public init?(from string: String, defaultDomain: String) {
        let components = string.components(separatedBy: ";").map {
            $0.trimmingCharacters(in: .whitespaces)
        }

        if components.isEmpty {
            return nil
        }

        let nameAndValue = components[0].split(separator: "=", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }

        guard nameAndValue.count == 2 else {
            return nil
        }

        self.name = nameAndValue[0]
        self.value = nameAndValue[1]

        self.path = "/"
        self.domain = defaultDomain
        self.expires = nil
        self.maxAge = nil
        self.httpOnly = false
        self.secure = false

        for component in components[1...] {
            if component.starts(with: "Path"), let value = parseComponentValue(component) {
                self.path = value
                continue
            }

            if component.starts(with: "Domain"), let value = parseComponentValue(component) {
                self.domain = value
                continue
            }

            if component.starts(with: "Expires") {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US")
                formatter.timeZone = TimeZone(identifier: "GMT")
                formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
                self.expires = self.parseComponentValue(component).flatMap { formatter.date(from: $0) }
                continue
            }

            if component.starts(with: "Max-Age"), let value = parseComponentValue(component).flatMap(Int.init) {
                self.maxAge = value
                continue
            }

            if component == "Secure" {
                self.secure = true
                continue
            }

            if component == "HttpOnly" {
                self.httpOnly = true
                continue
            }
        }
    }

    public init(name: String, value: String, path: String = "/", domain: String? = nil, expires: Date? = nil, maxAge: Int? = nil, httpOnly: Bool = false, secure: Bool = false) {
        self.name = name
        self.value = value
        self.path = path
        self.domain = domain
        self.expires = expires
        self.httpOnly = httpOnly
        self.secure = secure
    }

    func parseComponentValue(_ component: String) -> String? {
        let nameAndValue = component.split(separator: "=", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        if nameAndValue.count == 2 {
            return nameAndValue[1]
        }
        return nil
    }
}

public extension HTTPClient.Response {
    internal var cookieHeaders: [HTTPHeaders.Element] {
        return headers.filter { $0.name.lowercased() == "set-cookie" }
    }

    var cookies: [HTTPCookie] {
        return self.cookieHeaders.compactMap { HTTPCookie(from: $0.value, defaultDomain: self.host) }
    }
}
