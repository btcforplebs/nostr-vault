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
}
