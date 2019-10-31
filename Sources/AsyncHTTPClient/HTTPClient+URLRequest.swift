//
//  HTTPClient+URLRequest.swift
//  
//
//  Created by Volkov Alexander on 10/31/19.
//

import Foundation
import NIO
import NIOHTTP1

extension HTTPClient {
    
    /// Execute using URLRequest
    /// - Parameter request: the request
    public func execute(request: URLRequest) -> EventLoopFuture<Response> {
        do {
            let request = try request.toHTTPRequest()
            return self.execute(request: request)
        }
        catch let error {
            fatalError("Request cannot be made: \(error)")
        }
    }
}

extension URLRequest {
    
    /// Convert to HTTPClient.Request
    public func toHTTPRequest() throws -> HTTPClient.Request {
        guard let url = self.url?.absoluteString else { throw HTTPClientError.invalidURL }
        guard let httpMethod = self.httpMethod else { throw HTTPClientError.invalidURL }
        let method: HTTPMethod = HTTPMethod.from(string: httpMethod)
        
        var request = try HTTPClient.Request(url: url, method: method)
        for(k,v) in self.allHTTPHeaderFields ?? [:] {
            request.headers.add(name: k, value: v)
        }
        if let data = self.httpBody {
            request.body = .data(data)
        }
        return request
    }
}

extension HTTPMethod {
    
    static func from(string: String) -> HTTPMethod {
        switch string {
        case "GET": return .GET
        case "PUT": return .PUT
        case "ACL": return .ACL
        case "HEAD": return .HEAD
        case "POST": return .POST
        case "COPY": return .COPY
        case "LOCK": return .LOCK
        case "MOVE": return .MOVE
        case "BIND": return .BIND
        case "LINK": return .LINK
        case "PATCH": return .PATCH
        case "TRACE": return .TRACE
        case "MKCOL": return .MKCOL
        case "MERGE": return .MERGE
        case "PURGE": return .PURGE
        case "NOTIFY": return .NOTIFY
        case "SEARCH": return .SEARCH
        case "UNLOCK": return .UNLOCK
        case "REBIND": return .REBIND
        case "UNBIND": return .UNBIND
        case "REPORT": return .REPORT
        case "DELETE": return .DELETE
        case "UNLINK": return .UNLINK
        case "CONNECT": return .CONNECT
        case "MSEARCH": return .MSEARCH
        case "OPTIONS": return .OPTIONS
        case "PROPFIND": return .PROPFIND
        case "CHECKOUT": return .CHECKOUT
        case "PROPPATCH": return .PROPPATCH
        case "SUBSCRIBE": return .SUBSCRIBE
        case "MKCALENDAR": return .MKCALENDAR
        case "MKACTIVITY": return .MKACTIVITY
        case "UNSUBSCRIBE": return .UNSUBSCRIBE
        case "SOURCE": return .SOURCE
        default:
            return .RAW(value: string)
        }
    }
}
