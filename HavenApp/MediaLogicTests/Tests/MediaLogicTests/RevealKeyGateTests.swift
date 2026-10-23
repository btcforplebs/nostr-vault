import XCTest
@testable import MediaLogic

final class RevealKeyGateTests: XCTestCase {
    func testEmptyFieldRevealsNothing() {
        XCTAssertNil(RevealKeyGate.password(typed: ""))
    }

    func testTypedPasswordIsUsedAsTyped() {
        XCTAssertEqual(RevealKeyGate.password(typed: "hunter22"), "hunter22")
        XCTAssertEqual(RevealKeyGate.password(typed: " "), " ")
    }
}
