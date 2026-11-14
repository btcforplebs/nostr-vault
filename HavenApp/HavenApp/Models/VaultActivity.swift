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
        /// The pictures in `content`, as the view already finds them for
        /// feed rows. They show as thumbnails and leave the preview text.
        var images: [URL] = []
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
    /// Reactions only: the NIP-30 images for `:shortcode:` emojis, by shortcode (first seen wins).
    var customEmojis: [String: CustomEmoji] = [:]
    /// Zaps only: the total.
    var sats: Int64 = 0
    /// The pictures in the previewed note, in content order: theirs for a
    /// reply, mention or quote; yours when they only reacted to your post.
    var images: [URL] = []
    /// The note `images` come from: its author and tags, so a photo whose
    /// URL fails can be read from that author's vault on the mesh.
    var imagesAuthor: String? = nil
    var imagesTags: [[String]] = []

    static func == (a: VaultActivity, b: VaultActivity) -> Bool {
        a.id == b.id && a.actors == b.actors && a.createdAt == b.createdAt && a.sats == b.sats && a.emojis == b.emojis
            && a.customEmojis == b.customEmojis
    }

    /// One zap from a receipt: who made it (the zap request's signer, never
    /// the receipt's wallet server), on which post, how much, and when.
    struct Zap {
        let sender: String
        let target: String?
        let sats: Int64
        let at: Int64
    }

    /// The Zaps list's "on my notes" view: who zapped each of `targets`, and
    /// when the newest zap on it came in. A blocked sender is left out, so a
    /// post only they zapped drops off the list; unblocking brings it back.
    static func zapsOnPosts(
        _ zaps: [Zap],
        targets: Set<String>,
        owner: String,
        excludeOwner: Bool,
        isBlocked: (String) -> Bool
    ) -> (zappers: [String: [(pubkey: String, amount: Int64)]], lastZapAt: [String: Int64]) {
        var zappers: [String: [(pubkey: String, amount: Int64)]] = [:]
        var lastZapAt: [String: Int64] = [:]
        for zap in zaps {
            guard let target = zap.target, targets.contains(target) else { continue }
            if excludeOwner && zap.sender == owner { continue }
            if isBlocked(zap.sender) { continue }
            zappers[target, default: []].append((pubkey: zap.sender, amount: zap.sats))
            lastZapAt[target] = max(lastZapAt[target] ?? 0, zap.at)
        }
        return (zappers, lastZapAt)
    }

    static let reactionKind = 7
    static let zapKind = 9735
    static let repostKinds: Set<Int> = [6, 16]

    /// Builds the list. `noteKinds` are the kinds the Vault lists (the relay
    /// tab's); `isHidden` drops blocked authors and, for posts that tag you,
    /// replies from outside your network (the Notes list hides those too).
    /// `follows` are (pubkey, unix time) from the follower ledger; only those
    /// `isOutside` lets in get a line (Logen 2026-11-14), and none under
    /// `outsideOnly`: outside followers are the Followers page's ··· list.
    /// `outsideOnly` turns it round for the "Outside your web" filter: only
    /// the posts tagging you whose authors `isOutside` says are outside, and
    /// no likes, zaps, reposts or follows.
    /// `foldsOutsideLikes` (Logen 2026-11-13 "go all", option A): likes and
    /// reposts whose author `isOutside` leave All for the list's one
    /// "N from outside your web" line, and `outsideOnly` lists them with the
    /// outside posts. Zaps and follows are never folded.
    static func build(
        events: [Event],
        owner: String,
        noteKinds: Set<Int>,
        follows: [(pubkey: String, at: Int64)] = [],
        isBlocked: (String) -> Bool = { _ in false },
        isOutside: (String) -> Bool = { _ in false },
        outsideOnly: Bool = false,
        foldsOutsideLikes: Bool = false,
        now: Int64 = Int64(Date().timeIntervalSince1970)
    ) -> [VaultActivity] {
        guard !owner.isEmpty else { return [] }

        let mine = events.filter { $0.pubkey == owner && noteKinds.contains($0.kind) && !repostKinds.contains($0.kind) }
        let myText = Dictionary(mine.map { ($0.id, preview(of: $0)) }, uniquingKeysWith: { a, _ in a })
        let myImages = Dictionary(mine.map { ($0.id, $0.images) }, uniquingKeysWith: { a, _ in a })
        let myTags = Dictionary(mine.map { ($0.id, $0.tags) }, uniquingKeysWith: { a, _ in a })
        // Who wrote each event in memory, to tell a note of someone else's
        // from one of yours that simply hasn't arrived yet.
        let authorOf = Dictionary(events.map { ($0.id, $0.pubkey) }, uniquingKeysWith: { a, _ in a })
        // A like or repost on a note that isn't in memory yet still gets its
        // line when it names you as the note's author (its last `p`, as
        // NIP-18/25 put the author there), so it doesn't wait on your own
        // notes, or vanish when the note is older than the ones loaded
        // (Logen 2026-11-04: Live Vault showed only zaps at first). The line
        // has the same id it will keep once the note lands, so nothing jumps;
        // `missingTargets` names the notes to fetch for the preview.
        func onMyNote(_ target: String, _ tags: [[String]]) -> Bool {
            if myText[target] != nil { return true }
            guard authorOf[target] == nil else { return false }
            return tags.last { $0.count >= 2 && $0[0] == "p" }?[1] == owner
        }

        var singles: [VaultActivity] = []
        // Folded lines, by kind and target: actors newest first.
        var folds: [String: (kind: Kind, target: String, actors: [String], at: Int64, emojis: [String], sats: Int64,
                             custom: [String: CustomEmoji])] = [:]
        var seen = Set<String>()

        func fold(_ kind: Kind, target: String, actor: String, at: Int64, emoji: String? = nil, sats: Int64 = 0,
                  custom: CustomEmoji? = nil) {
            let key = "\(kind)-\(target)"
            var f = folds[key] ?? (kind, target, [], 0, [], 0, [:])
            f.actors.append(actor)
            f.at = max(f.at, at)
            if let emoji { f.emojis.append(emoji) }
            if let custom, f.custom[custom.shortcode] == nil { f.custom[custom.shortcode] = custom }
            f.sats += sats
            folds[key] = f
        }

        // Newest first, so each fold's actor list comes out newest first.
        for event in events.sorted(by: { $0.createdAt > $1.createdAt }) {
            guard event.pubkey != owner, !isFuture(event.createdAt, now: now),
                  seen.insert(event.id).inserted else { continue }
            let isLike = event.kind == reactionKind || repostKinds.contains(event.kind)
            if isLike && foldsOutsideLikes {
                // Folded likes and reposts: only in the outside list.
                if isOutside(event.pubkey) != outsideOnly { continue }
            } else if outsideOnly && (isLike || event.kind == zapKind) {
                continue
            }

            if event.kind == reactionKind {
                guard !isBlocked(event.pubkey),
                      let target = firstTag("e", in: event.tags), onMyNote(target, event.tags) else { continue }
                fold(.reaction, target: target, actor: event.pubkey, at: event.createdAt,
                     emoji: event.content.isEmpty ? "+" : event.content,
                     custom: CustomEmoji.forReaction(content: event.content, tags: event.tags))
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
                // A receipt is always to you: a note not in memory yet is
                // yours unless it is known to be someone else's.
                if let target, comment.isEmpty, myText[target] != nil || authorOf[target] == nil {
                    fold(.zap, target: target, actor: sender, at: event.createdAt, sats: sats)
                } else {
                    // A zap with words, or on your profile: its own line.
                    singles.append(VaultActivity(
                        id: event.id, kind: .zap, actors: [sender], createdAt: event.createdAt,
                        openId: target.flatMap { myText[$0] != nil ? $0 : nil },
                        preview: comment.isEmpty ? (target.flatMap { myText[$0] } ?? "") : comment,
                        sats: sats,
                        images: comment.isEmpty ? (target.flatMap { myImages[$0] } ?? []) : [],
                        imagesAuthor: owner, imagesTags: target.flatMap { myTags[$0] } ?? []))
                }
                continue
            }

            guard noteKinds.contains(event.kind) || repostKinds.contains(event.kind),
                  !isBlocked(event.pubkey) else { continue }

            if repostKinds.contains(event.kind) {
                guard let target = firstTag("e", in: event.tags), onMyNote(target, event.tags) else { continue }
                fold(.repost, target: target, actor: event.pubkey, at: event.createdAt)
                continue
            }

            guard event.tags.contains(where: { $0.count >= 2 && $0[0] == "p" && $0[1] == owner }),
                  isOutside(event.pubkey) == outsideOnly else { continue }

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
                openId: event.id, preview: preview(of: event), images: event.images,
                imagesAuthor: event.pubkey, imagesTags: event.tags))
        }

        let folded = folds.map { key, f in
            VaultActivity(
                id: key, kind: f.kind, actors: unique(f.actors), createdAt: f.at,
                openId: f.target, preview: myText[f.target] ?? "",
                emojis: unique(f.emojis), customEmojis: f.custom, sats: f.sats, images: myImages[f.target] ?? [],
                imagesAuthor: owner, imagesTags: myTags[f.target] ?? [])
        }

        // Follows on one day fold into one line, like a notifications page.
        var followDays: [String: [(pubkey: String, at: Int64)]] = [:]
        for follow in follows where !outsideOnly && follow.pubkey != owner && !isBlocked(follow.pubkey) && !isOutside(follow.pubkey) {
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

    /// The notes the lines point at that aren't in memory (`have`): likes,
    /// reposts and zaps on your notes older than the ones loaded, or not
    /// loaded yet. Fetched by id, they fill in the lines' previews.
    static func missingTargets(in lines: [VaultActivity], have: Set<String>) -> [String] {
        var out: [String] = []
        for line in lines where line.kind == .reaction || line.kind == .repost || line.kind == .zap {
            guard let id = line.openId, line.id == "\(line.kind)-\(id)", !have.contains(id), !out.contains(id) else { continue }
            out.append(id)
        }
        return out
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
    /// content with whitespace runs collapsed and its pictures' links left
    /// out, since those show as thumbnails.
    static func preview(of event: Event) -> String {
        if event.kind == VaultNoteScope.articleKind {
            if let title = firstTag("title", in: event.tags) { return title }
            if let summary = firstTag("summary", in: event.tags) { return summary }
        }
        let pictures = Set(event.images.map(\.absoluteString))
        return event.content
            .split(whereSeparator: { $0.isWhitespace })
            .filter { !pictures.contains(String($0)) }
            .joined(separator: " ")
    }
}

// MARK: - Clock guard

extension VaultActivity {
    /// How far ahead of this device's clock an event may be dated (the relay
    /// refuses the same, haven-go future_events.go). Later than that is a
    /// sender with a wrong clock: its line would sit on top of the list, and
    /// a refresh asking for "newer than the newest held" would ask for the
    /// future and get nothing more, so the Vault froze (Logen 11-02).
    static let maxFutureSkew: Int64 = 600

    /// Whether an event dated `createdAt` is too far ahead of `now` to keep.
    static func isFuture(_ createdAt: Int64, now: Int64) -> Bool {
        createdAt > now + maxFutureSkew
    }

    /// The `since` of a top-up: a minute before the newest event held, and
    /// never later than the clock allows, so a stray future date can't stop
    /// new events from arriving. Nil when nothing is held.
    static func refreshSince(newest: Int64?, now: Int64) -> Int64? {
        newest.map { min($0, now + maxFutureSkew) - 60 }
    }
}
