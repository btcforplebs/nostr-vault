import XCTest
@testable import MediaLogic

/// Import media reads every one of the owner's notes, not just the newest
/// 250: the vault answers a query with at most 250, and Import media used to
/// send one query.
final class OwnerNotePagerTests: XCTestCase {
    struct Note { let id: String; let pubkey: String; let createdAt: Int; var media: String { "https://blossom.example/\(id).jpg" } }
    private let owner = String(repeating: "1", count: 64)

    /// The vault: newest first, `until` inclusive, never more than `cap` per answer.
    private func store(_ notes: [Note], cap: Int = 250) -> (Int?) async -> [Note] {
        { until in
            Array(notes.filter { until == nil || $0.createdAt <= until! }.sorted { $0.createdAt > $1.createdAt }.prefix(cap))
        }
    }

    private func collect(_ fetch: (Int?) async -> [Note]) async -> [Note] {
        await OwnerNotePager.collect(owner: owner, id: \.id, pubkey: \.pubkey, createdAt: \.createdAt, fetch: fetch)
    }

    func testMoreThan250OwnerNotesAreAllReadDownToTheOldest() async {
        let notes = (0..<600).map { Note(id: "n\($0)", pubkey: owner, createdAt: 1_700_000_000 + $0) }
        var pages = 0
        let fetch = store(notes)
        let got = await collect { pages += 1; return await fetch($0) }
        XCTAssertEqual(got.count, 600)
        XCTAssertTrue(got.map(\.media).contains("https://blossom.example/n0.jpg"), "the oldest note's media is found")
        XCTAssertEqual(pages, 4) // 250 + 250 + 100 new, then one page with nothing new
    }

    func testNotesSharingASecondAcrossAPageEdgeAreNotLost() async {
        let notes = (0..<300).map { Note(id: "n\($0)", pubkey: owner, createdAt: 1_700_000_000 + $0 / 3) }
        let got = await collect(store(notes))
        XCTAssertEqual(got.count, 300)
    }

    func testOtherAuthorsAreLeftOutAndAnEmptyVaultEndsAtOnce() async {
        let notes = (0..<10).map { Note(id: "o\($0)", pubkey: owner, createdAt: $0) }
            + (0..<10).map { Note(id: "s\($0)", pubkey: "stranger", createdAt: $0) }
        let got = await collect(store(notes))
        XCTAssertEqual(got.count, 10)
        var pages = 0
        let none = await collect { _ in pages += 1; return [] }
        XCTAssertEqual(none.count, 0)
        XCTAssertEqual(pages, 1)
    }

    func testFilterAsksForTheOwnersNotesAtOrBeforeUntil() {
        let first = OwnerNotePager.filter(owner: owner, until: nil)
        XCTAssertNil(first["until"])
        XCTAssertEqual(first["authors"] as? [String], [owner])
        XCTAssertEqual(OwnerNotePager.filter(owner: owner, until: 42)["until"] as? Int, 42)
    }
}

/// One Import media by itself when the first Moving in finishes; a keyless
/// vault goes in-process, a keyed one signs its upload as before.
final class MediaImportAfterMovingInTests: XCTestCase {
    private final class State { var started = false; var runs = 0; var mediaImportedAt: Date?; var runResult = true }

    private func rule(_ s: State) -> MediaImportAfterMovingInRule {
        MediaImportAfterMovingInRule(
            started: { s.started }, markStarted: { s.started = true },
            mediaImportedAt: { s.mediaImportedAt }, runImport: { s.runs += 1; return s.runResult })
    }

    func testFirstMovingInStartsOneImportMediaLaterOnesNone() {
        let s = State()
        XCTAssertTrue(rule(s).movingInDone())
        XCTAssertFalse(rule(s).movingInDone())
        XCTAssertEqual(s.runs, 1)
    }

    func testNoRunWhenImportMediaAlreadyRanHere() {
        let s = State()
        s.mediaImportedAt = Date()
        XCTAssertFalse(rule(s).movingInDone())
        XCTAssertEqual(s.runs, 0)
    }

    func testARunAlreadyGoingCountsAsTheOne() {
        let s = State()
        s.runResult = false
        rule(s).movingInDone()
        rule(s).movingInDone()
        XCTAssertEqual(s.runs, 1)
    }

    func testKeylessVaultGoesInProcessKeyedSignsAsBefore() {
        XCTAssertEqual(OwnVaultUpload.route(keyless: true), .inProcess)
        XCTAssertEqual(OwnVaultUpload.route(keyless: false), .signedUpload)
    }
}
