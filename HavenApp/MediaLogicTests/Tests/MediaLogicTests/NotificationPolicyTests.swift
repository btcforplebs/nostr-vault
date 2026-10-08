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
            [1, 4, 1059, 1111, 9735]
        )
        XCTAssertEqual(
            NotificationPolicy.notifyKinds(mentionsOrReplies: false, dms: false, zaps: false, reactions: true, reposts: true),
            [6, 7, 16]
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

    /// Phone notifications off: a DM still gets the in-app banner while the app
    /// is open, and nothing else gets through.
    func testPushOffAllowsOnlyForegroundDMs() {
        XCTAssertTrue(NotificationPolicy.allowsWithPushOff(type: "giftwrap", appInForeground: true))
        XCTAssertTrue(NotificationPolicy.allowsWithPushOff(type: "dm", appInForeground: true))
        XCTAssertFalse(NotificationPolicy.allowsWithPushOff(type: "giftwrap", appInForeground: false))
        for type in ["mention", "reply", "quote", "zap", "reaction", "repost", "summary"] {
            XCTAssertFalse(NotificationPolicy.allowsWithPushOff(type: type, appInForeground: true), type)
        }
    }

    /// A decrypted DM becomes one readable banner line.
    func testDMPreviewIsOneLine() {
        XCTAssertEqual(NotificationPolicy.dmPreview("hey\n\n  are you  around?\t"), "hey are you around?")
    }

    /// Nothing to read keeps the generic line.
    func testDMPreviewOfBlankIsNil() {
        XCTAssertNil(NotificationPolicy.dmPreview(""))
        XCTAssertNil(NotificationPolicy.dmPreview(" \n\t "))
    }

    func testDMPreviewIsCutToTheLimit() {
        let long = String(repeating: "a", count: 300)
        let preview = NotificationPolicy.dmPreview(long, limit: 160)
        XCTAssertEqual(preview?.count, 160)
        XCTAssertEqual(preview?.last, "…")
        XCTAssertEqual(NotificationPolicy.dmPreview(String(repeating: "b", count: 160), limit: 160)?.count, 160)
    }
}

final class NotificationAuthorTrustTests: XCTestCase {
    func testOnlyTrustedAuthorsNotify() {
        let trusted: Set<String> = ["friend"]
        XCTAssertTrue(NotificationPolicy.authorMayNotify("friend", type: "reply", trusted: trusted, own: []))
        XCTAssertFalse(NotificationPolicy.authorMayNotify("stranger", type: "reply", trusted: trusted, own: []))
        XCTAssertFalse(NotificationPolicy.authorMayNotify("stranger", type: "dm", trusted: trusted, own: []))
        // Graph not loaded, own events, gift wraps and the summary are not held back.
        XCTAssertTrue(NotificationPolicy.authorMayNotify("stranger", type: "reply", trusted: [], own: []))
        XCTAssertTrue(NotificationPolicy.authorMayNotify("me", type: "zap", trusted: trusted, own: ["me"]))
        XCTAssertTrue(NotificationPolicy.authorMayNotify("throwaway", type: "giftwrap", trusted: trusted, own: []))
        // The receipt is signed by the lightning service, never in anyone's WoT.
        XCTAssertTrue(NotificationPolicy.authorMayNotify("lnurl-service", type: "zap", trusted: trusted, own: []))
        // A follow is never dropped for trust; followIsNamed decides how it is told.
        XCTAssertTrue(NotificationPolicy.authorMayNotify("stranger", type: "follow", trusted: trusted, own: []))
        XCTAssertTrue(NotificationPolicy.authorMayNotify("stranger", type: "follow", trusted: [], own: []))
    }

    /// Only a follower in your Web of Trust is named; a stranger, and everyone
    /// on a new account with no graph yet, goes to the nameless folded alert.
    func testOnlyTrustedFollowersAreNamed() {
        XCTAssertTrue(NotificationPolicy.followIsNamed("friend", trusted: ["friend"]))
        XCTAssertFalse(NotificationPolicy.followIsNamed("stranger", trusted: ["friend"]))
        XCTAssertFalse(NotificationPolicy.followIsNamed("friend", trusted: []))
    }

    /// The folded alert counts each stranger once, keeps counting while it is
    /// still showing, and starts over once it was tapped or cleared.
    func testFoldedFollowersCountEachStrangerOnce() {
        typealias Fold = NotificationPolicy.FoldedFollowers
        var showing = NotificationPolicy.foldedFollowers(showing: Fold(), adding: "a")
        XCTAssertFalse(Fold().isShowing)
        XCTAssertTrue(showing.isShowing)
        showing = NotificationPolicy.foldedFollowers(showing: showing, adding: "b")
        showing = NotificationPolicy.foldedFollowers(showing: showing, adding: "a")
        XCTAssertEqual(showing, Fold(members: ["b", "a"], count: 2))
        XCTAssertEqual(NotificationPolicy.foldedFollowers(showing: Fold(), adding: "c"), Fold(members: ["c"], count: 1))
        XCTAssertEqual(NotificationPolicy.foldedFollowersText(count: 1).0, "New follower")
        XCTAssertEqual(NotificationPolicy.foldedFollowersText(count: 3).0, "3 new followers")
    }

    /// Only the latest strangers ride in the alert, so it stays small; the
    /// count keeps going past them.
    func testFoldedFollowersKeepCountingPastTheCap() {
        var showing = NotificationPolicy.FoldedFollowers()
        for i in 0..<1000 { showing = NotificationPolicy.foldedFollowers(showing: showing, adding: "k\(i)") }
        XCTAssertEqual(showing.count, 1000)
        XCTAssertEqual(showing.members.count, 32)
        XCTAssertEqual(showing.members.last, "k999")
        // An alert saved before the count was stored counts its members.
        let old = NotificationPolicy.FoldedFollowers(members: ["a", "b"], count: 0)
        XCTAssertEqual(NotificationPolicy.foldedFollowers(showing: old, adding: "c").count, 3)
    }

    func testFollowerKeyMustBe64Hex() {
        XCTAssertTrue(NotificationPolicy.isPubkeyHex(String(repeating: "ab", count: 32)))
        XCTAssertFalse(NotificationPolicy.isPubkeyHex(""))
        XCTAssertFalse(NotificationPolicy.isPubkeyHex(String(repeating: "zz", count: 32)))
    }
}

final class NotificationPreferencesDecodingTests: XCTestCase {
    /// Settings saved before "New Followers" existed must keep every switch the
    /// user set and pick up the new one's default, not fail to decode.
    func testOldPayloadKeepsSwitchesAndDefaultsFollowsOn() throws {
        let old = #"{"mentions":false,"replies":true,"dms":true,"zaps":false,"reactions":true,"reposts":true}"#
        let prefs = try JSONDecoder().decode(NotificationPreferences.self, from: Data(old.utf8))
        XCTAssertFalse(prefs.mentions)
        XCTAssertFalse(prefs.zaps)
        XCTAssertTrue(prefs.reactions)
        XCTAssertTrue(prefs.reposts)
        XCTAssertTrue(prefs.follows)
    }

    func testFollowsRoundTrips() throws {
        var prefs = NotificationPreferences()
        prefs.follows = false
        let decoded = try JSONDecoder().decode(NotificationPreferences.self, from: JSONEncoder().encode(prefs))
        XCTAssertEqual(decoded, prefs)
    }
}
