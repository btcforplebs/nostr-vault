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

    /// One event is one key, however its id is written.
    func testDedupKeyNormalisesTheEventId() {
        let id = "ab12CD34" + String(repeating: "0", count: 56)
        XCTAssertEqual(NotificationPolicy.dedupKey(eventId: id), NotificationPolicy.dedupKey(eventId: " \(id.lowercased())\n"))
        XCTAssertNotEqual(NotificationPolicy.dedupKey(eventId: id), NotificationPolicy.dedupKey(eventId: "other"))
    }

    /// An arrival pill that times out without ever drawing is filed.
    func testPillTimedOutUndrawnIsFiled() {
        XCTAssertTrue(NotificationPolicy.filesPill(end: .timedOut, drawnFor: 0))
        XCTAssertTrue(NotificationPolicy.filesPill(end: .trimmed, drawnFor: 0))
    }

    /// Drawn for a moment is not read: still filed.
    func testPillDrawnTooBrieflyIsFiled() {
        XCTAssertTrue(NotificationPolicy.filesPill(end: .timedOut, drawnFor: 0.1))
        XCTAssertTrue(NotificationPolicy.filesPill(end: .trimmed, drawnFor: NotificationPolicy.pillReadableAfter - 0.01))
    }

    /// Losing the window or the foreground follows the read rule: a pill
    /// that only flashed is filed, one that was read is not filed again.
    func testPillHostLostFollowsTheReadRule() {
        XCTAssertTrue(NotificationPolicy.filesPill(end: .hostLost, drawnFor: 0))
        XCTAssertTrue(NotificationPolicy.filesPill(end: .hostLost, drawnFor: NotificationPolicy.pillReadableAfter - 0.01))
        XCTAssertFalse(NotificationPolicy.filesPill(end: .hostLost, drawnFor: NotificationPolicy.pillReadableAfter))
        XCTAssertFalse(NotificationPolicy.filesPill(end: .hostLost, drawnFor: 10))
    }

    /// A push and the relay's alert for one event share a key.
    func testEventKeyMatchesPushAndMarker() {
        let id = "AB12" + String(repeating: "0", count: 60)
        let push: [AnyHashable: Any] = ["event_id": id, "event_kind": 1]
        let marker: [AnyHashable: Any] = ["notif_id": id.lowercased(), "notif_type": "mention"]
        XCTAssertEqual(NotificationPolicy.eventKey(of: push), NotificationPolicy.eventKey(of: marker))
        XCTAssertEqual(NotificationPolicy.eventKey(of: push), NotificationPolicy.dedupKey(eventId: id))
        XCTAssertNil(NotificationPolicy.eventKey(of: ["nv_deeplink": "nostrvault://shareinbox"]))
        XCTAssertNil(NotificationPolicy.eventKey(of: ["notif_id": ""]))
    }

    /// Read or tapped: nothing to file.
    func testPillShownOrTappedIsNotFiled() {
        XCTAssertFalse(NotificationPolicy.filesPill(end: .timedOut, drawnFor: NotificationPolicy.pillReadableAfter))
        XCTAssertFalse(NotificationPolicy.filesPill(end: .trimmed, drawnFor: 3))
        XCTAssertFalse(NotificationPolicy.filesPill(end: .tapped, drawnFor: 0))
    }

    /// A filed DM carries the generic line, never its decrypted text.
    func testFiledDMIsGeneric() {
        XCTAssertEqual(NotificationPolicy.filedPillTitle(type: "dm", title: "Message from Alice"), NotificationPolicy.dmFiledTitle)
        XCTAssertEqual(NotificationPolicy.filedPillTitle(type: "giftwrap", title: "Message from Alice"), NotificationPolicy.dmFiledTitle)
        XCTAssertEqual(NotificationPolicy.filedPillTitle(type: "mention", title: "Alice mentioned you"), "Alice mentioned you")
        XCTAssertEqual(NotificationPolicy.filedPillBody(type: "giftwrap", body: "meet at 6"), NotificationPolicy.dmFiledBody)
        XCTAssertEqual(NotificationPolicy.filedPillBody(type: "dm", body: "meet at 6"), NotificationPolicy.dmFiledBody)
        XCTAssertEqual(NotificationPolicy.filedPillBody(type: "mention", body: "gm"), "gm")
    }

    /// A DM's lock-screen alert says who it is from, never what it says.
    func testSystemAlertDMIsGeneric() {
        XCTAssertEqual(NotificationPolicy.systemAlertTitle(type: "giftwrap", name: "Alice", title: "Message from Alice"), "New message from Alice")
        XCTAssertEqual(NotificationPolicy.systemAlertTitle(type: "dm", name: nil, title: "New message"), "New message")
        XCTAssertEqual(NotificationPolicy.systemAlertTitle(type: "dm", name: "", title: "Message from Someone"), "New message")
        XCTAssertEqual(NotificationPolicy.systemAlertTitle(type: "mention", name: "Alice", title: "Alice mentioned you"), "Alice mentioned you")
        XCTAssertEqual(NotificationPolicy.systemAlertBody(type: "giftwrap", body: "meet at 6"), NotificationPolicy.dmFiledBody)
        XCTAssertEqual(NotificationPolicy.systemAlertBody(type: "dm", body: "meet at 6"), NotificationPolicy.dmFiledBody)
        XCTAssertEqual(NotificationPolicy.systemAlertBody(type: "reply", body: "gm"), "gm")
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
        // Graph not loaded: fails closed, a stranger's reply stays silent.
        XCTAssertFalse(NotificationPolicy.authorMayNotify("stranger", type: "reply", trusted: [], own: []))
        // Own events, gift wraps and the summary are not held back.
        XCTAssertTrue(NotificationPolicy.authorMayNotify("me", type: "zap", trusted: trusted, own: ["me"]))
        XCTAssertTrue(NotificationPolicy.authorMayNotify("throwaway", type: "giftwrap", trusted: trusted, own: []))
        // The receipt is signed by the lightning service, never in anyone's WoT.
        XCTAssertTrue(NotificationPolicy.authorMayNotify("lnurl-service", type: "zap", trusted: trusted, own: []))
        // A follow is judged like a post: only a follower in your web alerts,
        // and with no graph yet nobody but your own accounts does.
        XCTAssertTrue(NotificationPolicy.authorMayNotify("friend", type: "follow", trusted: ["friend"], own: []))
        XCTAssertFalse(NotificationPolicy.authorMayNotify("stranger", type: "follow", trusted: trusted, own: []))
        XCTAssertFalse(NotificationPolicy.authorMayNotify("stranger", type: "follow", trusted: [], own: []))
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

// MARK: - Account label

final class NotificationAccountLabelTests: XCTestCase {
    private let owner = "npub1ownerownerownerownerownerownerownerownerownerownerowner0"
    private let second = "npub1secondsecondsecondsecondsecondsecondsecondsecondsecond"

    func testNoLabelWithOneAccount() {
        XCTAssertNil(NotificationPolicy.accountLabel(npub: owner, accounts: [owner], name: "Logen"))
    }

    func testNamesTheAccountWithTwo() {
        XCTAssertEqual(NotificationPolicy.accountLabel(npub: second, accounts: [owner, second], name: "Shop"), "Shop")
    }

    func testShortNpubWithoutAName() {
        XCTAssertEqual(NotificationPolicy.accountLabel(npub: second, accounts: [owner, second], name: "  "),
                       "npub1sec…cond")
    }

    func testNoLabelForAnAccountNoLongerHeld() {
        XCTAssertNil(NotificationPolicy.accountLabel(npub: second, accounts: [owner, "npub1other"], name: "Shop"))
    }
}

/// Logen 2026-11-11: a stranger replied to his note while his saved web read
/// empty; it notified and sat in Vault > All. It is kept on purpose, but only
/// under Outside, and only follows notify until the web is built.
final class EmptyWebFailsClosedTests: XCTestCase {
    let owner = "owner", follow = "follow", stranger = "stranger"

    func testStrangerReplyWithNoSavedWebIsSilentAndOutside() {
        let trusted = TrustMap.web(saved: [], follows: [follow])
        XCTAssertFalse(NotificationPolicy.authorMayNotify(stranger, type: "reply", trusted: trusted, own: [owner]))
        XCTAssertFalse(NotificationPolicy.authorMayNotify(stranger, type: "mention", trusted: trusted, own: [owner]))
        XCTAssertTrue(ContentFilter.isOutside(author: stranger, owner: owner, whitelist: [owner], trusted: trusted))
    }

    func testFollowStillNotifiesAndStaysInAllWithNoSavedWeb() {
        let trusted = TrustMap.web(saved: [], follows: [follow])
        XCTAssertTrue(NotificationPolicy.authorMayNotify(follow, type: "reply", trusted: trusted, own: [owner]))
        XCTAssertFalse(ContentFilter.isOutside(author: follow, owner: owner, whitelist: [owner], trusted: trusted))
        XCTAssertTrue(NotificationPolicy.authorMayNotify(owner, type: "reply", trusted: [], own: [owner]))
    }
}
