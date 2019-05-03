# SwiftNIOHTTPClient
This package provides simple HTTP Client library built on top of SwiftNIO.

This library provides the following:
1. Asynchronous and non-blocking request methods
2. Simple follow-redirects (cookie headers are dropped)
3. Streaming body download
4. TLS support
5. Cookie parsing (but not storage)

---

**NOTE**: You will need [Xcode 10.2](https://itunes.apple.com/us/app/xcode/id497799835) or [Swift 5.0](https://swift.org/download/#swift-50) to try out `SwiftNIOHTTPClient`.

---

## Getting Started

#### Adding the dependency
Add the following entry in your <code>Package.swift</code> to start using <code>HTTPClient</code>:

```swift
// it's early days here so we haven't tagged a version yet, but will soon
.package(url: "https://github.com/swift-server/swift-nio-http-client.git", .branch("master"))
```
and  `NIOHTTPClient` dependency to your target:
```swift
.target(name: "MyApp", dependencies: ["NIOHTTPClient"]),
```

#### Request-Response API
The code snippet below illustrates how to make a simple GET request to a remote server:

```swift
import NIOHTTPClient

let httpClient = HTTPClient(eventLoopGroupProvider: .createNew)
httpClient.get(url: "https://swift.org").whenComplete { result in
    switch result {
    case .failure(let error):
        // process error
    case .success(let response):
        if let response.status == .ok {
            // handle response
        } else {
            // handle remote error
        }
    }
}
```

It is important to close the client instance, for example in a `defer` statement, after use to cleanly shutdown the underlying NIO `EventLoopGroup`:
```swift
try? httpClient.syncShutdown()
```
Alternatively, you can provide shared `EventLoopGroup`:
```swift
let httpClient = HTTPClient(eventLoopGroupProvider: .shared(userProvidedGroup))
```
In this case shutdown of the client is not neccecary.

## Usage guide

Most common HTTP methods are supported out of the box. In case you need to have more control over the method, or you want to add headers or body, use the `HTTPRequest` struct:
```swift
import NIOHTTPClient

let httpClient = HTTPClient(eventLoopGroupProvider: .createNew)
defer {
    try? httpClient.syncShutdown()
}

var request = try HTTPClient.HTTPRequest(url: "https://swift.org", method: .POST)
request.headers.add(name: "User-Agent", value: "Swift HTTPClient")
request.body = .string("some-body")

httpClient.execute(request: request).whenComplete { result in
    switch result {
    case .failure(let error):
        // process error
    case .success(let response):
        if let response.status == .ok {
            // handle response
        } else {
            // handle remote error
        }
    }
}
```

### Redirects following
Enable follow-redirects behavior using the client configuration:
```swift
let httpClient = HTTPClient(eventLoopGroupProvider: .createNew,
                            configuration: HTTPClient.Configuration(followRedirects: true))
```

### Timeouts
Timeouts (connect and read) can also be set using the client configuration:
```swift
let timeout = HTTPClient.Timeout(connect: .seconds(1), read: .seconds(1))
let httpClient = HTTPClient(eventLoopGroupProvider: .createNew,
                            configuration: HTTPClient.Configuration(timeout: timeout))
```
or on a per-request basis:
```swift
let timeout = HTTPClient.Timeout(connect: .seconds(1), read: .seconds(1))
httpClient.execute(request: request, timeout: timeout)
```

### Streaming
When dealing with larger amount of data, it's critical to stream the response body instead of aggregating in-memory. Handling a response stream is done using a delegate protocol. The following example demonstrates how to count the number of bytes in a streaming response body:
```swift
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
        // this is called when the request is fully read, called once
        // this is where you return a result or throw any errors you require to propagate to the client
        return count
    }

    func didReceiveError(_ error: Error) {
        // this is called when we receive any network-related error, called once
    }
}

let request = try HTTPRequest(url: "https://swift.org")
let delegate = CountingDelegate()

try httpClient.execute(request: request, delegate: delegate).future.whenSuccess { count in
    print(count)
}
```
