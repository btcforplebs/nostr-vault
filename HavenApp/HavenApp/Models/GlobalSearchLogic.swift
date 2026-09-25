import Foundation

// Pure rules for Global search: which relays to ask, how to tell whether an
// own-store hit really matches, how a source's answer turns into a status, and
// how merged results are ordered. No networking and no app types here, so the
// test package can compile this file on its own.

// MARK: - Search relays

enum SearchRelayDefaults {
    /// NIP-50 services queried by Global search unless the user changes the list.
    ///
    /// From a live probe of 22 relays (2026-09-24): nostr.wine answers notes and
    /// profiles fast; search.nos.today is slow (4-16 s) but good; vertexlab and
    /// nostrver.se only search profiles. relay.nostr.band (handshake timeout)
    /// and relay.noswhere.com (0 results for everything) are gone.
    static let relays = [
        "wss://nostr.wine",
        "wss://search.nos.today",
        "wss://relay.vertexlab.io",
        "wss://profiles.nostrver.se"
    ]

    /// UserDefaults key. Absent means "use the defaults", so a device that never
    /// opened the setting picks up a changed default list on upgrade.
    static let userDefaultsKey = "searchRelays"

    /// The list to use given what is stored. `nil` (never set) is the defaults;
    /// an empty stored list is honoured — the user removed them all.
    static func effective(stored: [String]?) -> [String] {
        guard let stored else { return relays }
        return normalized(stored)
    }

    /// What two entries are compared by: trimmed, case-folded, no trailing
    /// slash. The settings editor uses the same key, so a row it shows is a
    /// row that is saved.
    static func key(_ relay: String) -> String {
        var key = relay.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while key.hasSuffix("/") { key.removeLast() }
        return key
    }

    /// Trims, drops blanks and duplicates (by `key`), keeps order.
    static func normalized(_ list: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in list {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard seen.insert(key(trimmed)).inserted else { continue }
            out.append(trimmed)
        }
        return out
    }
}

// MARK: - Term matching

/// "Does this own-store event actually match the query?" Case-insensitive,
/// and every whitespace-separated term has to appear somewhere in the text.
///
/// Used for results from the phone's store and the Mac relay. A server that
/// ignores `search` hands back its whole store, and even a real NIP-50 server
/// may match looser than we want, so own-store hits are re-checked here.
struct SearchTermMatcher: Equatable {
    let terms: [String]

    init?(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return nil }
        let terms = trimmed.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !terms.isEmpty else { return nil }
        self.terms = terms
    }

    func matches(_ text: String) -> Bool {
        let haystack = text.lowercased()
        return terms.allSatisfy { haystack.contains($0) }
    }

    /// Each term must occur in at least one field, so "jane doe" matches name
    /// "jane" + nip05 "doe@example.com". Same rule as Android's matcher.
    func matches(fields: [String?]) -> Bool {
        let hay = fields.compactMap { $0?.lowercased() }
        return terms.allSatisfy { term in hay.contains { $0.contains(term) } }
    }

    /// A note's searchable text: its content plus the headline tags
    /// (`title`, `summary`, `subject`) — what haven-go's `searchText` matches,
    /// so a hit the Mac relay returns for a long-form title is not thrown
    /// away on-device.
    static func noteFields(content: String, tags: [[String]]) -> [String] {
        var parts = [content]
        for tag in tags where tag.count >= 2 && ["title", "summary", "subject"].contains(tag[0]) {
            parts.append(tag[1])
        }
        return parts
    }

    func matchesNote(content: String, tags: [[String]]) -> Bool {
        matches(Self.noteFields(content: content, tags: tags).joined(separator: "\n"))
    }
}

// MARK: - Ranking

enum GlobalSearchRanking {
    /// Lower sorts first: the user's own posts, then people they follow, then everyone.
    static func tier(pubkey: String, own: Set<String>, follows: Set<String>) -> Int {
        if own.contains(pubkey) { return 0 }
        if follows.contains(pubkey) { return 1 }
        return 2
    }

    /// Own, then follows, then everyone; newest first within a tier. Ties on
    /// time break on id so the order is stable while results stream in.
    static func rankNotes<T>(_ items: [T],
                             own: Set<String>,
                             follows: Set<String>,
                             pubkey: (T) -> String,
                             createdAt: (T) -> Date,
                             id: (T) -> String) -> [T] {
        items
            .map { (item: $0, tier: tier(pubkey: pubkey($0), own: own, follows: follows)) }
            .sorted { a, b in
                if a.tier != b.tier { return a.tier < b.tier }
                let ta = createdAt(a.item), tb = createdAt(b.item)
                if ta != tb { return ta > tb }
                return id(a.item) < id(b.item)
            }
            .map(\.item)
    }

    /// Profiles carry no timestamp, so within a tier they keep arrival order —
    /// the order the sources returned them in, which is the services' own ranking.
    static func rankProfiles(_ pubkeysInArrivalOrder: [String],
                             own: Set<String>,
                             follows: Set<String>) -> [String] {
        pubkeysInArrivalOrder.enumerated()
            .map { (pubkey: $0.element, order: $0.offset,
                    tier: tier(pubkey: $0.element, own: own, follows: follows)) }
            .sorted { a, b in
                if a.tier != b.tier { return a.tier < b.tier }
                return a.order < b.order
            }
            .map(\.pubkey)
    }
}

// MARK: - Per-source status

/// What one Global search source is doing, as shown in the status chips.
enum GlobalSearchSourceState: Equatable {
    case searching
    /// Answered. `count` may be 0 — "0 found" is an answer, not a failure.
    case found(Int)
    /// Never answered; the reason is shown to the user.
    case noAnswer(String)

    var isFinished: Bool {
        if case .searching = self { return false }
        return true
    }
}

/// Bookkeeping for one source's subscriptions, reduced to a status.
///
/// A source has several REQs (kind 0 and kind 1, per route). Each one ends on
/// EOSE (answered), CLOSED (refused) or a socket error. A source counts as
/// answered if ANY of its REQs reached EOSE or delivered an event — a
/// profile-only service that CLOSES the notes REQ but answers the profiles one
/// has answered.
struct GlobalSearchSourceProgress: Equatable {
    private(set) var pending: Int
    private(set) var answered = false
    private(set) var results = 0
    private(set) var failures: [String] = []
    private(set) var timedOut = false

    init(pending: Int) { self.pending = pending }

    mutating func addPending(_ n: Int) { pending += n }

    mutating func eose() {
        answered = true
        pending = max(0, pending - 1)
    }

    mutating func closed(reason: String) {
        failures.append(reason.isEmpty ? "closed" : reason)
        pending = max(0, pending - 1)
    }

    /// A socket failed: every REQ still open on it is over.
    mutating func failed(reason: String, openReqs: Int) {
        failures.append(reason)
        pending = max(0, pending - openReqs)
    }

    mutating func event(counted: Bool) {
        answered = true
        if counted { results += 1 }
    }

    /// Sets the result count without claiming an answer — the phone store's
    /// matches can include profiles from the in-memory cache even when the
    /// relay itself never replied.
    mutating func setResults(_ n: Int) { results = n }

    /// The source replied (a paged walk got a page back) without closing a REQ.
    mutating func markAnswered() { answered = true }

    /// One REQ-like unit finished without a specific outcome (e.g. the Mac
    /// relay's NIP-11 probe, which is replaced by the real subscriptions).
    mutating func resolve() { pending = max(0, pending - 1) }

    mutating func timeout() {
        if pending > 0 { timedOut = true }
        pending = 0
    }

    var isDone: Bool { pending == 0 }

    var state: GlobalSearchSourceState {
        guard isDone else { return .searching }
        if answered { return .found(results) }
        if timedOut { return .noAnswer("timed out") }
        if let reason = failures.first { return .noAnswer(reason) }
        return .noAnswer("no response")
    }
}

// MARK: - NIP-11

enum RelayInfoDocument {
    /// The http(s) URL a relay serves its NIP-11 document on: same host, port
    /// and path as the websocket URL, with ws→http and wss→https.
    static func url(forRelay relay: URL) -> URL? {
        guard var comps = URLComponents(url: relay, resolvingAgainstBaseURL: false) else { return nil }
        switch comps.scheme?.lowercased() {
        case "wss": comps.scheme = "https"
        case "ws": comps.scheme = "http"
        case "https", "http": break
        default: return nil
        }
        if comps.path.isEmpty { comps.path = "/" }
        return comps.url
    }

    /// Whether a NIP-11 document lists NIP-50 in `supported_nips`. Accepts
    /// numbers or numeric strings; anything unparseable is "no".
    static func supportsNIP50(_ data: Data) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let nips = obj["supported_nips"] as? [Any] else { return false }
        return nips.contains { value in
            if let n = value as? NSNumber { return n.intValue == 50 }
            if let s = value as? String { return Int(s) == 50 }
            return false
        }
    }
}

// MARK: - Merge

/// Dedupes streamed results from every source: notes by event id, profiles by
/// pubkey. Generic so it can be tested without the app's model types.
struct GlobalSearchMerge<Note, Profile> {
    private(set) var notes: [String: Note] = [:]
    private(set) var profiles: [String: Profile] = [:]
    /// created_at of the kind 0 held for each pubkey.
    private(set) var profileCreatedAt: [String: Int64] = [:]
    /// Profiles in the order they first arrived.
    private(set) var profileOrder: [String] = []

    init() {}

    /// Returns true when the note was new.
    @discardableResult
    mutating func add(note: Note, id: String) -> Bool {
        guard notes[id] == nil else { return false }
        notes[id] = note
        return true
    }

    /// The newest kind 0 wins (by created_at; a tie keeps the one already
    /// held). The pubkey keeps the position it first arrived at — arrival
    /// order is the ranking inside a tier. Pass createdAt 0 when unknown
    /// (e.g. the in-memory profile cache), so any real event replaces it.
    /// Returns true when the pubkey was new or its profile was replaced.
    @discardableResult
    mutating func add(profile: Profile, pubkey: String, createdAt: Int64) -> Bool {
        if let held = profileCreatedAt[pubkey] {
            guard createdAt > held else { return false }
            profiles[pubkey] = profile
            profileCreatedAt[pubkey] = createdAt
            return true
        }
        profiles[pubkey] = profile
        profileCreatedAt[pubkey] = createdAt
        profileOrder.append(pubkey)
        return true
    }
}
