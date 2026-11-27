import XCTest
@testable import MediaLogic

/// The Vault dot's note scan (RelayProcessManager+NewsDot): pure rules,
/// and the scan kept off the main thread.
final class VaultNewsScanTests: XCTestCase {
    private struct Row { let kind: Int; let pubkey: String; let tags: [[String]]; let at: Int64 }
    private let me = "aa"

    private func newest(_ rows: [Row], modes: Set<String> = ["likes", "replies"]) -> [String: Int64] {
        let own: Set<String> = ["aa", "bb"]
        return VaultNewsAccounts<String>.newest(
            in: rows, modes: modes,
            listing: { $0.kind == 7 ? "likes" : $0.kind == 1 ? "replies" : nil },
            counts: { VaultNewsAccounts<String>.isFromOthersTagging(pubkey: $0.pubkey, tags: $0.tags,
                                                                    account: self.me, own: own) },
            createdAt: { $0.at })
    }

    func testNewestPerListFromOthersTaggingYou() {
        let rows = [
            Row(kind: 7, pubkey: "cc", tags: [["p", "AA"]], at: 10),
            Row(kind: 7, pubkey: "dd", tags: [["e", "x"], ["p", "aa"]], at: 30),
            Row(kind: 1, pubkey: "cc", tags: [["p", "aa"]], at: 20),
        ]
        XCTAssertEqual(newest(rows), ["likes": 30, "replies": 20])
    }

    func testSkipsYourAccountsUntaggedAndOtherLists() {
        let rows = [
            Row(kind: 7, pubkey: "BB", tags: [["p", "aa"]], at: 50), // your other account
            Row(kind: 7, pubkey: "cc", tags: [["p", "zz"]], at: 50), // tags someone else
            Row(kind: 7, pubkey: "cc", tags: [["p"]], at: 50),       // malformed tag
            Row(kind: 1, pubkey: "cc", tags: [["p", "aa"]], at: 50), // list not asked for
            Row(kind: 3, pubkey: "cc", tags: [["p", "aa"]], at: 50), // no list
        ]
        XCTAssertEqual(newest(rows, modes: ["likes"]), [:])
    }

    func testScanRunsOffTheMainThread() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: app.appendingPathComponent(
            "HavenApp/Services/Relay/RelayProcessManager+NewsDot.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("Task.detached"), "the event scan must not run on the main thread")
        XCTAssertFalse(source.contains("NostrService.shared.events.compactMap"),
                       "the old main-thread scan is back")
    }

    /// Tao 2026-11-27: spam replies from outside the web lit the dot within
    /// seconds of each post, while the Vault list hid them. The dot counts
    /// only what the list shows.
    private func shows(_ row: Row, muted: Bool = false) -> Bool {
        let web: Set<String> = ["cc"], blocked: Set<String> = ["ee"]
        return VaultNewsAccounts<String>.listShows(
            kind: row.kind, author: row.pubkey, isMuted: muted,
            isBlocked: { blocked.contains($0) },
            isOutside: { ContentFilter.isOutside(author: $0, owner: self.me, whitelist: [], trusted: web) })
    }

    func testListShowsNothingFromOutsideTheWebButZaps() {
        XCTAssertTrue(shows(Row(kind: 1, pubkey: "cc", tags: [["p", "aa"]], at: 1)), "a reply from your web")
        XCTAssertFalse(shows(Row(kind: 1, pubkey: "ff", tags: [["p", "aa"]], at: 1)), "spam reply from outside")
        XCTAssertFalse(shows(Row(kind: 7, pubkey: "ff", tags: [["p", "aa"]], at: 1)), "like from outside")
        XCTAssertTrue(shows(Row(kind: 9735, pubkey: "ff", tags: [["p", "aa"]], at: 1)), "zap from outside")
        XCTAssertFalse(shows(Row(kind: 1, pubkey: "ee", tags: [["p", "aa"]], at: 1)), "blocked")
        XCTAssertFalse(shows(Row(kind: 1, pubkey: "cc", tags: [["p", "aa"]], at: 1), muted: true), "muted")
    }

    func testOutsideSpamDoesNotLightTheDot() {
        let own: Set<String> = ["aa", "bb"]
        let rows = [
            Row(kind: 1, pubkey: "ff", tags: [["p", "aa"]], at: 90), // spam reply, newest
            Row(kind: 1, pubkey: "cc", tags: [["p", "aa"]], at: 20),
        ]
        let newest = VaultNewsAccounts<String>.newest(
            in: rows, modes: ["replies"],
            listing: { $0.kind == 1 ? "replies" : nil },
            counts: { VaultNewsAccounts<String>.isFromOthersTagging(pubkey: $0.pubkey, tags: $0.tags,
                                                                    account: self.me, own: own) && self.shows($0) },
            createdAt: { $0.at })
        XCTAssertEqual(newest, ["replies": 20])
    }

    func testDotScanUsesTheListRules() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: app.appendingPathComponent(
            "HavenApp/Services/Relay/RelayProcessManager+NewsDot.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("&& shows($0)"), "the dot's scan must skip what the Vault list hides")
        XCTAssertTrue(source.contains("relayTabTrustedPubkeys()"), "the list's web")
    }
}
