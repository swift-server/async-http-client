# swift-nio-http-client
This package provides simple HTTP Client library built on top of SwiftNIO.

## Getting Started

Add the following entry in your <code>Package.swift</code> to start using <code>HTTPClient</code>:

### Swift 5

```swift
dependencies: [
    .package(url: "https://github.com/swift-server/swift-nio-http-client.git", from: "1.0.0")
]
```

## Status

This library provides the following:
1. Async single request methods
2. Simple follow-redirect support (cookie headers are dropped)
3. Body download streaming
4. TLS support
5. Cookie parsing (but not storage)

## How to use

### Request-Response API
The code snippet below illustrates how to make a simple GET request to a remote server:

```import HTTPClient

let httpClient = HTTPClient(eventLoopGroupProvider: .createNew)
let response = try httpClient.get(url: "https://swift.org").wait()

if response.status == .ok {
    // handle the response
}

// close the client
try? httpClient.syncShutdown()
```

It is important to close client instance after use to cleanly shutdown underlying NIO ```EventLoopGroup```. Alternatively, you can provide shared ```EventLoopGroup```:
```
let httpClient = HTTPClient(eventLoopGroupProvider: .shared(userProvidedGroup))
```
In this case shutdown of the client is not neccecary.

Library provides methods for most HTTP-methods. In case you need to have more control over the method, or you want to add headers or body, use ```HTTPRequest``` struct:
```import HTTPClient

let httpClient = HTTPClient(eventLoopGroupProvider: .createNew)
defer {
    try? httpClient.syncShutdown()
}

var request = try HTTPRequest(url: "https://swift.org", method: .POST)
request.headers.add(name: "User-Agent", value: "Swift HTTPClient")
request.body = .string("some-body")

let response = try httpClient.execute(request: request).wait()

if response.status == .ok {
    // handle the response
}
```

### Redirect following
To enable follow-redirects behaviour, enable in using client configuration:
```
let httpClient = HTTPClient(eventLoopGroupProvider: .createNew,
                            configuration: HTTPClientConfiguration(followRedirects: true))
```

### Timeouts
Timeouts (connect and read) can be set in the client configuration:
```
let httpClient = HTTPClient(eventLoopGroupProvider: .createNew,
                            configuration: HTTPClientConfiguration(timeout: Timeout(connectTimeout: .seconds(1),
                                                                                    readTimeout: .seconds(1))))
```
or on per-request basis:
```
let response = try httpClient.execute(request: request, timeout: Timeout(connectTimeout: .seconds(1), readTimeout: .seconds(1))).wait()
```

### Streaming
In case greater control over body processing is needed or you want to process HTTP Reponse body in a streaming manner, following delegate protocol could be used (example shows how to count bytes in response body without copiying it to the memory):
```
class CountingDelegate: HTTPResponseDelegate {
    typealias Response = Int

    var count = 0
    
    func didTransmitRequestBody() {
        // this is executed when request is sent, called once
    }

    func didReceiveHead(_ head: HTTPResponseHead) {
        // this is executed when we receive HTTP Reponse head part of the request (it contains response code and headers), called once
    }

    func didReceivePart(_ buffer: ByteBuffer) {
        // this is executed when we receive parts of the response body, could be called zero or more times
        count += buffer.readableBytes
    }

    func didFinishRequest() throws -> Int {
        // this is called when request is fully read, called once, this is where you return a result or throw any errors you require to propagate to the client
        return count
    }
    
    func didReceiveError(_ error: Error) {
        // this is called when we receive any network-related error, called once
    }
}

let request = try HTTPRequest(url: "https://swift.org")
let delegate = CountingDelegate()

let count = try httpClient.execute(request: request, delegate: delegate).wait()
```
