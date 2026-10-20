import XCTest
@testable import MediaLogic

/// withCStrings stands in for the bridged-NSString pointers at every key-to-Go
/// call, so the order and contents of what Go reads must be exact.
final class CStringArgumentsTests: XCTestCase {

    func testPassesEachStringInOrder() {
        let read = withCStrings(["nsec-hex", "", "ünïcödé ✓"]) { pointers in
            pointers.map { String(cString: $0) }
        }
        XCTAssertEqual(read, ["nsec-hex", "", "ünïcödé ✓"])
    }

    func testHandsOverNulTerminatedUTF8() {
        let bytes = withCStrings(["é"]) { pointers in
            (0..<3).map { UInt8(bitPattern: pointers[0][$0]) }
        }
        XCTAssertEqual(bytes, [0xC3, 0xA9, 0x00])
    }

    func testNoStringsStillRunsTheBody() {
        XCTAssertEqual(withCStrings([]) { $0.count }, 0)
    }

    func testReturnsTheBodyResult() {
        let length = withCStrings(["abc", "de"]) { strlen($0[0]) + strlen($0[1]) }
        XCTAssertEqual(length, 5)
    }
}
