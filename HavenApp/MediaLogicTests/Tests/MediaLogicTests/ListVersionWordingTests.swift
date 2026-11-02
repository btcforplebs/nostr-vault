import XCTest
@testable import MediaLogic

/// The words on List backups' versions page and its Restore / Merge previews
/// (Logen 2026-11-02): which app saved a version, its size and change, the
/// wipe flag's text, and "Will follow again" / "Will unfollow".
final class ListVersionWordingTests: XCTestCase {
    private func p(_ n: Int) -> String { let h = String(n, radix: 16); return String(repeating: "0", count: 64 - h.count) + h }
    private func v(_ kind: Int, _ tags: [[String]], content: String = "") -> ListVersion {
        ListVersion(id: UUID().uuidString, pubkey: "me", kind: kind, createdAt: 1, tags: tags, content: content)
    }
    private func follows(_ ns: ClosedRange<Int>, client: String? = nil) -> ListVersion {
        v(3, (client.map { [["client", $0]] } ?? []) + ns.map { ["p", p($0)] })
    }

    func testAppIsTheClientTagElseUnknown() {
        XCTAssertEqual(ListVersionWording.app(follows(1...3, client: "Primal")), "Primal")
        XCTAssertEqual(ListVersionWording.app(v(3, [["client", "Amethyst", "31990:abc:def"], ["client", "Other"]])), "Amethyst")
        XCTAssertEqual(ListVersionWording.app(follows(1...3)), "An unknown app")
        XCTAssertEqual(ListVersionWording.app(v(3, [["client", "  "]])), "An unknown app")
        XCTAssertEqual(ListVersionWording.savedBy(follows(1...3)), "saved by an unknown app")
        XCTAssertEqual(ListVersionWording.savedBy(follows(1...3, client: "Primal")), "saved by Primal")
    }

    func testCountUsesTheListsWord() {
        XCTAssertEqual(ListVersionWording.count(follows(1...300, client: "Primal")), "300 follows")
        XCTAssertEqual(ListVersionWording.count(follows(1...1)), "1 follow")
        XCTAssertEqual(ListVersionWording.count(v(10000, [["p", p(1)], ["word", "x"]])), "2 muted")
        XCTAssertEqual(ListVersionWording.count(v(10000, [["p", p(1)]], content: "abc")), "1 muted + private")
        XCTAssertEqual(ListVersionWording.count(v(10050, [["relay", "wss://a"], ["relay", "wss://b"]])), "2 relays")
        XCTAssertEqual(ListVersionWording.count(v(10002, [["r", "wss://a"]])), "1 item")
        XCTAssertEqual(ListVersionWording.count(v(10003, [])), "0 bookmarks")
        XCTAssertEqual(ListVersionWording.count(v(10004, [["a", "x"], ["a", "y"]])), "2 communities")
    }

    func testDetailIsTheChangeAgainstTheOlderVersion() {
        let big = follows(1...1009, client: "Nostr Vault")
        let wiped = follows(1...300, client: "Primal")
        XCTAssertEqual(ListVersionWording.detail(wiped, older: big), "300 follows, −709")
        XCTAssertEqual(ListVersionWording.detail(follows(1...303), older: wiped), "303 follows, +3")
        XCTAssertEqual(ListVersionWording.detail(follows(2...4), older: follows(1...3)), "3 follows, +1, −1")
        XCTAssertEqual(ListVersionWording.detail(follows(1...3), older: follows(1...3, client: "X")), "3 follows, no change")
        XCTAssertEqual(ListVersionWording.detail(big, older: nil), "1009 follows")
        XCTAssertEqual(ListVersionWording.wipedFlag, "This one wiped your list")
    }

    func testTitlesSayWhatHappensToPeople() {
        XCTAssertEqual(ListVersionWording.titles(3), .init(back: "Will follow again", out: "Will unfollow", stays: "Still following"))
        XCTAssertEqual(ListVersionWording.titles(10000), .init(back: "Will mute again", out: "Will unmute", stays: "Still muted"))
        XCTAssertEqual(ListVersionWording.titles(10003).back, "Will add back")
        XCTAssertEqual(ListVersionWording.titles(10003).out, "Will remove")
        XCTAssertEqual(ListVersionWording.followMergeLine(added: 709, removed: 0), "Saves your follows: you follow 709 again.")
        XCTAssertEqual(ListVersionWording.followMergeLine(added: 709, removed: 2), "Saves your follows: you follow 709 again, 2 unfollowed.")
        XCTAssertTrue(ListVersionWording.mergeExplainer(3).contains("everyone you follow now"))
        XCTAssertTrue(ListVersionWording.mergeExplainer(10003).contains("everything in your list now"))
    }

    func testPersonKeysOnly() {
        XCTAssertEqual(ListVersionWording.person("p\u{0}" + p(5).uppercased()), p(5))
        XCTAssertNil(ListVersionWording.person("p\u{0}abc"))
        XCTAssertNil(ListVersionWording.person("t\u{0}" + p(5)))
        XCTAssertNil(ListVersionWording.person("relay\u{0}wss://a"))
    }
}
