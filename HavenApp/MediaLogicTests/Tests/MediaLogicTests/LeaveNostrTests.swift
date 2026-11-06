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
        let asked = LeaveNostr.vanishTags
        func check(pubkey: String = owner, kind: Int = 62, content: String = "x",
                   tags: [[String]] = LeaveNostr.vanishTags + [["client", "Nostr Vault"]], ownerHex: String = owner) -> Bool {
            LeaveNostr.signedAsAsked(pubkey: pubkey, kind: kind, content: content, tags: tags,
                                     ownerHex: ownerHex, askedKind: 62, askedContent: "x", askedTags: asked)
        }
        XCTAssertTrue(check(pubkey: owner.uppercased()), "an added client tag is fine")
        XCTAssertFalse(check(pubkey: String(repeating: "b", count: 64)), "another key")
        XCTAssertFalse(check(kind: 1), "another kind")
        XCTAssertFalse(check(content: "edited"), "edited content")
        XCTAssertFalse(check(tags: [["client", "Nostr Vault"]]), "ALL_RELAYS dropped")
        XCTAssertFalse(check(tags: [["relay", "wss://one.example"]]), "narrowed to one relay")
        XCTAssertFalse(check(pubkey: "", ownerHex: ""), "no owner")
    }

    func testTheWipeWaitsForAtLeastOneRelay() {
        XCTAssertFalse(LeaveNostr.mayWipe(after: LeaveNostr.Tally(total: 3)), "offline: none answered")
        XCTAssertFalse(LeaveNostr.mayWipe(after: LeaveNostr.Tally(refused: ["a", "b"], total: 2)), "all refused")
        XCTAssertFalse(LeaveNostr.mayWipe(after: LeaveNostr.Tally(total: 0)), "no relays at all")
        XCTAssertTrue(LeaveNostr.mayWipe(after: LeaveNostr.Tally(accepted: ["a"], refused: ["b"], total: 3)))
    }

    func testTallySaysWhoAcceptedRefusedAndStayedSilent() {
        let tally = LeaveNostr.Tally(accepted: ["a", "b"], refused: ["c"], total: 5)
        XCTAssertEqual(tally.summary, "2 of 5 relays accepted the erase request, 1 refused, 2 did not answer")
        XCTAssertEqual(LeaveNostr.Tally(accepted: ["a"], total: 1).summary, "1 of 1 relays accepted the erase request")
    }
}
