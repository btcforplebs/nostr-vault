import Foundation

/// Who flies on the globe, by how far out they are (rules 1-4 of
/// RESEARCH/NV_GLOBE_STARS_FINAL.md, Logen 2026-11-19). The gate
/// (`WebGate.judge`) is the one hop check: your follows and your web's
/// friends of friends fly as plain stars; anyone further out flies only a
/// zap. Someone you blocked or muted never flies. Nothing is drawn red.
extension GlobeArcs {
    /// Most people the globe names in its REQ. Past it (a very large web)
    /// one filter with no authors is asked instead, and everyone further
    /// out is dropped here: a REQ of thousands of keys costs relays more
    /// than the notes it would save.
    static let maxFilterAuthors = 2_000

    /// Whose activity to ask relays for: you and your follows first, then,
    /// with `friends` on, your web's friends of friends. nil when that is
    /// more than `maxFilterAuthors`: ask with no authors.
    static func askedAuthors(follows: Set<String>, web: Set<String>, friends: Bool) -> [String]? {
        var authors = follows.sorted()
        if friends { authors += web.subtracting(follows).sorted() }
        return authors.count > maxFilterAuthors ? nil : authors
    }

    /// Where `arrival` (from relay event `event`) flies from, or nil when it
    /// doesn't fly. `follows` is you and your follows. The signer is the
    /// arrival's author: a repost's reposter, a zap's verified zapper. The
    /// mute list reads the note's own text and tags; a zap's comment sits
    /// inside its request, so a zap is judged on its zapper alone.
    static func ring(of arrival: Arrival, event: [String: Any], in web: WebGate.Web,
                     follows: Set<String>, show: Show) -> Ring? {
        guard show.allows(arrival.sort) else { return nil }
        let subject: WebGate.Subject = arrival.zap
            ? WebGate.Subject(signer: arrival.author, id: arrival.id)
            : .note(id: arrival.id, author: arrival.author, content: event["content"] as? String ?? "",
                    tags: event["tags"] as? [[String]] ?? [])
        let verdict = WebGate.judge(subject, in: web, reach: .web)
        if verdict == .blocked { return nil }
        if verdict == .inside {
            if follows.contains(arrival.author.lowercased()) { return .following }
            if show.friends { return .friends }
        }
        // Further out (or friends of friends switched off): a zap, nothing else.
        return arrival.zap ? .outside : nil
    }
}
