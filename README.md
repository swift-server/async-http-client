# AsyncHTTPClient
This package provides simple HTTP Client library built on top of SwiftNIO.

This library provides the following:
1. Asynchronous and non-blocking request methods
2. Simple follow-redirects (cookie headers are dropped)
3. Streaming body download
4. TLS support
5. Cookie parsing (but not storage)

---

**NOTE**: You will need [Xcode 10.2](https://itunes.apple.com/us/app/xcode/id497799835) or [Swift 5.0](https://swift.org/download/#swift-50) to try out `AsyncHTTPClient`.

---

## Getting Started

#### Adding the dependency
Add the following entry in your <code>Package.swift</code> to start using <code>HTTPClient</code>:

```swift
.package(url: "https://github.com/swift-server/async-http-client.git", from: "1.0.0")
```
and  `AsyncHTTPClient` dependency to your target:
```swift
.target(name: "MyApp", dependencies: ["AsyncHTTPClient"]),
```

#### Request-Response API

The code snippet below illustrates how to make a simple GET request to a remote server.

Please note that the example will spawn a new `EventLoopGroup` which will _create fresh threads_ which is a very costly operation. In a real-world application that uses [SwiftNIO](https://github.com/apple/swift-nio) for other parts of your application (for example a web server), please prefer `eventLoopGroupProvider: .shared(myExistingEventLoopGroup)` to share the `EventLoopGroup` used by AsyncHTTPClient with other parts of your application.

If your application does not use SwiftNIO yet, it is acceptable to use `eventLoopGroupProvider: .createNew` but please make sure to share the returned `HTTPClient` instance throughout your whole application. Do not create a large number of `HTTPClient` instances with `eventLoopGroupProvider: .createNew`, this is very wasteful and might exhaust the resources of your program.

```swift
import AsyncHTTPClient

let httpClient = HTTPClient(eventLoopGroupProvider: .createNew)
httpClient.get(url: "https://swift.org").whenComplete { result in
    switch result {
    case .failure(let error):
        // process error
    case .success(let response):
        if response.status == .ok {
            // handle response
        } else {
            // handle remote error
        }
    }
}
```

You should always shut down `HTTPClient` instances you created using `try httpClient.syncShutdown()`. Please note that you must not call `httpClient.syncShutdown` before all requests of the HTTP client have finished, or else the in-flight requests will likely fail because their network connections are interrupted.

## Usage guide

Most common HTTP methods are supported out of the box. In case you need to have more control over the method, or you want to add headers or body, use the `HTTPRequest` struct:
```swift
import AsyncHTTPClient

let httpClient = HTTPClient(eventLoopGroupProvider: .createNew)
defer {
    try? httpClient.syncShutdown()
}

var request = try HTTPClient.Request(url: "https://swift.org", method: .POST)
request.headers.add(name: "User-Agent", value: "Swift HTTPClient")
request.body = .string("some-body")

httpClient.execute(request: request).whenComplete { result in
    switch result {
    case .failure(let error):
        // process error
    case .success(let response):
        if response.status == .ok {
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
httpClient.execute(request: request, deadline: .now() + .milliseconds(1))
```

### Streaming
When dealing with larger amount of data, it's critical to stream the response body instead of aggregating in-memory. Handling a response stream is done using a delegate protocol. The following example demonstrates how to count the number of bytes in a streaming response body:
```swift
import NIO
import NIOHTTP1

class CountingDelegate: HTTPClientResponseDelegate {
    typealias Response = Int

    var count = 0

    func didSendRequestHead(task: HTTPClient.Task<Response>, _ head: HTTPRequestHead) {
        // this is executed right after request head was sent, called once
    }

    func didSendRequestPart(task: HTTPClient.Task<Response>, _ part: IOData) {
        // this is executed when request body part is sent, could be called zero or more times
    }

    func didSendRequest(task: HTTPClient.Task<Response>) {
        // this is executed when request is fully sent, called once
    }

    func didReceiveHead(task: HTTPClient.Task<Response>, _ head: HTTPResponseHead) -> EventLoopFuture<Void> {
        // this is executed when we receive HTTP Reponse head part of the request (it contains response code and headers), called once
        // in case backpressure is needed, all reads will be paused until returned future is resolved
        return task.eventLoop.makeSucceededFuture(())
    }

    func didReceiveBodyPart(task: HTTPClient.Task<Response>, _ buffer: ByteBuffer) -> EventLoopFuture<Void> {
        // this is executed when we receive parts of the response body, could be called zero or more times
        count += buffer.readableBytes
        // in case backpressure is needed, all reads will be paused until returned future is resolved
        return task.eventLoop.makeSucceededFuture(())
    }

    func didFinishRequest(task: HTTPClient.Task<Response>) throws -> Int {
        // this is called when the request is fully read, called once
        // this is where you return a result or throw any errors you require to propagate to the client
        return count
    }

    func didReceiveError(task: HTTPClient.Task<Response>, _ error: Error) {
        // this is called when we receive any network-related error, called once
    }
}

let request = try HTTPClient.Request(url: "https://swift.org")
let delegate = CountingDelegate()

httpClient.execute(request: request, delegate: delegate).futureResult.whenSuccess { count in
    print(count)
}
```
