import XCTest
@testable import MediaLogic

/// The iPad's Live Vault column: rows never jump, new lines wait behind the pill.
final class LiveVaultTests: XCTestCase {
    private func line(_ id: String, at: Int64, actors: [String] = ["ann"]) -> VaultActivity {
        VaultActivity(id: id, kind: .reaction, actors: actors, createdAt: at, openId: id, preview: "")
    }

    func testSnapshotTakesTheFirstRowsAndTheNewestMoment() {
        let lines = (0..<40).map { line("l\($0)", at: Int64(1000 - $0)) }
        let shot = LiveVault.snapshot(lines)
        XCTAssertEqual(shot.ids.count, LiveVault.maxRows)
        XCTAssertEqual(shot.ids.first, "l0")
        XCTAssertEqual(shot.top, 1000)
        XCTAssertEqual(LiveVault.snapshot([], now: 7).top, 7)
    }

    func testNewerLinesWaitBehindThePillAndDrawnRowsKeepTheirSlots() {
        let shot = LiveVault.snapshot([line("a", at: 100), line("b", at: 90)])
        // "b" gained a face and moved to the top of the list; "n" is new.
        let now = [line("n", at: 120), line("b", at: 110, actors: ["bob", "ann"]), line("a", at: 100)]
        let (rows, held) = LiveVault.split(now, shot)
        XCTAssertEqual(rows.map(\.id), ["a", "b"])
        XCTAssertEqual(rows[1].actors, ["bob", "ann"])
        XCTAssertEqual(held.map(\.id), ["n"])
    }

    func testLateOlderLinesGoBelowAndGoneLinesDropOut() {
        let shot = LiveVault.snapshot([line("a", at: 100), line("b", at: 90)])
        let (rows, held) = LiveVault.split([line("a", at: 100), line("late", at: 95)], shot)
        XCTAssertEqual(rows.map(\.id), ["a", "late"])
        XCTAssertTrue(held.isEmpty)
    }

    func testFacesAreUniqueNewestFirstWithACountOfTheRest() {
        let lines = [line("1", at: 3, actors: ["a", "b"]), line("2", at: 2, actors: ["b", "c", "d", "e", "f"])]
        let (faces, more) = LiveVault.faces(lines)
        XCTAssertEqual(faces, ["a", "b", "c", "d", "e"])
        XCTAssertEqual(more, 1)
    }

    func testPillPrefersUnreadThenHeld() {
        XCTAssertEqual(LiveVault.pillCount(unread: 3, held: 1), 3)
        XCTAssertEqual(LiveVault.pillCount(unread: 0, held: 2), 2)
        XCTAssertEqual(LiveVault.pillCount(unread: 0, held: 0), 0)
        XCTAssertEqual(LiveVault.foldedKey("ABC"), "nv-space-folded:abc")
    }
}
