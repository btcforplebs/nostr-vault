import XCTest
@testable import MediaLogic

/// Nuclear unfollow (RESEARCH/NV_NUCLEAR_UNFOLLOW_SPEC.md): who goes, what the
/// new follow list keeps, and when the second warning shows. Keys here are
/// made up; nothing is signed or published.
final class NuclearUnfollowPlanTests: XCTestCase {
    private let x = String(repeating: "aa", count: 32)
    private let b1 = String(repeating: "b1", count: 32)
    private let b2 = String(repeating: "b2", count: 32)
    private let keep = String(repeating: "cc", count: 32)

    func testRemovalIsTheCheckedPeopleAndXWhenFollowed() {
        XCTAssertEqual(NuclearUnfollowPlan.removal(checked: [b1, b2], target: x, follows: [x, keep]), [b1, b2, x])
        XCTAssertEqual(NuclearUnfollowPlan.removal(checked: [b1], target: x, follows: [keep]), [b1],
                       "X not followed: only the checked people")
        XCTAssertEqual(NuclearUnfollowPlan.removal(checked: [B1upper], target: x, follows: []), [b1], "keys compare lowercased")
    }
    private var B1upper: String { b1.uppercased() }

    func testNewListKeepsEveryOtherTagInOrder() {
        let base: [[String]] = [["p", keep, "wss://r.example", "pet"], ["p", b1], ["t", "nostr"], ["p", x.uppercased()],
                                ["p", b2], ["e", "x"]]
        guard case .ready(let tags) = NuclearUnfollowPlan.newTags(base: base, removing: [b1, b2, x]) else {
            return XCTFail("expected a new list")
        }
        XCTAssertEqual(tags, [["p", keep, "wss://r.example", "pet"], ["t", "nostr"], ["e", "x"]])
    }

    func testRefusesNoListAndAnEmptiedListUnchangedWhenNoOneIsIn() {
        if case .refuse = NuclearUnfollowPlan.newTags(base: nil, removing: [b1]) {} else { XCTFail("no list to start from") }
        if case .refuse = NuclearUnfollowPlan.newTags(base: [["p", b1], ["t", "x"]], removing: [b1]) {} else {
            XCTFail("would follow no one")
        }
        XCTAssertEqual(NuclearUnfollowPlan.newTags(base: [["p", keep]], removing: [b1]), .unchanged)
    }

    func testDoubleWarningFromTwentyFive() {
        XCTAssertFalse(NuclearUnfollowPlan.needsSecondWarning(24))
        XCTAssertTrue(NuclearUnfollowPlan.needsSecondWarning(25))
        XCTAssertEqual(NuclearUnfollowPlan.confirmTitle(1), "Unfollow 1 person")
        XCTAssertEqual(NuclearUnfollowPlan.confirmTitle(30), "Unfollow 30 people")
    }

    /// The backup comes before anything is signed: the screen's "Backup
    /// saved ✓" fires from the vault step that ListVersionSave runs first.
    func testBackupIsKeptBeforePublishing() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let save = try String(contentsOf: app.appendingPathComponent("HavenApp/Services/Nostr/NostrService+ListVersionSave.swift"), encoding: .utf8)
        XCTAssertTrue(save.contains("if kept { await MainActor.run { onUndoCopyKept?() } }"))
        let service = try String(contentsOf: app.appendingPathComponent("HavenApp/Services/NuclearUnfollowService.swift"), encoding: .utf8)
        XCTAssertTrue(service.contains("saveListVersion(kind: 3, author: me, verb: \"unfollow\""))
    }
}
