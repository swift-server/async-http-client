import AsyncHTTPClient
import Foundation
import NIOCore
import NIOFoundationCompat

@main
struct DeleteJSON {
    static func main() async throws {
        let httpClient = HTTPClient.shared

        do {
            var request = HTTPClientRequest(url: "https://jsonplaceholder.typicode.com/todos/1")
            request.method = .DELETE

            let response = try await httpClient.execute(request, timeout: .seconds(30))
            print("HTTP head", response)
        } catch {
            print("request failed:", error)
        }
    }
}
