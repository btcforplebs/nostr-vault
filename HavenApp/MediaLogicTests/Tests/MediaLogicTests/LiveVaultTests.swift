import XCTest
@testable import MediaLogic

/// The iPad's Live Vault column: drawn rows never jump, new lines go on top by themselves.
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

    func testFoldedKeyIsPerAccountLowercased() {
        XCTAssertEqual(LiveVault.foldedKey("ABC"), "nv-space-folded:abc")
    }

    func testPlaceWithoutASnapshotTakesOne() {
        let lines = [line("a", at: 100), line("b", at: 90)]
        XCTAssertEqual(LiveVault.place(lines, nil), LiveVault.snapshot(lines))
    }

    func testNewLinesGoOnTopByThemselvesAndDrawnRowsKeepTheirSlots() {
        let shot = LiveVault.snapshot([line("a", at: 100), line("b", at: 90)])
        // "b" gained a face and moved up the list; "n" and "m" are new; "late" came in late.
        let now = [line("n", at: 130), line("m", at: 120), line("b", at: 110, actors: ["bob", "ann"]),
                   line("a", at: 100), line("late", at: 95)]
        let next = LiveVault.place(now, shot)
        XCTAssertEqual(next.ids, ["n", "m", "a", "b", "late"])
        XCTAssertEqual(next.top, 130)
        let (rows, held) = LiveVault.split(now, next)
        XCTAssertEqual(rows.map(\.id), ["n", "m", "a", "b", "late"])
        XCTAssertTrue(held.isEmpty)
    }

    func testPlaceKeepsAtMostMaxRowsAndNeverMovesTopBack() {
        let old = (0..<LiveVault.maxRows).map { line("o\($0)", at: Int64(500 - $0)) }
        let shot = LiveVault.snapshot(old)
        let next = LiveVault.place([line("new", at: 600)] + old, shot)
        XCTAssertEqual(next.ids.count, LiveVault.maxRows)
        XCTAssertEqual(next.ids.first, "new")
        XCTAssertEqual(next.ids.last, "o\(LiveVault.maxRows - 2)")
        // A line gone from the list doesn't pull the newest moment back.
        XCTAssertEqual(LiveVault.place([line("o1", at: 499)], next).top, 600)
    }
}
