import Foundation

/// What the "why?" sheet says about one person (discovery phase 4): their
/// score from your Haven, their ring, and the people you follow who follow
/// them, highest score first. No mute rows and no mute weighting: whether
/// trusted people's mutes count is still Logen's open question 3.
///
/// Only offered when your Haven's copy has a score for them (`of` is nil
/// otherwise): a phone with no Haven has no scores (Logen 2026-11-22).
/// The score is from `people`; someone only on the globe list (under the
/// floor, far out) gets the globe row's score. Hop 3 and out also get the
/// chain back to you (`TrustChain`) when the globe list has one.
/// Android twin: `data/model/TrustWhy.kt`.
struct TrustWhy: Equatable {
    /// One of your follows who follows them; `score` nil when your Haven's copy doesn't have them.
    struct Follower: Equatable {
        let pubkey: String
        let score: Int?
    }

    /// 0-100, shown scale, whole points.
    let score: Int
    let hop: Int
    /// Where the slider starts.
    let bar: Int
    /// Unix seconds: when your Haven ranked.
    let rankedAt: Int64
    let followers: [Follower]
    /// `followers` is everyone you follow who follows them (the links file).
    let exact: Bool
    /// What the live path found; nil while it is still tracing.
    let reach: TrustPath.Reach?
    /// Your follow first, out to them (`TrustChain.links`); nil under hop 3
    /// or when the globe list has no chain for them.
    var chain: [String]? = nil

    var overBar: Bool { score >= bar }

    /// Rows the sheet lists; the rest are counted.
    static let shown = 12

    /// `follows` and `blocked` only check the chain (`TrustChain.links`).
    static func of(pubkey: String, me: String, copy: TrustRankCopy?, path: TrustPath?,
                   follows: Set<String>, blocked: Set<String>) -> TrustWhy? {
        guard let copy, pubkey.caseInsensitiveCompare(me) != .orderedSame,
              let person = copy[pubkey] ?? copy.globePerson(pubkey).map({ TrustRankCopy.Person(score: $0.score, hop: $0.hop) })
        else { return nil }
        // The web outranks the copy for the near rings (ProfileHopText).
        guard let hop = ProfileHopText.hop(pubkey: pubkey, me: me, path: path, rank: person) else { return nil }
        let bridges: [String]
        if let path, path.reach == .follow || path.reach == .bridged {
            bridges = path.all.isEmpty ? path.bridges : path.all
        } else {
            bridges = []
        }
        let followers = bridges
            .map { Follower(pubkey: $0, score: copy[$0].map { whole($0.score) }) }
            .sorted { a, b in
                let sa = a.score ?? -1, sb = b.score ?? -1
                return sa != sb ? sa > sb : a.pubkey < b.pubkey
            }
        let chain = hop >= 3 ? TrustChain.links(to: pubkey, copy: copy, follows: follows, blocked: blocked) : nil
        return TrustWhy(score: whole(person.score), hop: hop, bar: whole(copy.viewBar), rankedAt: copy.builtAt,
                        followers: followers, exact: path?.complete == true, reach: path?.reach, chain: chain)
    }

    /// Kotlin's `roundToInt`: halves round up. Clamped to 0-100 so no value
    /// can trap the `Int` conversion.
    private static func whole(_ x: Double) -> Int {
        guard x.isFinite else { return 0 }
        return Int((min(max(x, 0), 100) + 0.5).rounded(.down))
    }
}

/// The sheet's words, kept apart so they can be tested. Android twin: `TrustWhyText` in `TrustWhy.kt`.
enum TrustWhyText {
    static func headline(_ why: TrustWhy) -> String { "Score \(why.score) of 100" }

    static func place(_ why: TrustWhy) -> String {
        let hops = why.hop == 1 ? "1 hop" : "\(why.hop) hops"
        let bar = why.overBar ? "at or over the \(why.bar) discovery starts at" : "under the \(why.bar) discovery starts at"
        return "\(hops) from you · \(bar)"
    }

    /// nil when the sheet can't say: in the graph with no bridge seen
    /// (web/unknown), or a follow whose own follows aren't known. "No one"
    /// only when the path says outside.
    static func followersTitle(_ why: TrustWhy) -> String? {
        let n = why.followers.count
        if n == 0 {
            switch why.reach {
            case nil: return "Checking…"
            case .outside: return "No one you follow follows them"
            default: return nil
            }
        }
        let who = n == 1 ? "person you follow follows" : "people you follow follow"
        return why.exact ? "\(n) \(who) them" : "At least \(n) \(who) them"
    }

    /// "How they connect: You > Alice > Bob > Carol", nil with no chain.
    static func chain(_ why: TrustWhy, name: (String) -> String) -> String? {
        why.chain.map { TrustChain.text($0, name: name) }
    }

    /// What the score is made of, in a sentence.
    static let how =
        "Your desktop Vault scores people from the follows of people you trust: a follow from someone with a high score "
        + "counts for more, and trust fades with each hop. The score is yours alone and never published."

    static func more(_ why: TrustWhy) -> String? {
        let rest = why.followers.count - TrustWhy.shown
        return rest > 0 ? "and \(rest) more" : nil
    }
}
