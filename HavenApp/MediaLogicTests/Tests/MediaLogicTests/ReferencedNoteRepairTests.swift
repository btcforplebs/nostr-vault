import XCTest
@testable import MediaLogic

/// Stand-in for `FeedNote` carrying only the fields the repair logic reads.
private struct Row: ReferencedNoteRow {
    let id: String
    var parentEventId: String? = nil
    var repostedEventId: String? = nil
    var quotedEventIds: [String] = []
    var threadRootEventId: String? = nil
}

final class ReferencedNoteRepairTests: XCTestCase {

    /// The bug this exists for: a reply's parent lands in the cache and the row
    /// must be named for re-resolution, or it renders its skeleton forever.
    func testReplyRowIsRepairedWhenItsParentArrives() {
        let rows = [Row(id: "reply", parentEventId: "parent"), Row(id: "unrelated")]
        XCTAssertEqual(
            ReferencedNoteRepair.rowsNeedingRepair(notes: rows, arrivedIds: ["parent"]),
            ["reply"]
        )
    }

    func testRepostRowIsRepairedWhenItsOriginalArrives() {
        let rows = [Row(id: "repost", repostedEventId: "original")]
        XCTAssertEqual(
            ReferencedNoteRepair.rowsNeedingRepair(notes: rows, arrivedIds: ["original"]),
            ["repost"]
        )
    }

    func testQuotingRowIsRepairedWhenAnyQuotedNoteArrives() {
        let rows = [Row(id: "quoter", quotedEventIds: ["q1", "q2"])]
        XCTAssertEqual(
            ReferencedNoteRepair.rowsNeedingRepair(notes: rows, arrivedIds: ["q2"]),
            ["quoter"]
        )
    }

    /// One arriving note can be the parent of several visible replies.
    func testEveryRowReferencingTheSameArrivalIsRepaired() {
        let rows = [
            Row(id: "a", parentEventId: "p"),
            Row(id: "b", parentEventId: "p"),
            Row(id: "c", parentEventId: "other")
        ]
        XCTAssertEqual(
            ReferencedNoteRepair.rowsNeedingRepair(notes: rows, arrivedIds: ["p"]),
            ["a", "b"]
        )
    }

    /// A row referencing an arrival through more than one field is named once,
    /// and the early `continue` must not hide its other references.
    func testRowMatchingOnParentAndQuoteIsReturnedOnce() {
        let rows = [Row(id: "both", parentEventId: "p", quotedEventIds: ["q"])]
        XCTAssertEqual(
            ReferencedNoteRepair.rowsNeedingRepair(notes: rows, arrivedIds: ["p", "q"]),
            ["both"]
        )
    }

    /// Re-resolving is not free — an arrival nothing on screen references must
    /// produce no work.
    func testUnreferencedArrivalRepairsNothing() {
        let rows = [Row(id: "a", parentEventId: "p")]
        XCTAssertTrue(
            ReferencedNoteRepair.rowsNeedingRepair(notes: rows, arrivedIds: ["stranger"]).isEmpty
        )
    }

    func testEmptyArrivalSetRepairsNothing() {
        let rows = [Row(id: "a", parentEventId: "p")]
        XCTAssertTrue(
            ReferencedNoteRepair.rowsNeedingRepair(notes: rows, arrivedIds: []).isEmpty
        )
    }

    /// A row is identified by its own id, never by the id that arrived — the
    /// row-data cache is keyed by the referencing note.
    func testArrivedIdIsNeverReturnedAsARowToRepair() {
        let rows = [Row(id: "reply", parentEventId: "parent")]
        let repaired = ReferencedNoteRepair.rowsNeedingRepair(notes: rows, arrivedIds: ["parent"])
        XCTAssertFalse(repaired.contains("parent"))
    }

    // MARK: - referencedIds

    /// The eviction bug behind a thread card stuck on "Loading the start of
    /// this thread...": a deep reply's root is nobody's parent, so trimming the
    /// cache on parent edges alone threw away the root that had just been
    /// fetched for it.
    func testReferencedIdsKeepsAThreadRootThatIsNoRowsParent() {
        let rows = [Row(id: "deep", parentEventId: "middle", threadRootEventId: "root")]
        XCTAssertEqual(ReferencedNoteRepair.referencedIds(in: rows), ["middle", "root"])
    }

    func testReferencedIdsCoversRepostOriginalsAndQuotes() {
        let rows = [
            Row(id: "repost", repostedEventId: "original"),
            Row(id: "quoter", quotedEventIds: ["q1", "q2"]),
        ]
        XCTAssertEqual(ReferencedNoteRepair.referencedIds(in: rows), ["original", "q1", "q2"])
    }

    func testReferencedIdsIsEmptyForNotesThatReferenceNothing() {
        XCTAssertTrue(ReferencedNoteRepair.referencedIds(in: [Row(id: "a"), Row(id: "b")]).isEmpty)
    }
}
