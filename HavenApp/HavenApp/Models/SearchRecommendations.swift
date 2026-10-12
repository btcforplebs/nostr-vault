import Foundation

/// Search tab's "For you": recommendations judged only from what the user's
/// own relay already holds — its trust graph and the notes in the feed. No
/// recommendation server is asked.
enum SearchRecommendations {
    /// Someone you don't follow, and how many of your follows follow them.
    struct Person: Equatable {
        let pubkey: String
        let vouches: Int
    }

    /// Below this many of your follows, a follow-of-a-follow is noise.
    static let minVouches = 2

    /// People your follows follow most, from the relay graph's `vouches`
    /// (pubkey → how many of your follows follow them). Drops you, anyone you
    /// already follow and anyone blocked. Most vouched first, ties by pubkey
    /// so the list doesn't reshuffle between refreshes.
    static func people(vouches: [String: Int],
                       following: Set<String>,
                       owner: String,
                       blocked: Set<String>,
                       limit: Int = 8) -> [Person] {
        vouches
            .filter { $0.value >= minVouches && $0.key != owner
                && !following.contains($0.key) && !blocked.contains($0.key) }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit)
            .map { Person(pubkey: $0.key, vouches: $0.value) }
    }

    /// A note as the picker sees it.
    struct Candidate {
        let id: String
        let pubkey: String
        let tags: [[String]]
        let createdAt: Date
    }

    /// Notes tagged with one of your `interests` (followed hashtags), not
    /// yours, not blocked. Ranked by how many interests a note hits, then by
    /// how close its author is to you (followed, else vouches), then newest.
    /// At most one note per author, so one prolific poster can't fill it.
    static func notes(_ candidates: [Candidate],
                      interests: Set<String>,
                      following: Set<String>,
                      vouches: [String: Int],
                      owner: String,
                      blocked: Set<String>,
                      limit: Int = 5) -> [String] {
        let wanted = Set(interests.map(InterestList.normalize).filter { !$0.isEmpty })
        guard !wanted.isEmpty else { return [] }

        struct Scored {
            let id: String
            let pubkey: String
            let hits: Int
            let closeness: Int
            let createdAt: Date
        }
        // Followed authors outrank anyone the graph knows of.
        let followedCloseness = Int.max

        var scored: [Scored] = []
        for note in candidates where note.pubkey != owner && !blocked.contains(note.pubkey) {
            var hit = Set<String>()
            for tag in note.tags where tag.count >= 2 && tag[0] == "t" {
                let name = InterestList.normalize(tag[1])
                if wanted.contains(name) { hit.insert(name) }
            }
            guard !hit.isEmpty else { continue }
            let closeness = following.contains(note.pubkey) ? followedCloseness : (vouches[note.pubkey] ?? 0)
            scored.append(Scored(id: note.id, pubkey: note.pubkey, hits: hit.count,
                                 closeness: closeness, createdAt: note.createdAt))
        }
        scored.sort {
            if $0.hits != $1.hits { return $0.hits > $1.hits }
            if $0.closeness != $1.closeness { return $0.closeness > $1.closeness }
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id < $1.id
        }
        var authors = Set<String>()
        var out: [String] = []
        for note in scored where authors.insert(note.pubkey).inserted {
            out.append(note.id)
            if out.count == limit { break }
        }
        return out
    }
}
