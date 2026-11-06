import XCTest
@testable import MediaLogic

final class FeedAccountKeyTests: XCTestCase {
    private let oldMain = "npub1old"
    private let newMain = "npub1new"

    func testMainAccountIsKeyedByItsNpubNotOwner() {
        XCTAssertEqual(FeedAccountKey.key(activeNpub: "", ownerNpub: oldMain), oldMain)
        XCTAssertEqual(FeedAccountKey.key(activeNpub: "  ", ownerNpub: " \(oldMain)\n"), oldMain)
    }

    /// The bug: a new account after a factory reset got the old one's key.
    func testAccountSetUpAfterResetGetsItsOwnKey() {
        XCTAssertNotEqual(FeedAccountKey.key(activeNpub: "", ownerNpub: oldMain),
                          FeedAccountKey.key(activeNpub: "", ownerNpub: newMain))
    }

    func testActiveAccountWins() {
        XCTAssertEqual(FeedAccountKey.key(activeNpub: "npub1second", ownerNpub: oldMain), "npub1second")
    }

    func testNoAccountIsEmptyKey() {
        XCTAssertEqual(FeedAccountKey.key(activeNpub: "", ownerNpub: ""), "")
    }

    func testLegacyOwnerFilesAreDeletedAndNothingElse() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("FeedAccountKeyTests-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let kept = ["config.json", "feed_snapshot_\(newMain).json", "following_snapshots_\(newMain).json",
                    "composer_draft_owner.json"]
        for name in FeedAccountKey.legacyOwnerFiles + kept {
            try Data("{}".utf8).write(to: dir.appendingPathComponent(name))
        }
        FeedAccountKey.removeLegacyOwnerFiles(in: dir, fileManager: fm)
        let left = Set(try fm.contentsOfDirectory(atPath: dir.path))
        XCTAssertEqual(left, Set(kept))
    }
}
