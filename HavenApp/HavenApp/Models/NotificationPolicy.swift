import Foundation

/// Decides whether the two *unattended* notifications may fire: the relay's
/// catch-up summary ("N more new items while you were away") and the background
/// feed check ("N new notes in your feed").
///
/// Both used to fire on whatever background wake happened to be running. iOS
/// grants those several times an hour — each one starts the relay, which runs a
/// catch-up round 20 seconds later and ends it with the same "while you were
/// away" line — so a fifteen-minute pocket produced the same notification as an
/// overnight absence, over and over. These rules make "away" mean away, and let
/// one absence produce at most one summary of each kind.
///
/// Pure Foundation so MediaLogicTests can compile and test it directly; the
/// persisted timestamps it reads live in `NotificationActivityLog`.
enum NotificationPolicy {
    /// How long the app must have been out of the foreground before "while you
    /// were away" is a true statement. Shorter than this and the user was
    /// holding the phone; the events are already on screen in the app.
    static let minimumAbsence: TimeInterval = 2 * 60 * 60

    /// True when `now` falls in an absence long enough to summarise, and that
    /// absence has not already been summarised.
    ///
    /// - Parameters:
    ///   - lastForegroundAt: when the app was last in front of the user. `nil`
    ///     means it has never been foregrounded on this install, in which case
    ///     there is no absence to describe and nothing fires.
    ///   - lastAnnouncedAt: when a summary of this kind last fired. A summary
    ///     that fired *after* the absence began already covered this absence.
    static func shouldAnnounceAbsenceSummary(
        now: Date,
        lastForegroundAt: Date?,
        lastAnnouncedAt: Date?
    ) -> Bool {
        guard let lastForegroundAt else { return false }
        guard now.timeIntervalSince(lastForegroundAt) >= minimumAbsence else { return false }
        guard let lastAnnouncedAt else { return true }
        return lastAnnouncedAt < lastForegroundAt
    }

    /// Event kinds the relay should raise notifications for, given what the
    /// user has switched on. Passed to the embedded relay as NOTIFY_KINDS so its
    /// catch-up summary counts only kinds the user wants — the client can drop
    /// an individual marker for a kind, but "N more new items" is one number and
    /// nothing can filter it after the fact.
    ///
    /// Mentions and replies are both kind 1, so either one enables it. The set is
    /// the union across accounts; the client still applies each account's own
    /// preferences to the individual markers.
    ///
    /// Nothing enabled returns `[silentKind]` rather than an empty list: the relay
    /// reads an empty NOTIFY_KINDS as "no preference, notify for everything".
    static func notifyKinds(
        mentionsOrReplies: Bool,
        dms: Bool,
        zaps: Bool,
        reactions: Bool,
        reposts: Bool
    ) -> [Int] {
        var kinds: [Int] = []
        if mentionsOrReplies { kinds.append(1) }
        if dms { kinds.append(contentsOf: [4, 1059]) }
        if reposts { kinds.append(6) }
        if reactions { kinds.append(7) }
        if zaps { kinds.append(9735) }
        return kinds.isEmpty ? [silentKind] : kinds.sorted()
    }

    /// Kind 0 (profile metadata) never produces a notification, so listing it
    /// alone is how "notify for nothing" is expressed to the relay.
    static let silentKind = 0

    /// How many feed notes arrived since the last one the user was told about
    /// (or last saw, since foregrounding the app sets the same watermark).
    ///
    /// The old count was the growth of `FeedService.notes` across a 25-second
    /// window, which counts an older note being backfilled into the list as
    /// news. Counting by `createdAt` against a watermark cannot do that.
    ///
    /// With no watermark yet there is no baseline to count from, so nothing is
    /// announced — the caller stores one and starts counting from the next check.
    static func unannouncedFeedNoteCount(createdAt: [Date], lastAnnouncedNoteAt: Date?) -> Int {
        guard let cutoff = lastAnnouncedNoteAt else { return 0 }
        return createdAt.reduce(0) { $0 + ($1 > cutoff ? 1 : 0) }
    }
}

/// The persisted timestamps `NotificationPolicy` reads. Small enough to live in
/// UserDefaults, and it must survive process death: the whole point is that a
/// background wake (a fresh process, every time) can tell how long the user has
/// actually been away.
enum NotificationActivityLog {
    private static let foregroundKey = "com.haven.notify.lastForegroundAt"
    private static let catchUpKey = "com.haven.notify.lastCatchUpSummaryAt"
    private static let feedKey = "com.haven.notify.lastFeedSummaryAt"
    private static let feedNoteKey = "com.haven.notify.lastAnnouncedFeedNoteAt"

    private static func date(_ key: String) -> Date? {
        let raw = UserDefaults.standard.double(forKey: key)
        return raw > 0 ? Date(timeIntervalSince1970: raw) : nil
    }

    private static func store(_ date: Date, _ key: String) {
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: key)
    }

    static var lastForegroundAt: Date? { date(foregroundKey) }
    static var lastCatchUpSummaryAt: Date? { date(catchUpKey) }
    static var lastFeedSummaryAt: Date? { date(feedKey) }
    static var lastAnnouncedFeedNoteAt: Date? { date(feedNoteKey) }

    /// Called whenever the app is in front of the user (becoming active, and
    /// again on the way out) so "time since last foreground" stays truthful
    /// across a long session.
    static func recordForeground(now: Date = Date()) {
        store(now, foregroundKey)
    }

    static func recordCatchUpSummary(now: Date = Date()) {
        store(now, catchUpKey)
    }

    static func recordFeedSummary(now: Date = Date()) {
        store(now, feedKey)
    }

    /// The newest feed note the user has been told about — or, when set from
    /// the foreground, has had on screen. Monotonic: a late-arriving older note
    /// must not drag the watermark back and re-announce everything after it.
    static func recordAnnouncedFeedNote(_ createdAt: Date) {
        guard let current = lastAnnouncedFeedNoteAt else {
            store(createdAt, feedNoteKey)
            return
        }
        if createdAt > current { store(createdAt, feedNoteKey) }
    }
}
