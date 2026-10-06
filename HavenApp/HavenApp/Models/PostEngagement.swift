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
    static func filters(for ids: [String], groupSize: Int = 10, limit: Int = 500) -> [[String: Any]] {
        let kinds = [reactionKind] + repostKinds + [zapReceiptKind] + replyKinds
        return stride(from: 0, to: ids.count, by: max(groupSize, 1)).map { start in
            let group = Array(ids[start..<min(start + groupSize, ids.count)])
            return ["kinds": kinds, "#e": group, "limit": limit]
        }
    }

    /// Counts what points at each of `targets`. Relays answer tag filters
    /// loosely and the same event comes from several of them, so each event
    /// is checked against its own tags and counted once.
    static func tally(_ events: [[String: Any]], targets: Set<String>) -> [String: PostEngagement] {
        var likers: [String: Set<String>] = [:]
        var reposters: [String: Set<String>] = [:]
        var replies: [String: Set<String>] = [:]
        var zapSats: [String: Int] = [:]
        var seen = Set<String>()

        for event in events {
            guard let id = event["id"] as? String, seen.insert(id).inserted,
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
                likers[target, default: []].insert(pubkey)

            case _ where repostKinds.contains(kind):
                guard let target = tags.first(where: { $0.count >= 2 && $0[0] == "e" && targets.contains($0[1]) })?[1]
                else { continue }
                reposters[target, default: []].insert(pubkey)

            case zapReceiptKind:
                guard let target = tags.first(where: { $0.count >= 2 && $0[0] == "e" && targets.contains($0[1]) })?[1],
                      let bolt11 = tags.first(where: { $0.count >= 2 && $0[0] == "bolt11" })?[1],
                      let sats = Bolt11.sats(bolt11), sats > 0 else { continue }
                zapSats[target, default: 0] += sats

            case _ where replyKinds.contains(kind):
                // Only a reply to the post itself; a quote or a reply further
                // down the thread also carries the id in an `e` tag.
                guard let parent = NIP10Thread.parentEventId(kind: kind, tags: tags),
                      targets.contains(parent) else { continue }
                replies[parent, default: []].insert(id)

            default:
                continue
            }
        }

        var out: [String: PostEngagement] = [:]
        for target in targets {
            let e = PostEngagement(likes: likers[target]?.count ?? 0, reposts: reposters[target]?.count ?? 0,
                                   replies: replies[target]?.count ?? 0, zapSats: zapSats[target] ?? 0)
            if !e.isEmpty { out[target] = e }
        }
        return out
    }
}
