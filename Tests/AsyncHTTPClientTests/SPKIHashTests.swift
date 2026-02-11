import XCTest
@testable import AsyncHTTPClient
import Crypto

final class SPKIHashTests: XCTestCase {

    // MARK: - Initialization (custom algorithm + base64)

    func testInitWithSHA384AndValidBase64() throws {
        let base64 = Data(repeating: 0, count: 48).base64EncodedString()
        let hash = try SPKIHash(algorithm: SHA384.self, base64: base64)
        XCTAssertEqual(hash.bytes.count, 48)
        XCTAssertEqual(hash.bytes, Data(repeating: 0, count: 48))
    }

    func testInitWithSHA384AndWrongLengthThrows() throws {
        let base64 = Data(repeating: 0, count: 32).base64EncodedString()
        XCTAssertThrowsError(try SPKIHash(algorithm: SHA384.self, base64: base64)) { error in
            XCTAssertEqual(error as? HTTPClientError, .invalidDigestLength)
        }
    }

    // MARK: - Initialization (raw bytes)

    func testInitWithSHA256AndValidBytes() throws {
        let bytes = Data(repeating: 0, count: 32)
        let hash = try SPKIHash(algorithm: SHA256.self, bytes: bytes)
        XCTAssertEqual(hash.bytes, bytes)
    }

    func testInitWithSHA512AndValidBytes() throws {
        let bytes = Data(repeating: 0, count: 64)
        let hash = try SPKIHash(algorithm: SHA512.self, bytes: bytes)
        XCTAssertEqual(hash.bytes, bytes)
    }

    func testInitWithWrongByteCountThrows() throws {
        let bytes = Data(repeating: 0, count: 31)
        XCTAssertThrowsError(try SPKIHash(algorithm: SHA256.self, bytes: bytes)) { error in
            XCTAssertEqual(error as? HTTPClientError, .invalidDigestLength)
        }
    }

    // MARK: - Initialization (convenience bytes initializer)

    func testConvenienceBytesInitializerUsesSHA256() throws {
        let bytes = Data([UInt8](0..<32))
        let hash1 = try SPKIHash(algorithm: SHA256.self, bytes: bytes)
        let hash2 = try SPKIHash(algorithm: SHA256.self, bytes: bytes)
        XCTAssertEqual(hash1, hash2)
    }

    // MARK: - Equality

    func testEqualityWithSameBytesAndAlgorithm() throws {
        let bytes = Data(repeating: 0, count: 32)
        let hash1 = try SPKIHash(algorithm: SHA256.self, bytes: bytes)
        let hash2 = try SPKIHash(algorithm: SHA256.self, bytes: bytes)
        XCTAssertEqual(hash1, hash2)
    }

    func testInequalityWithSameBytesDifferentAlgorithm() throws {
        let hash1 = try SPKIHash(algorithm: SHA256.self, bytes: Data(repeating: 0, count: 32))
        let hash2 = try SPKIHash(algorithm: SHA384.self, bytes: Data(repeating: 0, count: 48))
        XCTAssertNotEqual(hash1, hash2)
    }

    func testInequalityWithDifferentBytesSameAlgorithm() throws {
        let hash1 = try SPKIHash(algorithm: SHA256.self, bytes: Data(repeating: 0, count: 32))
        let hash2 = try SPKIHash(algorithm: SHA256.self, bytes: Data(repeating: 1, count: 32))
        XCTAssertNotEqual(hash1, hash2)
    }

    // MARK: - Hashable

    func testHashableWithEqualValues() throws {
        let bytes = Data(repeating: 0, count: 32)
        let hash1 = try SPKIHash(algorithm: SHA256.self, bytes: bytes)
        let hash2 = try SPKIHash(algorithm: SHA256.self, bytes: bytes)

        var set = Set<SPKIHash>()
        set.insert(hash1)
        set.insert(hash2)
        XCTAssertEqual(set.count, 1)
    }

    func testHashableWithDifferentAlgorithms() throws {
        let hash1 = try SPKIHash(algorithm: SHA256.self, bytes: Data(repeating: 0, count: 32))
        let hash2 = try SPKIHash(algorithm: SHA384.self, bytes: Data(repeating: 0, count: 48))

        var set = Set<SPKIHash>()
        set.insert(hash1)
        set.insert(hash2)
        XCTAssertEqual(set.count, 2)
    }

    // MARK: - Real-world test vectors

    func testSHA256EmptyInputHash() throws {
        let expectedBase64 = "47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU="
        let hash = try SPKIHash(algorithm: SHA256.self, base64: expectedBase64)

        let expectedBytes = Data([
            0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14,
            0x9a, 0xfb, 0xf4, 0xc8, 0x99, 0x6f, 0xb9, 0x24,
            0x27, 0xae, 0x41, 0xe4, 0x64, 0x9b, 0x93, 0x4c,
            0xa4, 0x95, 0x99, 0x1b, 0x78, 0x52, 0xb8, 0x55
        ])
        XCTAssertEqual(hash.bytes, expectedBytes)
    }

    func testSHA384EmptyInputHash() throws {
        let emptyHash = Data(SHA384.hash(data: Data()))
        let base64 = emptyHash.base64EncodedString()
        let hash = try SPKIHash(algorithm: SHA384.self, base64: base64)
        XCTAssertEqual(hash.bytes, emptyHash)
    }
}
