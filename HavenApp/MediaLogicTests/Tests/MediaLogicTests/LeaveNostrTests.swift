import XCTest
@testable import MediaLogic

final class LeaveNostrTests: XCTestCase {
    func testOnlyTheExactWordConfirms() {
        XCTAssertTrue(LeaveNostr.confirms("DELETE"))
        XCTAssertTrue(LeaveNostr.confirms("  DELETE\n"))
        XCTAssertFalse(LeaveNostr.confirms("delete"))
        XCTAssertFalse(LeaveNostr.confirms("DELET"))
        XCTAssertFalse(LeaveNostr.confirms("DELETE IT"))
        XCTAssertFalse(LeaveNostr.confirms(""))
    }

    func testEraseRequestIsNIP62ForAllRelays() {
        XCTAssertEqual(LeaveNostr.vanishKind, 62)
        XCTAssertEqual(LeaveNostr.vanishTags, [["relay", "ALL_RELAYS"]])
    }

    func testBlankProfileHasEveryFieldEmptyAndTheDeletedFlag() throws {
        let data = Data(LeaveNostr.blankProfileContent.utf8)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["name", "display_name", "about", "picture", "banner", "website", "nip05", "lud16", "lud06"] {
            XCTAssertEqual(fields[key] as? String, "", key)
        }
        XCTAssertEqual(fields["deleted"] as? Bool, true)
    }

    func testRelaysAreEveryListOnceWssOnlyBlockedLeftOut() {
        let relays = LeaveNostr.relays(
            write: ["wss://relay.damus.io/", "wss://write.example"],
            read: ["wss://relay.damus.io", "wss://Read.example", "ws://127.0.0.1:3355", "ws://localhost:4869"],
            dm: ["wss://dm.example", "wss://blocked.example/x", "ws://192.168.1.20:7777", "https://not.a.relay"],
            own: ["wss://mine.example"],
            blocked: ["wss://blocked.example"])
        XCTAssertEqual(relays, ["wss://mine.example", "wss://relay.damus.io", "wss://write.example",
                                "wss://Read.example", "wss://dm.example", "ws://192.168.1.20:7777"])
    }

    func testOnlyTheOwnersOwnSignatureOfTheAskedEventCounts() {
        let owner = String(repeating: "a", count: 64)
        XCTAssertTrue(LeaveNostr.signedAsAsked(pubkey: owner.uppercased(), kind: 62, content: "x",
                                               ownerHex: owner, askedKind: 62, askedContent: "x"))
        XCTAssertFalse(LeaveNostr.signedAsAsked(pubkey: String(repeating: "b", count: 64), kind: 62, content: "x",
                                                ownerHex: owner, askedKind: 62, askedContent: "x"))
        XCTAssertFalse(LeaveNostr.signedAsAsked(pubkey: owner, kind: 1, content: "x",
                                                ownerHex: owner, askedKind: 62, askedContent: "x"))
        XCTAssertFalse(LeaveNostr.signedAsAsked(pubkey: owner, kind: 62, content: "edited",
                                                ownerHex: owner, askedKind: 62, askedContent: "x"))
        XCTAssertFalse(LeaveNostr.signedAsAsked(pubkey: "", kind: 62, content: "x",
                                                ownerHex: "", askedKind: 62, askedContent: "x"))
    }

    func testTallySaysWhoAcceptedRefusedAndStayedSilent() {
        let tally = LeaveNostr.Tally(accepted: ["a", "b"], refused: ["c"], total: 5)
        XCTAssertEqual(tally.summary, "2 of 5 relays accepted the erase request, 1 refused, 2 did not answer")
        XCTAssertEqual(LeaveNostr.Tally(accepted: ["a"], total: 1).summary, "1 of 1 relays accepted the erase request")
    }
}
