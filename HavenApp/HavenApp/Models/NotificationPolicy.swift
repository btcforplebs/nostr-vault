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
    /// Mentions and replies are kind 1, and replies may also be NIP-22 comments
    /// (kind 1111), so either one enables both. The set is
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
        if mentionsOrReplies { kinds.append(contentsOf: [1, 1111]) }
        if dms { kinds.append(contentsOf: [4, 1059]) }
        // Kind 16 is the generic repost: an article, picture or anything but a text note.
        if reposts { kinds.append(contentsOf: [6, 16]) }
        if reactions { kinds.append(7) }
        if zaps { kinds.append(9735) }
        return kinds.isEmpty ? [silentKind] : kinds.sorted()
    }

    /// Whether a notification marker may be shown while phone notifications are
    /// switched off. Only a DM, and only as the in-app banner while the app is
    /// open: that banner is part of the app, not a phone notification, so the
    /// switch shouldn't hide it. Everything else stays silent.
    /// Only people in your Web of Trust (or follows) notify. `trusted` empty
    /// means the graph has not loaded, and then nobody is held back. Gift
    /// wraps (`giftwrap`) carry a throwaway author and the catch-up summary
    /// carries none, so they are not judged here. Zaps pass too: the relay
    /// already admitted the receipt on the zapper's standing (haven-go
    /// inboxTrustKey), and a relay from before that marker change names the
    /// lightning service, which is never in anyone's Web of Trust.
    /// Follows pass as well: they are never dropped for trust, only told
    /// differently (followIsNamed).
    static func authorMayNotify(_ author: String, type: String, trusted: Set<String>, own: Set<String>) -> Bool {
        if author.isEmpty || type == "giftwrap" || type == "summary" || type == "zap" || type == "follow" { return true }
        if trusted.isEmpty || own.contains(author) { return true }
        return trusted.contains(author)
    }

    /// Whether a new follower is announced by name ("Alice followed you").
    /// Only someone in your Web of Trust is. Anyone else, and everyone while
    /// the graph is empty (a brand-new account), is folded into one nameless
    /// "N new followers" alert: a stranger's follow is the cheapest event to
    /// forge, so it must not put a chosen name or picture on the lock screen,
    /// but you still hear that you gained followers.
    static func followIsNamed(_ follower: String, trusted: Set<String>) -> Bool {
        trusted.contains(follower)
    }

    /// The folded alert once `follower` joins it. `showing` is the alert still
    /// on screen (empty once it was tapped or cleared, so the count starts
    /// over). Only the latest `cap` strangers ride along, so the alert stays
    /// small however many follow; they exist to count a repeat once, and the
    /// count itself is stored apart from them.
    static func foldedFollowers(showing: FoldedFollowers, adding follower: String, cap: Int = 32) -> FoldedFollowers {
        let count = max(showing.count, showing.members.count)
        let repeat_ = showing.members.contains(follower)
        let members = Array((showing.members.filter { $0 != follower } + [follower]).suffix(cap))
        return FoldedFollowers(members: members, count: repeat_ ? count : count + 1)
    }

    /// Who the folded strangers' alert counts, and how many.
    struct FoldedFollowers: Equatable {
        var members: [String] = []
        var count: Int = 0
        /// Already on screen: an update to it changes the number, silently.
        var isShowing: Bool { count > 0 }
    }

    /// A follower key as the relay marker should carry it: 64 hex characters.
    static func isPubkeyHex(_ s: String) -> Bool {
        s.count == 64 && s.allSatisfy(\.isHexDigit)
    }

    /// Title and body of the folded strangers' alert.
    static func foldedFollowersText(count: Int) -> (String, String) {
        count <= 1
            ? ("New follower", "Someone new followed you. Tap to see your followers.")
            : ("\(count) new followers", "Tap to see your followers")
    }

    static func allowsWithPushOff(type: String, appInForeground: Bool) -> Bool {
        appInForeground && (type == "dm" || type == "giftwrap")
    }

    /// A decrypted DM as notification text: one line, cut to fit a banner.
    /// Nil when there is nothing to read (an empty message), so the caller
    /// keeps the generic line.
    static func dmPreview(_ content: String, limit: Int = 160) -> String? {
        let oneLine = content
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !oneLine.isEmpty else { return nil }
        guard oneLine.count > limit else { return oneLine }
        return String(oneLine.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
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

/// One account's notification switches. Lives beside NotificationPolicy so
/// the pure-Foundation test package can compile HavenConfig.
struct NotificationPreferences: Codable, Equatable {
    var mentions: Bool = true
    var replies: Bool = true
    var dms: Bool = true
    var zaps: Bool = true
    var reactions: Bool = false
    var reposts: Bool = false
    /// Someone new follows this account (or comes back after a week away).
    var follows: Bool = true

    /// Whether any notification at all is wanted. The relay's catch-up summary
    /// ("N more new items while you were away") counts events of every type at
    /// once, so no single preference governs it — but turning everything off
    /// has to silence it too, which it previously did not.
    var wantsAnything: Bool {
        mentions || replies || dms || zaps || reactions || reposts
    }
}

/// The post a relay notification opens, carried inside the notification.
///
/// The relay raises its notification marker only after it has stored the
/// event, so the app can read that event — and, for a like, zap or repost,
/// your post it is about — from this device and put both in the notification.
/// A tap then opens the post from that copy: no relay round trip and no hunt
/// through a list, even on a cold start.
///
/// Pure Foundation so MediaLogicTests can compile and test it directly.
enum NotificationNote {
    /// userInfo key for the notifying event, as NIP-01 JSON.
    static let eventKey = "notif_event"
    /// userInfo key for the post a like, zap or repost is about.
    static let targetKey = "notif_target"

    /// Past this size an event is left out and the tap loads it by id instead.
    /// iOS keeps delivered notifications in its own store; a long-form post
    /// has no business there.
    static let maxEncodedBytes = 32 * 1024

    /// Whether a tap opens the post the event is about rather than the event.
    /// A like or zap on its own is not something to read.
    static func opensTarget(type: String) -> Bool {
        type == "reaction" || type == "zap" || type == "repost"
    }

    /// The id of the post a like, zap or repost is about: its last `e` tag
    /// (NIP-25, NIP-57, NIP-18). Nil for a zap on a profile.
    static func targetId(type: String, tags: [[String]]) -> String? {
        guard opensTarget(type: type) else { return nil }
        return tags.last { $0.count >= 2 && $0[0] == "e" && isEventId($0[1]) }?[1]
    }

    /// Compact JSON for userInfo, or nil when the event is malformed or too big.
    static func encode(_ event: [String: Any]) -> String? {
        guard parse(event) != nil,
              JSONSerialization.isValidJSONObject(event),
              let data = try? JSONSerialization.data(withJSONObject: event),
              data.count <= maxEncodedBytes else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The fields a note needs, from userInfo's JSON. Nil for anything that
    /// is not a whole event.
    static func decode(_ json: String) -> Event? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parse(object)
    }

    struct Event: Equatable {
        let id: String
        let pubkey: String
        let createdAt: Int64
        let kind: Int
        let tags: [[String]]
        let content: String
    }

    private static func parse(_ object: [String: Any]) -> Event? {
        guard let id = object["id"] as? String, isEventId(id),
              let pubkey = object["pubkey"] as? String, isEventId(pubkey),
              let createdAt = (object["created_at"] as? NSNumber)?.int64Value,
              let kind = (object["kind"] as? NSNumber)?.intValue,
              let tags = object["tags"] as? [[String]],
              let content = object["content"] as? String else { return nil }
        return Event(id: id, pubkey: pubkey, createdAt: createdAt, kind: kind, tags: tags, content: content)
    }

    private static func isEventId(_ s: String) -> Bool {
        s.count == 64 && s.allSatisfy(\.isHexDigit)
    }
}

extension NotificationPreferences {
    /// Every key is optional: preferences saved before a switch existed must
    /// decode to that switch's default, not fail and reset every account.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = NotificationPreferences()
        mentions = try c.decodeIfPresent(Bool.self, forKey: .mentions) ?? d.mentions
        replies = try c.decodeIfPresent(Bool.self, forKey: .replies) ?? d.replies
        dms = try c.decodeIfPresent(Bool.self, forKey: .dms) ?? d.dms
        zaps = try c.decodeIfPresent(Bool.self, forKey: .zaps) ?? d.zaps
        reactions = try c.decodeIfPresent(Bool.self, forKey: .reactions) ?? d.reactions
        reposts = try c.decodeIfPresent(Bool.self, forKey: .reposts) ?? d.reposts
        follows = try c.decodeIfPresent(Bool.self, forKey: .follows) ?? d.follows
    }
}
