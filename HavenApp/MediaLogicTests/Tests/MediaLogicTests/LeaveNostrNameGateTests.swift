import XCTest
@testable import MediaLogic

/// The last Leave Nostr Forever screen: type the account's name, then hold.
final class LeaveNostrNameGateTests: XCTestCase {
    private let npub = "npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"

    func testNameToTypeIsTheNameElseTheNpubStart() {
        XCTAssertEqual(LeaveNostr.nameToType(name: " Logen ", npub: npub), "Logen")
        XCTAssertEqual(LeaveNostr.nameToType(name: "", npub: npub), String(npub.prefix(12)))
        XCTAssertEqual(LeaveNostr.nameToType(name: "  \n", npub: npub), String(npub.prefix(12)))
    }

    func testTypedNameMustMatchIgnoringCaseAndSpaces() {
        XCTAssertTrue(LeaveNostr.nameConfirms("Logen", expected: "Logen"))
        XCTAssertTrue(LeaveNostr.nameConfirms("  logen \n", expected: "Logen"))
        XCTAssertFalse(LeaveNostr.nameConfirms("Loge", expected: "Logen"))
        XCTAssertFalse(LeaveNostr.nameConfirms("Logen D", expected: "Logen"))
        XCTAssertFalse(LeaveNostr.nameConfirms("", expected: "Logen"))
        XCTAssertFalse(LeaveNostr.nameConfirms("DELETE", expected: "Logen"))
    }

    func testEmptyExpectedNameNeverMatches() {
        XCTAssertFalse(LeaveNostr.nameConfirms("", expected: ""))
        XCTAssertFalse(LeaveNostr.nameConfirms(" ", expected: "  "))
    }

    func testHoldIsThreeSeconds() {
        XCTAssertEqual(LeaveNostr.holdSeconds, 3)
    }
}
