import XCTest
@testable import MediaLogic

/// The rules one Auto-Mirror run keeps (Logen 2026-11-12), Apple side.
/// Android twin: `AutoMirrorRulesTest.kt` / `AutoMirrorRunTest.kt` (PR 1983).
/// Rule 1 (never download a photo the vault has) is also covered by
/// `AutoMirrorLedgerTests`; rule 2 (signatures) by `AutoMirrorSigningTests`.
final class AutoMirrorRulesTests: XCTestCase {
    private let hashA = String(repeating: "a", count: 64)
    private let hashB = String(repeating: "b", count: 64)
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Rule 1: the note's imeta `x` names the photo before any download

    func testImetaHashOfPhotoHereSkipsDownload() {
        let url = URL(string: "https://image.nostr.build/photo123.jpg")!
        let known = AutoMirrorLedger.imetaHashes([["imeta", "url \(url.absoluteString)", "x \(hashA.uppercased())", "m image/jpeg"]])
        XCTAssertEqual(known, [url.absoluteString: hashA])
        XCTAssertEqual(AutoMirrorLedger().toDownload([url], localHashes: [hashA], knownHashes: known), [])
        XCTAssertEqual(AutoMirrorLedger().toDownload([url], localHashes: [hashB], knownHashes: known), [url])
    }

    func testTwoLinksToOnePhotoDownloadOnce() {
        let first = URL(string: "https://a.example/one.jpg")!
        let second = URL(string: "https://b.example/two.jpg")!
        let known = [first.absoluteString: hashA, second.absoluteString: hashA]
        XCTAssertEqual(AutoMirrorLedger().toDownload([first, second], localHashes: [], knownHashes: known), [first])
    }

    func testImetaIgnoresOtherTagsAndBadHashes() {
        let tags = [["e", "x"], ["imeta", "url https://a.example/1.jpg", "x nothex"], ["imeta", "x \(hashB)"]]
        XCTAssertEqual(AutoMirrorLedger.imetaHashes(tags), [:])
    }

    // MARK: Rule 3: at most one run per 3 h, counted from when a run starts

    func testRelaunchMidRunDoesNotStartAnother() {
        // Started at t0, killed before it finished: no finish date written.
        let last = AutoMirrorSchedule.lastRun(started: t0, finished: nil)
        XCTAssertFalse(AutoMirrorSchedule.isDue(enabled: true, lastRun: last, now: t0.addingTimeInterval(3600)))
        XCTAssertTrue(AutoMirrorSchedule.isDue(enabled: true, lastRun: last, now: t0.addingTimeInterval(3 * 3600)))
    }

    func testLaterOfStartAndFinishCounts() {
        let older = t0.addingTimeInterval(-10 * 3600)
        XCTAssertEqual(AutoMirrorSchedule.lastRun(started: t0, finished: older), t0)
        XCTAssertEqual(AutoMirrorSchedule.lastRun(started: older, finished: t0), t0)
        XCTAssertNil(AutoMirrorSchedule.lastRun(started: nil, finished: nil))
    }

    func testClockSetBackDoesNotHoldItOffForGood() {
        XCTAssertTrue(AutoMirrorSchedule.isDue(enabled: true, lastRun: t0, now: t0.addingTimeInterval(-60)))
    }

    func testOffNeverRuns() {
        XCTAssertFalse(AutoMirrorSchedule.isDue(enabled: false, lastRun: nil, now: t0))
    }

    // MARK: Rule 4: at most 200 downloads per run, across both halves

    func testRunTakesAtMost200() {
        var limit = AutoMirrorRunLimit()
        let first = limit.take(Array(0..<250))
        XCTAssertEqual(first, Array(0..<200))
        XCTAssertEqual(limit.left, 0)
        XCTAssertEqual(limit.held, 50)
    }

    func testServerAndNoteHalvesShareOneCap() {
        var limit = AutoMirrorRunLimit()
        XCTAssertEqual(limit.take(Array(0..<120)).count, 120)
        XCTAssertEqual(limit.take(Array(0..<100)).count, 80)
        XCTAssertEqual(limit.take([1, 2, 3]), [])
        XCTAssertEqual(limit.held, 23)
    }

    func testUnlimitedTakesEverything() {
        var limit = AutoMirrorRunLimit.unlimited
        XCTAssertEqual(limit.take(Array(0..<1000)).count, 1000)
        XCTAssertEqual(limit.held, 0)
    }

    /// The photos left over are picked up by the next run: rule 1 skips the
    /// ones this run saved, so the next 200 are new ones.
    func testNextRunCarriesOnWithTheRest() {
        let urls = (0..<250).map { URL(string: "https://a.example/\($0).jpg")! }
        var ledger = AutoMirrorLedger()
        var limit = AutoMirrorRunLimit()
        let run1 = limit.take(ledger.toDownload(urls, localHashes: []))
        for (i, url) in run1.enumerated() { ledger.remember(url: url, sha256: String(format: "%064x", i)) }
        var limit2 = AutoMirrorRunLimit()
        let run2 = limit2.take(ledger.toDownload(urls, localHashes: []))
        XCTAssertEqual(run2, Array(urls[200...]))
    }
}
