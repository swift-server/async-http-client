# Proposal: Async-await support

## Introduction

With the introduction of [async/await][SE-0296] in Swift 5.5, it is now possible to write asynchronous code without the need for callbacks. 

Language support for [`AsyncSequence`][SE-0298] also allows for writing functions that return values over time.

We would like to explore how we could offer APIs that make use of these new language features to allow users to run HTTPRequest using these new idioms.

This proposal describes what these APIs could look like and explores some of the potential usability concerns.

## Proposed API additions

### New `AsyncRequest` type

The proposed new `AsyncRequest` shall be a simple swift structure.

```swift
struct AsyncRequest {
  /// The requests url.
  var url: String
  
  /// The request's HTTPMethod
  var method: HTTPMethod
  
  /// The request's headers
  var headers: HTTPHeaders

  /// The request's body
  var body: Body?
    
  init(url: String) {
    self.url = url
    self.method = .GET
    self.headers = .init()
    self.body = .none
  }
}
```

A notable change from the current [`HTTPRequest`][HTTPRequest] is that the url is not of type `URL`. This makes the creation of a request non throwing. Existing issues regarding current API: 

- [HTTPClient.Request.url is a let constant][issue-395]
- [refactor to make request non-throwing](https://github.com/swift-server/async-http-client/pull/56)
- [improve request validation](https://github.com/swift-server/async-http-client/pull/67)

The url validation will become part of the normal request validation that occurs when the request is scheduled on the `HTTPClient`. If the user supplies a request with an invalid url, the http client, will reject the request.

In normal try/catch flows this should not change the control flow:

```swift
do {
  var request = AsyncRequest(url: "invalidurl")
  try await httpClient.execute(request, deadline: .now() + .seconds(3))
} catch {
  print(error)
}
```

If the library code throws from the AsyncRequest creation or the request invocation the user will, in normal use cases, handle the error in the same catch block. 

#### Body streaming

The new AsyncRequest has a new body type, that is wrapper around an internal enum. This allows us to evolve this type for use-cases that we are not aware of today. 

```swift
public struct Body {
  static func bytes<S: Sequence>(_ sequence: S) -> Body where S.Element == UInt8

  static func stream<S: AsyncSequence>(_ sequence: S) -> Body where S.Element == ByteBuffer

  static func stream<S: AsyncSequence>(_ sequence: S) -> Body where S.Element == UInt8
}
```

The main difference to today's `Request.Body` type is the lack of a `StreamWriter` for streaming scenarios. The existing StreamWriter offered the user an API to write into (thus the user was in control of when writing happened). The new `AsyncRequest.Body` uses `AsyncSequence`s to stream requests. By iterating over the provided AsyncSequence, the HTTPClient is  in control when writes happen, and can ask for more data efficiently. 

Using the `AsyncSequence` from the Swift standard library as our upload stream mechanism dramatically reduces the learning curve for new users.

### New `AsyncResponse` type

The `AsyncResponse` looks more similar to the existing `Response` type. The biggest difference is again the `body` property, which is now an `AsyncSequence` of `ByteBuffer`s instead of a single optional `ByteBuffer?`. This will make every response on AsyncHTTPClient streaming by default.

```swift
public struct AsyncResponse {
  /// the used http version
  public var version: HTTPVersion
  /// the http response status
  public var status: HTTPResponseStatus
  /// the response headers
  public var headers: HTTPHeaders
  /// the response payload as an AsyncSequence
  public var body: Body
}

extension AsyncResponse {
  public struct Body: AsyncSequence {
    public typealias Element = ByteBuffer
    public typealias AsyncIterator = Iterator
  
    public struct Iterator: AsyncIteratorProtocol {
      public typealias Element = ByteBuffer
    
      public func next() async throws -> ByteBuffer?
    }
  
    public func makeAsyncIterator() -> Iterator
  }
}
```

At a later point we could add trailers to the AsyncResponse as effectful properties.

```swift
    public var trailers: HTTPHeaders { async throws }
```

However we will need to make sure that the user has consumed the body stream completely before, calling the trailers, because otherwise we might run into a situation from which we can not progress forward:

```swift
do {
  var request = AsyncRequest(url: "https://swift.org/")
  let response = try await httpClient.execute(request, deadline: .now() + .seconds(3))
  
  var trailers = try await response.trailers // can not move forward since body must be consumed before.
} catch {
  print(error)
}

```

### New invocation

The new way to invoke a request shall look like this:

```swift
extension HTTPClient {
  func execute(_ request: AsyncRequest, deadline: NIODeadline) async throws -> AsyncResponse
}
```

- **Why do we have a deadline in the function signature?** 
    Task deadlines are not part of the Swift 5.5 release. However we think that they are an important tool to not overload the http client accidentally. For this reason we will not default them.
- **What happened to the Logger?** We will use Task locals to propagate the logger metadata. @slashmo and @ktoso are currently working on this.
- **How does cancellation work?** Cancellation works by cancelling the surrounding task:

        ```swift
        let task = Task {
          let response = try await httpClient.execute(request, deadline: .distantFuture)
        }
        
        Task.sleep(500 * 1000 * 1000) // wait half a second
        task.cancel() // cancel the task after half a second
        ```

- **What happens with all the other configuration options?** Currently users can configure a TLSConfiguration on a request.  This API doesn't expose this option. We hope to create a three layer model in the future. For this reason, we currently don't want to add per request configuration on the request invocation. More info can be found in the issue: [RFC: design suggestion: Make this a "3-tier library"][issue-392]
		

[SE-0296]: https://github.com/apple/swift-evolution/blob/main/proposals/0296-async-await.md
[SE-0298]: https://github.com/apple/swift-evolution/blob/main/proposals/0298-asyncsequence.md
[SE-0310]: https://github.com/apple/swift-evolution/blob/main/proposals/0310-effectful-readonly-properties.md
[SE-0314]: https://github.com/apple/swift-evolution/blob/main/proposals/0314-async-stream.md

[issue-392]: https://github.com/swift-server/async-http-client/issues/392
[issue-395]: https://github.com/swift-server/async-http-client/issues/395

[HTTPRequest]: https://github.com/swift-server/async-http-client/blob/main/Sources/AsyncHTTPClient/HTTPHandler.swift#L96-L318