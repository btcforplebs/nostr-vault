import XCTest
@testable import MediaLogic

/// A posted or deleted draft whose relay copy missed its kind 5 doesn't come
/// back on the next fetch.
final class DraftTombstonesTests: XCTestCase {
    func testADeletedDraftsRelayCopyStaysHidden() {
        var t = DraftTombstones()
        let saved = Date(timeIntervalSince1970: 1_000)
        t.record(id: "d1", at: Date(timeIntervalSince1970: 2_000))
        XCTAssertTrue(t.hides(id: "d1", updatedAt: saved), "the old relay copy came back")
        XCTAssertFalse(t.hides(id: "d2", updatedAt: saved))
        // A later save under the same id is a real draft again.
        XCTAssertFalse(t.hides(id: "d1", updatedAt: Date(timeIntervalSince1970: 3_000)))
    }

    func testTheDeleteSurvivesARelaunch() throws {
        var t = DraftTombstones()
        t.record(id: "d1", at: Date(timeIntervalSince1970: 2_000))
        let back = try JSONDecoder().decode(DraftTombstones.self, from: JSONEncoder().encode(t))
        XCTAssertTrue(back.hides(id: "d1", updatedAt: Date(timeIntervalSince1970: 1_000)))
    }

    func testOldDeletesAreForgottenAndAReSaveRevives() {
        var t = DraftTombstones()
        let now = Date(timeIntervalSince1970: 10_000_000)
        t.record(id: "old", at: now.addingTimeInterval(-DraftTombstones.keep - 1))
        t.record(id: "new", at: now)
        t.prune(now: now)
        XCTAssertFalse(t.hides(id: "old", updatedAt: .distantPast))
        XCTAssertTrue(t.hides(id: "new", updatedAt: now))
        t.forget(id: "new")
        XCTAssertFalse(t.hides(id: "new", updatedAt: now))
    }
}
