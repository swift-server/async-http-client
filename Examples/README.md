# Examples
This folder includes a couple of Examples for `AsyncHTTPClient`. 
You can run them by opening the `Package.swift` in this folder through Xcode.
In Xcode you can then select the scheme for the example you want run e.g. `GetHTML`.

You can also run the examples from the command line by executing the follow command in this folder:
```
swift run GetHTML
```
To run other examples you can just replace `GetHTML` with the name of the example you want to run.

## [GetHTML](./GetHTML/GetHTML.swift)

This examples sends a HTTP GET request to `https://apple.com/` and first `await`s and `print`s the HTTP Response Head. 
Afterwards it buffers the full response body in memory and prints the response as a `String`.    

## [GetJSON](./GetJSON/GetJSON.swift)

This examples sends a HTTP GET request to `https://xkcd.com/info.0.json` and first `await`s and `print`s the HTTP Response Head. 
Afterwards it buffers the full response body in memory, decodes the buffer using a `JSONDecoder` and `dump`s the decoded response. 

## [StreamingByteCounter](./StreamingByteCounter/StreamingByteCounter.swift)

This examples sends a HTTP GET request to `https://apple.com/` and first `await`s and `print`s the HTTP Response Head. 
Afterwards it asynchronously iterates over all body fragments, counts the received bytes and prints a progress indicator (if the server send a content-length header).
At the end the total received bytes are printed.
Note that we drop all received fragment and therefore do **not** buffer the whole response body in-memory.
