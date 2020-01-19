//
//  File.swift
//  
//
//  Created by Marcin Krzyzanowski on 19/01/2020.
//

import Foundation
import NIOHTTP1

protocol HTTPRequest {
    /// Request HTTP method
    var method: HTTPMethod { get }
    /// Remote URL.
    var url: URL { get }
    /// Remote HTTP scheme, resolved from `URL`.
    var scheme: String { get }
    /// Remote host, resolved from `URL`.
    var host: String { get }
    /// Request custom HTTP Headers, defaults to no headers.
    var headers: HTTPHeaders { get set }
    /// Request body, defaults to no body.
    var body: HTTPClient.Body? { get set }

    static func isSchemeSupported(scheme: String) -> Bool
}
