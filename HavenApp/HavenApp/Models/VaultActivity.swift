import Foundation

/// One line on the Vault tab's "Vault" list: everything other people did that
/// reached you, newest first, the way a notifications page reads. Likes,
/// zaps and reposts of the same post fold into one line ("Ann and 3 others
/// liked your note"); replies, mentions and quotes each get their own.
struct VaultActivity: Identifiable, Equatable {
    enum Kind: Equatable {
        case reply, mention, quote, reaction, repost, zap, article, highlight, follow
    }

    /// The event fields the list needs. NostrEvent lives with the network
    /// code, so the view hands these over and this file stays testable.
    struct Event {
        let id: String
        let pubkey: String
        let kind: Int
        let createdAt: Int64
        let content: String
        let tags: [[String]]
    }

    let id: String
    let kind: Kind
    /// Who did it, newest first, each once.
    let actors: [String]
    /// The newest of them, unix seconds.
    let createdAt: Int64
    /// The note a tap opens: their reply or mention, or your post they liked.
    /// Nil for follows, which open the profile.
    let openId: String?
    /// Their words (reply, mention, quote, article title, zap comment), or
    /// your post's text when they only reacted to it.
    let preview: String
    /// Reactions only: the emoji, newest first, each once.
    var emojis: [String] = []
    /// Zaps only: the total.
    var sats: Int64 = 0

    static func == (a: VaultActivity, b: VaultActivity) -> Bool {
        a.id == b.id && a.actors == b.actors && a.createdAt == b.createdAt && a.sats == b.sats && a.emojis == b.emojis
    }

    static let reactionKind = 7
    static let zapKind = 9735
    static let repostKinds: Set<Int> = [6, 16]

    /// Builds the list. `noteKinds` are the kinds the Vault lists (the relay
    /// tab's); `isHidden` drops blocked authors and, for posts that tag you,
    /// replies from outside your network (the Notes list hides those too).
    /// `follows` are (pubkey, unix time) from the follower ledger.
    static func build(
        events: [Event],
        owner: String,
        noteKinds: Set<Int>,
        follows: [(pubkey: String, at: Int64)] = [],
        isBlocked: (String) -> Bool = { _ in false },
        isOutside: (String) -> Bool = { _ in false }
    ) -> [VaultActivity] {
        guard !owner.isEmpty else { return [] }

        let mine = events.filter { $0.pubkey == owner && noteKinds.contains($0.kind) && !repostKinds.contains($0.kind) }
        let myText = Dictionary(mine.map { ($0.id, preview(of: $0)) }, uniquingKeysWith: { a, _ in a })

        var singles: [VaultActivity] = []
        // Folded lines, by kind and target: actors newest first.
        var folds: [String: (kind: Kind, target: String, actors: [String], at: Int64, emojis: [String], sats: Int64)] = [:]
        var seen = Set<String>()

        func fold(_ kind: Kind, target: String, actor: String, at: Int64, emoji: String? = nil, sats: Int64 = 0) {
            let key = "\(kind)-\(target)"
            var f = folds[key] ?? (kind, target, [], 0, [], 0)
            f.actors.append(actor)
            f.at = max(f.at, at)
            if let emoji { f.emojis.append(emoji) }
            f.sats += sats
            folds[key] = f
        }

        // Newest first, so each fold's actor list comes out newest first.
        for event in events.sorted(by: { $0.createdAt > $1.createdAt }) {
            guard event.pubkey != owner, seen.insert(event.id).inserted else { continue }

            if event.kind == reactionKind {
                guard !isBlocked(event.pubkey),
                      let target = firstTag("e", in: event.tags), myText[target] != nil else { continue }
                fold(.reaction, target: target, actor: event.pubkey, at: event.createdAt,
                     emoji: event.content.isEmpty ? "+" : event.content)
                continue
            }

            if event.kind == zapKind {
                guard firstTag("p", in: event.tags) == owner else { continue }
                let request = LiveChat.zapRequest(from: event.tags)
                guard let sender = request?.pubkey, sender != owner, !isBlocked(sender) else { continue }
                let sats = Int64(LiveChat.zapAmountSats(receiptTags: event.tags, requestTags: request?.tags ?? []))
                // The note comes from the signed request, as the Zaps list reads it.
                let target = request.flatMap { firstTag("e", in: $0.tags) } ?? firstTag("e", in: event.tags)
                let comment = (request?.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if let target, myText[target] != nil, comment.isEmpty {
                    fold(.zap, target: target, actor: sender, at: event.createdAt, sats: sats)
                } else {
                    // A zap with words, or on your profile: its own line.
                    singles.append(VaultActivity(
                        id: event.id, kind: .zap, actors: [sender], createdAt: event.createdAt,
                        openId: target.flatMap { myText[$0] != nil ? $0 : nil },
                        preview: comment.isEmpty ? (target.flatMap { myText[$0] } ?? "") : comment,
                        sats: sats))
                }
                continue
            }

            guard noteKinds.contains(event.kind) || repostKinds.contains(event.kind),
                  !isBlocked(event.pubkey) else { continue }

            if repostKinds.contains(event.kind) {
                guard let target = firstTag("e", in: event.tags), myText[target] != nil else { continue }
                fold(.repost, target: target, actor: event.pubkey, at: event.createdAt)
                continue
            }

            guard event.tags.contains(where: { $0.count >= 2 && $0[0] == "p" && $0[1] == owner }),
                  !isOutside(event.pubkey) else { continue }

            let kind: Kind
            switch event.kind {
            case VaultNoteScope.articleKind: kind = .article
            case VaultNoteScope.highlightKind: kind = .highlight
            default:
                if let quoted = firstTag("q", in: event.tags), myText[quoted] != nil {
                    kind = .quote
                } else if event.tags.contains(where: { $0.count >= 2 && ($0[0] == "e" || $0[0] == "E") }) {
                    kind = .reply
                } else {
                    kind = .mention
                }
            }
            singles.append(VaultActivity(
                id: event.id, kind: kind, actors: [event.pubkey], createdAt: event.createdAt,
                openId: event.id, preview: preview(of: event)))
        }

        let folded = folds.map { key, f in
            VaultActivity(
                id: key, kind: f.kind, actors: unique(f.actors), createdAt: f.at,
                openId: f.target, preview: myText[f.target] ?? "",
                emojis: unique(f.emojis), sats: f.sats)
        }

        // Follows on one day fold into one line, like a notifications page.
        var followDays: [String: [(pubkey: String, at: Int64)]] = [:]
        for follow in follows where follow.pubkey != owner && !isBlocked(follow.pubkey) {
            followDays[dayKey(follow.at), default: []].append(follow)
        }
        let followLines = followDays.map { day, list in
            let sorted = list.sorted { $0.at > $1.at }
            return VaultActivity(
                id: "follow-\(day)", kind: .follow, actors: unique(sorted.map(\.pubkey)),
                createdAt: sorted.first?.at ?? 0, openId: nil, preview: "")
        }

        return (singles + folded + followLines).sorted {
            $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : $0.id < $1.id
        }
    }

    // MARK: - Helpers

    private static func firstTag(_ name: String, in tags: [[String]]) -> String? {
        tags.first { $0.count >= 2 && $0[0] == name && !$0[1].isEmpty }?[1]
    }

    private static func unique(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }

    private static func dayKey(_ at: Int64) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: TimeInterval(at)))
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    /// One line of text for an event: an article's title or summary, else its
    /// content with whitespace runs collapsed.
    static func preview(of event: Event) -> String {
        if event.kind == VaultNoteScope.articleKind {
            if let title = firstTag("title", in: event.tags) { return title }
            if let summary = firstTag("summary", in: event.tags) { return summary }
        }
        return event.content
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}
