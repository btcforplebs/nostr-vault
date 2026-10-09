import XCTest
@testable import MediaLogic

/// The rules the iOS home vault sender runs on.
final class HomeVaultLogicTests: XCTestCase {
    private let npub = "npub1" + String(repeating: "q", count: 58)
    private let other = "npub1" + String(repeating: "p", count: 58)

    func testOnlyTheExactMeshEntryFormIsAVault() {
        XCTAssertEqual(HomeVaultLogic.meshNpub(fromEntry: "fipsmesh://\(npub)/"), npub)
        XCTAssertNil(HomeVaultLogic.meshNpub(fromEntry: "fipsmesh://\(npub)"), "no trailing slash")
        XCTAssertNil(HomeVaultLogic.meshNpub(fromEntry: "fipsmesh://\(npub)q"), "no slash, one more bech32 char")
        XCTAssertNil(HomeVaultLogic.meshNpub(fromEntry: "fipsmesh://\(npub):80/"), "a port")
        XCTAssertNil(HomeVaultLogic.meshNpub(fromEntry: "fipsmesh://\(npub)/evil"), "a path")
        XCTAssertNil(HomeVaultLogic.meshNpub(fromEntry: "fipsmesh://npub1short/"), "not an npub")
        XCTAssertNil(HomeVaultLogic.meshNpub(fromEntry: "fipsmesh://npub1" + String(repeating: "b", count: 58) + "/"), "b is not bech32")
        XCTAssertNil(HomeVaultLogic.meshNpub(fromEntry: "https://blossom.primal.net/"))
    }

    func testChoicesSkipThisPhoneAndDuplicates() {
        let list = ["https://blossom.band/", "fipsmesh://\(npub)/", "fipsmesh://\(other)/", "fipsmesh://\(npub)/"]
        XCTAssertEqual(HomeVaultLogic.meshEntries(serverList: list, excluding: nil), [npub, other])
        XCTAssertEqual(HomeVaultLogic.meshEntries(serverList: list, excluding: npub), [other])
    }

    func testMediaQueuesAheadOfNotesSoANoteNeverLandsFirst() {
        func item(_ kind: HomeVaultItem.Kind, _ id: String) -> HomeVaultItem {
            HomeVaultItem(kind: kind, id: id, ownerHex: "aa", eventJSON: nil, contentType: nil, added: Date(), attempts: 0)
        }
        let queue = [item(.blob, "b1"), item(.event, "e1"), item(.event, "e2")]
        XCTAssertEqual(HomeVaultLogic.insertionIndex(for: .blob, in: queue), 1)
        XCTAssertNil(HomeVaultLogic.insertionIndex(for: .event, in: queue), "notes go last")
        XCTAssertNil(HomeVaultLogic.insertionIndex(for: .blob, in: [item(.blob, "b1")]), "no notes waiting: append")
    }

    func testTheWebsocketKeepsTheTokenPath() {
        let base = URL(string: "http://127.0.0.1:41234/0123456789abcdef0123456789abcdef")!
        XCTAssertEqual(HomeVaultLogic.websocketURL(base: base)?.absoluteString,
                       "ws://127.0.0.1:41234/0123456789abcdef0123456789abcdef")
    }

    func testOkAnswers() {
        XCTAssertEqual(HomeVaultLogic.okResult(#"["OK","abc",true,""]"#, id: "abc"), .sent)
        XCTAssertEqual(HomeVaultLogic.okResult(#"["OK","abc",false,"duplicate: have it"]"#, id: "abc"), .sent)
        XCTAssertEqual(HomeVaultLogic.okResult(#"["OK","abc",false,"blocked: not the owner"]"#, id: "abc"),
                       .rejected("blocked: not the owner"))
        XCTAssertNil(HomeVaultLogic.okResult(#"["OK","other",true,""]"#, id: "abc"), "someone else's OK")
        XCTAssertNil(HomeVaultLogic.okResult(#"["NOTICE","hi"]"#, id: "abc"))
        XCTAssertNil(HomeVaultLogic.okResult("not json", id: "abc"))
    }

    func testUploadStatuses() {
        XCTAssertEqual(HomeVaultLogic.uploadResult(status: 200), .sent)
        XCTAssertEqual(HomeVaultLogic.uploadResult(status: 201), .sent)
        XCTAssertEqual(HomeVaultLogic.uploadResult(status: 403), .rejected("HTTP 403"), "not the owner: retrying won't help")
        XCTAssertEqual(HomeVaultLogic.uploadResult(status: 413), .rejected("HTTP 413"))
        XCTAssertEqual(HomeVaultLogic.uploadResult(status: 429), .unreachable("HTTP 429"), "rate limit is about now")
        XCTAssertEqual(HomeVaultLogic.uploadResult(status: 404), .unreachable("HTTP 404"), "a kiosk without the upload door keeps the blob queued")
        XCTAssertEqual(HomeVaultLogic.uploadResult(status: 502), .unreachable("HTTP 502"))
        XCTAssertEqual(HomeVaultLogic.uploadResult(status: 0), .unreachable("HTTP 0"))
    }

    func testQueueSurvivesARoundTrip() throws {
        let item = HomeVaultItem(kind: .event, id: "e1", ownerHex: "aa", eventJSON: #"{"id":"e1"}"#, contentType: nil,
                                 added: Date(timeIntervalSince1970: 1_000), attempts: 2)
        let back = try JSONDecoder().decode([HomeVaultItem].self, from: JSONEncoder().encode([item]))
        XCTAssertEqual(back, [item])
    }
}
