import XCTest

import SwiftNIOHTTPTests

var tests = [XCTestCaseEntry]()
tests += SwiftNIOHTTPTests.__allTests()

XCTMain(tests)
