import AsyncHTTPClient
import Foundation
import NIOCore
import NIOFoundationCompat

struct Todo: Codable {
    var id: Int?
    var userId: Int
    var title: String
    var completed: Bool
}

@main
struct PostJSON {
    static func main() async throws {
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
        let payload = Todo(userId: 1, title: "Test Todo", completed: false)

        do {
            let jsonData = try JSONEncoder().encode(payload)

            var request = HTTPClientRequest(url: "https://jsonplaceholder.typicode.com/todos")
            request.method = .POST
            request.headers.add(name: "Content-Type", value: "application/json")
            request.body = .bytes(jsonData)

            let response = try await httpClient.execute(request, timeout: .seconds(30))
            print("HTTP head", response)
        } catch {
            print("request failed:", error)
        }
        // it is important to shutdown the httpClient after all requests are done, even if one failed
        try await httpClient.shutdown()
    }
}
