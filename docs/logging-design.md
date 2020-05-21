# Design of the way AsyncHTTPClient logs

<details>
  <summary>The logging is strictly separated between request activity & background activity.</summary>
  AsyncHTTPClient is very much a request-driven library. Almost all work happens when you invoke a request, say `httpClient.get(someURL)`. To preserve the metadata you may have attached to your current `Logger`, we accept a `logger: Logger` parameter on each request. For example to so a `GET` request with logging use the following code.

```swift
httpClient.get(someURL, logger: myLogger)
```

  Apart from the request-driven work, AsyncHTTPClient does do some very limited amount of background work, for example expiring connections that stayed unused in the connection pool for too long. Logs associated with the activity from background tasks can be seen only if you attach a `Logger` in `HTTPClient`'s initialiser like below.

```swift
HTTPClient(eventLoopGroupProvider: .shared(group),
           backgroundActivityLogger: self.myBackgroundLogger)
```

The rationale for the strict separation is the correct propagation of the `Logger`'s `metadata`. You are likely to attach request specific information to a `Logger` before passing it to one of AsyncHTTPClient's request methods. This metadata will then be correctly attached to all log messages that occur from AsyncHTTPClient processing this request.

If AsyncHTTPClient does some work in the background (like closing a connection that was long idle) however you likely do _not_ want the request-specific information from some previous request to be attached to those messages. Therefore, those messages get logged with the `backgroundActivityLogger` passed to HTTPClient's initialiser.
</details>
<details>
  <summary>Unless you explicitly pass AsyncHTTPClient a `Logger` instance, nothing is ever logged.</summary>
  AsyncHTTPClient is useful in many places where you wouldn't want to log, for example a command line HTTP client. Also, we do not want to change its default behaviour in a minor release.
</details>
<details>
  <summary>Nothing is logged at level `info` or higher, unless something is really wrong that cannot be communicated through the API.</summary>
  Fundamentally, AsyncHTTPClient performs a simple task, it makes a HTTP request and communicates the outcome back via its API. In normal usage, we would not expect people to want AsyncHTTPClient to log. In certain scenarios, for example when debugging why a request takes longer than expected it may however be useful to get information about AsyncHTTPClient's connection pool. That is when enabling logging may become useful.
</details>
<details>
  <summary>Each request will get a globally unique request ID (`ahc-request-id`) that will be attached (as metadata) to each log message relevant to a request.</summary>
  When many concurrent requests are active, it can be challenging to figure out which log message is associated with which request. To facilitate this task, AsyncHTTPClient will add a metadata field `ahc-request-id` to each log message so you can first find the request ID that is causing issues and then filter only messages with that ID.
</details>
<details>
  <summary>Your `Logger` metadata is preserved.</summary>
  AsyncHTTPClient accepts a `Logger` on every request method. This means that all the metadata you have attached, will be present on log messages issued by AsyncHTTPClient.

 For example, if you attach `["my-system-req-uuid": "84B453E0-0DFD-4B4B-BF22-3434812C9015"]` and then do two requests using AsyncHTTPClient, both of those requests will carry `"my-system-req-uuid` as well as AsyncHTTPClient's `ahc-request-id`. This allows you to filter all HTTP request made from one of your system's requests whilst still disambiguating the HTTP requests (they will have different `ahc-request-id`s.
</details>
<details>
  <summary>Instead of accepting one `Logger` instance per `HTTPClient` instance, each request method can accept a `Logger`.</summary>
  This allows AsyncHTTPClient to preserve your metadata and add its own metadata such as `ahc-request-id`.
</details>
<details>
  <summary>All logs use the [structured logging](https://www.sumologic.com/glossary/structured-logging/) pattern, i.e. only static log messages and accompanying key/value metadata are used.</summary>
  None of the log messages issued by AsyncHTTPClient will use String interpolation which means they will always be the exact same message.

  For example when AsyncHTTPClient wants to tell you it got an actual network connection to perform a request on, it will give the logger the following pieces of information:

  - message: `got connection for request`
  - metadata (the values are example):
    - `ahc-request-id`: `0`
    - `ahc-connection`: `SocketChannel { BaseSocket { fd=15 }, active = true, localAddress = Optional([IPv4]127.0.0.1/127.0.0.1:54459), remoteAddress = Optional([IPv4]127.0.0.1/127.0.0.1:54457) }`

  As you can see above, the log message doesn't actually contain the request or the network connection. Both of those pieces of information are in the `metadata`.

  The rationale is that many people use log aggregation systems where it is very useful to aggregate, search and group by log message, or specific metadata values. This is greatly simplified by using a constant string (relatively stable) string and explicitly marked metadata values which make it easy to filter by.
</details>
<details>
  <summary>`debug` should be enough to diagnose most problems but information that can be correlated is usually skipped.</summary>
  When crafting log messages, it's often hard to strike a balance between logging everything and logging just enough. A rule of thumb is that you have to assume someone may be running with `logLevel = .debug` in production. So it can't be too much. Yet `.trace` can log everything you would need to know when debugging a tricky implementation issue. We assume nobody is running in production with `logLevel = .trace`.

  The problem with logging everything is that logging itself becomes very slow. We want logging in `debug` level to still be reasonably performant and therefore avoid logging information that can be correlated from other log messages.

  For example, AsyncHTTPClient may tell you in two log messages that it `got a connection` (from the connection pool) and a little later that it's `parking connection` (in the connection pool). Just like all messages, both of them will have an associated `ahc-request-id` which makes it possible to correlate the two log messages. The message that logs that we actually got a network connection will also include information about this network connection. The message that we're now parking the connection however _will not_. The information which connection is being parked can be found by filtering all other log messages with the same `ahc-request-id`.
</details>
<details>
  <summary>In `trace`, AsyncHTTPClient may log _a lot_.</summary>
  In the `.trace` log level, AsyncHTTPClient basically logs all the information that it has handily available. The frugality considerations we take in `.debug` do not apply here. We just want to log as much information as possible. This is useful almost exclusively for local debugging and should almost certainly not be sent into a log aggregation system where the information might be persisted for a long time. This also means, handing AsyncHTTPClient a logger in `logLevel = .trace` may have a fairly serious performance impact.
</details>
