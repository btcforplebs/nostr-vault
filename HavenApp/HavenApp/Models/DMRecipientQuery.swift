import Foundation

/// What the new-chat box makes of what you typed (B2, 2026-11-19): the same
/// on iPhone, iPad and Mac. A key (npub, nprofile or 64-char hex, with or
/// without `nostr:`) names one person, loaded or not; anything else searches
/// the names of profiles already loaded. Blocked people and your own account
/// never come up (B3).
enum DMRecipientQuery {
    enum Outcome: Equatable {
        /// Too short to search.
        case idle
        /// Exactly one person, by key.
        case key(String)
        /// That key is someone you blocked.
        case blocked
        /// It looks like a key but doesn't read as one.
        case badKey
        /// Your own account's key.
        case yourself
        /// Loaded profiles whose name matches, best first.
        case matches([String])
        /// Nothing loaded matches.
        case noMatch
    }

    static let minimumSearch = 2

    static func resolve(_ typed: String, names: [String: String], blocked: Set<String>,
                        own: String, limit: Int = 10) -> Outcome {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("nostr:") { text = String(text.dropFirst(6)) }
        let lower = text.lowercased()
        if lower.hasPrefix("npub1") || lower.hasPrefix("nprofile1") {
            guard let hex = QuoteReference.profilePubkey(fromBech32: lower) else { return .badKey }
            return person(hex, blocked: blocked, own: own)
        }
        if lower.count == 64, lower.allSatisfy(\.isHexDigit) {
            return person(lower, blocked: blocked, own: own)
        }
        guard text.count >= minimumSearch else { return .idle }
        let skip = Set(blocked.map { $0.lowercased() }).union([own.lowercased()])
        let hits = names
            .filter { !skip.contains($0.key.lowercased()) && $0.value.lowercased().contains(lower) }
            .sorted { a, b in
                let pa = a.value.lowercased().hasPrefix(lower), pb = b.value.lowercased().hasPrefix(lower)
                if pa != pb { return pa }
                return a.value.localizedCaseInsensitiveCompare(b.value) == .orderedAscending
            }
            .prefix(limit)
            .map(\.key)
        return hits.isEmpty ? .noMatch : .matches(Array(hits))
    }

    private static func person(_ hex: String, blocked: Set<String>, own: String) -> Outcome {
        if BlockedPeople.isBlocked(hex, in: blocked) { return .blocked }
        if hex == own.lowercased() { return .yourself }
        return .key(hex)
    }
}
