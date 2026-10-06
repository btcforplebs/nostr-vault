import Foundation

/// How much attention a post got: shown on profile rows so a person can see
/// at a glance which of their posts landed.
///
/// Kept apart from `NoteStats` on purpose. That struct is persisted in the
/// feed cache with synthesized Codable, so adding a field to it would make
/// every existing cache fail to decode.
struct PostEngagement: Equatable {
    /// People who reacted. One person reacting twice counts once.
    var likes = 0
    /// People who reposted (kind 6, or kind 16 for non-note kinds).
    var reposts = 0
    /// Direct replies: kind 1 notes and NIP-22 comments whose parent is this post.
    var replies = 0
    /// Total sats across zap receipts.
    var zapSats = 0
    /// The counts came from a handful of relays and may be missing what sits
    /// on others: true for anyone else's posts. Large numbers then show as
    /// "64+" so nobody reads them as exact. Your own posts are counted from
    /// your relay's inbox, which receives what's sent to you.
    var isLowerBound = false

    /// From this many up, a lower-bound count gets its "+". Small accounts
    /// measured within about one of Primal's numbers; the gap opens on popular posts.
    static let lowerBoundFrom = 10

    /// `value` as shown: compact, with "+" when it is a lower bound and large.
    func display(_ value: Int) -> String {
        Self.compact(value) + (isLowerBound && value >= Self.lowerBoundFrom ? "+" : "")
    }

    var isEmpty: Bool { likes == 0 && reposts == 0 && replies == 0 && zapSats == 0 }

    /// Field by field, the larger of two counts. A relay that came back short
    /// this time must not shrink a number already on screen.
    func merged(with other: PostEngagement) -> PostEngagement {
        PostEngagement(likes: max(likes, other.likes), reposts: max(reposts, other.reposts),
                       replies: max(replies, other.replies), zapSats: max(zapSats, other.zapSats),
                       isLowerBound: isLowerBound && other.isLowerBound)
    }

    /// `2100` → "2.1k", `1_250_000` → "1.3M". Below 1,000 the number itself.
    static func compact(_ value: Int) -> String {
        switch value {
        case ..<1_000: return "\(value)"
        case ..<1_000_000: return trimmed(Double(value) / 1_000) + "k"
        default: return trimmed(Double(value) / 1_000_000) + "M"
        }
    }

    private static func trimmed(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
    }
}

enum PostEngagementQuery {
    static let reactionKind = 7
    static let repostKinds = [6, 16]
    static let zapReceiptKind = 9735
    static let replyKinds = [1, NIP10Thread.commentKind]

    /// Relay filters for the engagement on `ids`. The ids are split into small
    /// groups because a relay applies `limit` per filter: one filter for fifty
    /// posts would stop at the limit and undercount the popular ones.
    /// - Parameter since: only engagement newer than this (unix seconds), for
    ///   posts already counted once; nil asks for everything.
    static func filters(for ids: [String], since: Int? = nil, groupSize: Int = 10, limit: Int = 500) -> [[String: Any]] {
        let kinds = [reactionKind] + repostKinds + [zapReceiptKind] + replyKinds
        return stride(from: 0, to: ids.count, by: max(groupSize, 1)).map { start in
            let group = Array(ids[start..<min(start + groupSize, ids.count)])
            var filter: [String: Any] = ["kinds": kinds, "#e": group, "limit": limit]
            if let since { filter["since"] = since }
            return filter
        }
    }

    /// What points at each of `targets`, as the people and events behind the
    /// numbers, so a saved ledger can add a later fetch without counting
    /// anything twice. Relays answer tag filters loosely and the same event
    /// comes from several of them, so each event is checked against its own
    /// tags.
    static func contributions(_ events: [[String: Any]], targets: Set<String>) -> [String: EngagementLedger] {
        var out: [String: EngagementLedger] = [:]
        for event in events {
            guard let id = event["id"] as? String,
                  let kind = event["kind"] as? Int,
                  let pubkey = event["pubkey"] as? String,
                  let tags = event["tags"] as? [[String]] else { continue }

            switch kind {
            case reactionKind:
                // NIP-25: the reacted-to event is the last `e` tag.
                guard let target = tags.last(where: { $0.count >= 2 && $0[0] == "e" })?[1],
                      targets.contains(target) else { continue }
                // A "-" is a dislike, not attention worth counting as a like.
                if (event["content"] as? String) == "-" { continue }
                out[target, default: EngagementLedger()].likers.insert(EngagementLedger.key(pubkey))

            case _ where repostKinds.contains(kind):
                guard let target = tags.first(where: { $0.count >= 2 && $0[0] == "e" && targets.contains($0[1]) })?[1]
                else { continue }
                out[target, default: EngagementLedger()].reposters.insert(EngagementLedger.key(pubkey))

            case zapReceiptKind:
                guard let target = tags.first(where: { $0.count >= 2 && $0[0] == "e" && targets.contains($0[1]) })?[1],
                      let bolt11 = tags.first(where: { $0.count >= 2 && $0[0] == "bolt11" })?[1],
                      let sats = Bolt11.sats(bolt11), sats > 0 else { continue }
                out[target, default: EngagementLedger()].zaps[EngagementLedger.key(id)] = sats

            case _ where replyKinds.contains(kind):
                // Only a reply to the post itself; a quote or a reply further
                // down the thread also carries the id in an `e` tag.
                guard let parent = NIP10Thread.parentEventId(kind: kind, tags: tags),
                      targets.contains(parent) else { continue }
                out[parent, default: EngagementLedger()].replies.insert(EngagementLedger.key(id))

            default:
                continue
            }
        }
        return out
    }

    /// Counts for each target, ready to show. Zero-engagement targets are left out.
    static func tally(_ events: [[String: Any]], targets: Set<String>) -> [String: PostEngagement] {
        contributions(events, targets: targets).compactMapValues { ledger in
            // Whether these are a lower bound depends on where they came
            // from, which only the caller knows.
            var e = ledger.engagement
            e.isLowerBound = false
            return e.isEmpty ? nil : e
        }
    }
}

/// Everything counted so far for one post: who liked and reposted it, which
/// replies and zap receipts were seen. Saved between launches so the next
/// visit asks relays only for what's new and adds it, never counting the
/// same like or zap twice.
///
/// Keys are the first 16 hex characters of a pubkey or event id: 64 bits is
/// plenty to tell a few thousand apart, at a quarter of the storage.
struct EngagementLedger: Codable, Equatable {
    var likers: Set<String> = []
    var reposters: Set<String> = []
    var replies: Set<String> = []
    /// Zap receipt key → sats.
    var zaps: [String: Int] = [:]
    /// When relays were last asked about this post. nil until then.
    var checkedAt: Date?
    /// Counted from relays only (anyone else's post): a lower bound.
    var isLowerBound = true

    static func key(_ hex: String) -> String { String(hex.prefix(16)) }

    var engagement: PostEngagement {
        PostEngagement(likes: likers.count, reposts: reposters.count, replies: replies.count,
                       zapSats: zaps.values.reduce(0, +), isLowerBound: isLowerBound)
    }

    /// Adds what `other` saw. Sets union, so an event seen before adds nothing.
    mutating func absorb(_ other: EngagementLedger) {
        likers.formUnion(other.likers)
        reposters.formUnion(other.reposters)
        replies.formUnion(other.replies)
        zaps.merge(other.zaps) { old, _ in old }
    }
}
