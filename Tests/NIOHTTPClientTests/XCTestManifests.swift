import XCTest

extension HTTPCookieTests {
    static let __allTests = [
        ("testCookie", testCookie),
        ("testCookieDefaults", testCookieDefaults),
    ]
}

extension SwiftHTTPTests {
    static let __allTests = [
        ("testRequestURI", testRequestURI),
        ("testHTTPPartsHandler", testHTTPPartsHandler),
        ("testHTTPPartsHandlerMultiBody", testHTTPPartsHandlerMultiBody),
        ("testGet", testGet),
        ("testPost", testPost),
        ("testGetHttps", testGetHttps),
        ("testPostHttps", testPostHttps),
        ("testHttpRedirect", testHttpRedirect),
        ("testStreaming", testStreaming),
        ("testRemoteClose", testRemoteClose),
        ("testReadTimeout", testReadTimeout),
        ("testReadCancel", testCancel),
    ]
}

#if !os(macOS)
public func __allTests() -> [XCTestCaseEntry] {
    return [
        testCase(HTTPCookieTests.__allTests),
        testCase(SwiftHTTPTests.__allTests),
    ]
}
#endif
