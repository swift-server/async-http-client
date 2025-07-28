import AsyncHTTPClient
import Foundation
import NIOCore
import NIOFoundationCompat

@main
struct DeleteJSON {
    static func main() async throws {
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)

        do {
            var request = HTTPClientRequest(url: "http://localhost:8080/todos/1)")
            request.method = .DELETE

            let response = try await httpClient.execute(request, timeout: .seconds(30))
            print("HTTP head", response)
        } catch {
            print("request failed:", error)
        }
        // it is important to shutdown the httpClient after all requests are done, even if one failed
        try await httpClient.shutdown()
    }
}
