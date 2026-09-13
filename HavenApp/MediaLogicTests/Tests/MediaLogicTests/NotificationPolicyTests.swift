import XCTest
@testable import MediaLogic

final class NotificationPolicyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

    // MARK: - Absence summaries

    func testAnnouncesAfterARealAbsence() {
        XCTAssertTrue(NotificationPolicy.shouldAnnounceAbsenceSummary(
            now: now,
            lastForegroundAt: ago(6 * 3600),
            lastAnnouncedAt: nil
        ))
    }

    /// The bug this whole policy exists for: a background wake every few
    /// minutes ran the same catch-up round and announced it every time.
    func testDoesNotAnnounceForAShortGapBetweenBackgroundWakes() {
        XCTAssertFalse(NotificationPolicy.shouldAnnounceAbsenceSummary(
            now: now,
            lastForegroundAt: ago(15 * 60),
            lastAnnouncedAt: nil
        ))
    }

    func testAnnouncesOnlyOncePerAbsence() {
        let leftAt = ago(6 * 3600)
        // A summary already fired an hour into this absence.
        XCTAssertFalse(NotificationPolicy.shouldAnnounceAbsenceSummary(
            now: now,
            lastForegroundAt: leftAt,
            lastAnnouncedAt: leftAt.addingTimeInterval(3600)
        ))
        // The next absence, after the user came back and left again, is fair game.
        XCTAssertTrue(NotificationPolicy.shouldAnnounceAbsenceSummary(
            now: now,
            lastForegroundAt: ago(3 * 3600),
            lastAnnouncedAt: ago(20 * 3600)
        ))
    }

    func testTheThresholdIsInclusive() {
        XCTAssertTrue(NotificationPolicy.shouldAnnounceAbsenceSummary(
            now: now,
            lastForegroundAt: ago(NotificationPolicy.minimumAbsence),
            lastAnnouncedAt: nil
        ))
        XCTAssertFalse(NotificationPolicy.shouldAnnounceAbsenceSummary(
            now: now,
            lastForegroundAt: ago(NotificationPolicy.minimumAbsence - 1),
            lastAnnouncedAt: nil
        ))
    }

    func testNeverForegroundedMeansNoAbsenceToDescribe() {
        XCTAssertFalse(NotificationPolicy.shouldAnnounceAbsenceSummary(
            now: now,
            lastForegroundAt: nil,
            lastAnnouncedAt: nil
        ))
    }

    // MARK: - Feed counting

    func testCountsOnlyNotesNewerThanTheWatermark() {
        let dates = [ago(3600), ago(600), ago(60), ago(10)]
        XCTAssertEqual(
            NotificationPolicy.unannouncedFeedNoteCount(createdAt: dates, lastAnnouncedNoteAt: ago(900)),
            3
        )
    }

    /// Backfill: older notes arriving into the list are not news. The old count
    /// was list growth, which could not tell the difference.
    func testBackfilledOlderNotesDoNotCount() {
        let watermark = ago(600)
        let dates = [ago(50_000), ago(40_000), ago(30_000), watermark]
        XCTAssertEqual(
            NotificationPolicy.unannouncedFeedNoteCount(createdAt: dates, lastAnnouncedNoteAt: watermark),
            0
        )
    }

    func testNoWatermarkAnnouncesNothing() {
        XCTAssertEqual(
            NotificationPolicy.unannouncedFeedNoteCount(createdAt: [ago(10), ago(20)], lastAnnouncedNoteAt: nil),
            0
        )
    }

    // MARK: - Kinds handed to the relay

    func testKindsFollowThePreferences() {
        XCTAssertEqual(
            NotificationPolicy.notifyKinds(mentionsOrReplies: true, dms: true, zaps: true, reactions: false, reposts: false),
            [1, 4, 1059, 9735]
        )
        XCTAssertEqual(
            NotificationPolicy.notifyKinds(mentionsOrReplies: false, dms: false, zaps: false, reactions: true, reposts: true),
            [6, 7]
        )
    }

    /// An empty list means "no preference" to the relay, so "nothing enabled"
    /// has to be spelled with a kind that never notifies.
    func testNothingEnabledIsNotAnEmptyList() {
        let kinds = NotificationPolicy.notifyKinds(
            mentionsOrReplies: false, dms: false, zaps: false, reactions: false, reposts: false
        )
        XCTAssertEqual(kinds, [NotificationPolicy.silentKind])
        XCTAssertFalse(kinds.isEmpty)
    }
}
