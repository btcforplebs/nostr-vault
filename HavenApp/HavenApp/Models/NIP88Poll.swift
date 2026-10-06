import Foundation

/// NIP-88 polls: a kind 1068 poll and the kind 1018 votes on it.
///
/// A poll names its options in `option` tags and the relays its votes go to
/// in `relay` tags. A vote names the poll by `e` and its picks by `response`.
/// Anyone can publish a vote, so the count is kept honest here: one vote per
/// person (their newest), only options the poll has, and nothing after it
/// closes.
enum NIP88Poll {
    static let kind = 1068
    static let responseKind = 1018
    /// How far ahead of the clock a vote may be dated. The newest vote per
    /// person is the one counted, so a vote dated in 2099 would pin that
    /// person's pick forever; this allows only for clock drift.
    static let maxFutureSkew: TimeInterval = 600
    /// Where votes are looked for and sent, at most this many relays.
    static let maxRelays = 8

    /// Relay filter for a poll's votes.
    static func responseFilters(pollId: String, limit: Int = 1_000) -> [[String: Any]] {
        [["kinds": [responseKind], "#e": [pollId], "limit": limit]]
    }

    /// NIP-88 vote tags: the poll, then one `response` per pick.
    static func responseTags(poll: Poll, optionIds: [String], relayHint: String) -> [[String]] {
        var out: [[String]] = [["e", poll.id, relayHint], ["p", poll.pubkey]]
        var seen = Set<String>()
        let known = Set(poll.options.map(\.id))
        let picks = optionIds.filter { known.contains($0) && seen.insert($0).inserted }
        for id in poll.type == .single ? Array(picks.prefix(1)) : picks {
            out.append(["response", id])
        }
        return out
    }

    /// The relays to read votes from and send them to: the poll's own first
    /// (NIP-88 says votes go there), then `fallback`, deduplicated.
    static func relays(poll: Poll, fallback: [String]) -> [String] {
        var seen = Set<String>()
        return (poll.relays + fallback)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("wss://") || $0.hasPrefix("ws://") }
            .filter { seen.insert($0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))).inserted }
            .prefix(maxRelays)
            .map { $0 }
    }

    /// Counts the votes on `poll`. The caller checks signatures; this checks
    /// that each vote is for this poll, in time, and for options it has.
    static func tally(_ events: [[String: Any]], poll: Poll, now: Date = Date()) -> PollTally {
        let known = Set(poll.options.map(\.id))
        let latestAllowed = min(now.timeIntervalSince1970 + maxFutureSkew,
                                poll.endsAt?.timeIntervalSince1970 ?? .infinity)
        // Each person's newest vote. Ties go to the lower id so every device
        // counts the same vote.
        var newest: [String: (createdAt: Double, id: String, picks: [String])] = [:]
        for event in events {
            guard (event["kind"] as? Int) == responseKind,
                  let id = event["id"] as? String,
                  let pubkey = event["pubkey"] as? String,
                  let createdAt = (event["created_at"] as? NSNumber)?.doubleValue,
                  createdAt <= latestAllowed,
                  let tags = event["tags"] as? [[String]],
                  tags.contains(where: { $0.count >= 2 && $0[0] == "e" && $0[1] == poll.id }) else { continue }
            if let current = newest[pubkey],
               current.createdAt > createdAt || (current.createdAt == createdAt && current.id < id) { continue }
            var seen = Set<String>()
            var picks = tags
                .filter { $0.count >= 2 && $0[0] == "response" && known.contains($0[1]) }
                .map { $0[1] }
                .filter { seen.insert($0).inserted }
            // A single-choice poll counts the first pick only.
            if poll.type == .single { picks = Array(picks.prefix(1)) }
            newest[pubkey] = (createdAt, id, picks)
        }

        var tally = PollTally()
        for (pubkey, vote) in newest where !vote.picks.isEmpty {
            tally.voters.insert(pubkey)
            tally.picksByVoter[pubkey] = vote.picks
            for pick in vote.picks { tally.votersByOption[pick, default: []].insert(pubkey) }
        }
        return tally
    }
}

extension NIP88Poll {
    enum PollType: Equatable {
        case single, multiple
    }

    struct Option: Identifiable, Equatable, Hashable {
        let id: String
        let label: String
    }

    /// A kind 1068 poll, read from its event. Nil when it is not a poll or
    /// has no options to vote on.
    struct Poll: Equatable {
        let id: String
        let pubkey: String
        let question: String
        let options: [Option]
        let type: PollType
        let endsAt: Date?
        let relays: [String]

        init?(id: String, pubkey: String, kind: Int, content: String, tags: [[String]]) {
            guard kind == NIP88Poll.kind else { return nil }
            var seen = Set<String>()
            let options = tags.compactMap { tag -> Option? in
                guard tag.count >= 3, tag[0] == "option" else { return nil }
                let optionId = tag[1].trimmingCharacters(in: .whitespacesAndNewlines)
                let label = tag[2].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !optionId.isEmpty, !label.isEmpty, seen.insert(optionId).inserted else { return nil }
                return Option(id: optionId, label: label)
            }
            guard !options.isEmpty else { return nil }
            self.id = id
            self.pubkey = pubkey
            self.question = content.trimmingCharacters(in: .whitespacesAndNewlines)
            self.options = options
            let typeTag = tags.first { $0.count >= 2 && $0[0] == "polltype" }?[1]
            self.type = typeTag == "multiplechoice" ? .multiple : .single
            if let ends = tags.first(where: { $0.count >= 2 && $0[0] == "endsAt" })?[1],
               let seconds = Double(ends), seconds > 0 {
                self.endsAt = Date(timeIntervalSince1970: seconds)
            } else {
                self.endsAt = nil
            }
            self.relays = tags.filter { $0.count >= 2 && $0[0] == "relay" }.map { $0[1] }
        }

        func isClosed(now: Date = Date()) -> Bool {
            guard let endsAt else { return false }
            return endsAt <= now
        }
    }
}

/// Who voted for what on one poll.
struct PollTally: Equatable {
    /// Everyone whose vote counted.
    var voters: Set<String> = []
    /// The people behind each option, keyed by option id.
    var votersByOption: [String: Set<String>] = [:]
    /// What each person picked, keyed by pubkey.
    var picksByVoter: [String: [String]] = [:]

    func count(_ optionId: String) -> Int { votersByOption[optionId]?.count ?? 0 }

    /// An option's share of the people who voted, 0...1. In a multiple-choice
    /// poll the shares add up to more than 1, the way other clients show it.
    func share(_ optionId: String) -> Double {
        voters.isEmpty ? 0 : Double(count(optionId)) / Double(voters.count)
    }
}

/// The Polls feed's Open / Closed / All filter.
enum PollStatusFilter: String, CaseIterable {
    case all = "All"
    case open = "Open"
    case closed = "Closed"

    func admits(_ poll: NIP88Poll.Poll, now: Date = Date()) -> Bool {
        switch self {
        case .all: return true
        case .open: return !poll.isClosed(now: now)
        case .closed: return poll.isClosed(now: now)
        }
    }
}

/// A poll being written, turned into a kind 1068 event's content and tags.
struct PollDraft: Equatable {
    static let minOptions = 2
    static let maxOptions = 10
    /// Poll relays named in the event, at most this many.
    static let maxRelays = 4

    var question = ""
    var options: [String] = ["", ""]
    var type: NIP88Poll.PollType = .single
    /// When voting closes; nil leaves the poll open.
    var endsAt: Date?

    var trimmedQuestion: String { question.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// The filled-in options, in order.
    var filledOptions: [String] {
        options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// Two different case-insensitive labels at least, a question, and an
    /// end time still ahead.
    func isComplete(now: Date = Date()) -> Bool {
        guard !trimmedQuestion.isEmpty else { return false }
        let labels = filledOptions
        guard labels.count >= Self.minOptions, labels.count <= Self.maxOptions else { return false }
        guard Set(labels.map { $0.lowercased() }).count == labels.count else { return false }
        if let endsAt, endsAt <= now { return false }
        return true
    }

    /// NIP-88 tags: one `option` per label with a short id, the relays votes
    /// go to, the poll type, and `endsAt` when set. `makeId` is for tests.
    func tags(relays: [String], makeId: () -> String = PollDraft.randomOptionId) -> [[String]] {
        var out: [[String]] = []
        var used = Set<String>()
        for label in filledOptions {
            var id = makeId()
            while !used.insert(id).inserted { id = makeId() }
            out.append(["option", id, label])
        }
        var seen = Set<String>()
        for relay in relays {
            let url = relay.trimmingCharacters(in: .whitespacesAndNewlines)
            guard url.hasPrefix("wss://"), seen.insert(url.lowercased()).inserted else { continue }
            out.append(["relay", url])
            if seen.count >= Self.maxRelays { break }
        }
        out.append(["polltype", type == .multiple ? "multiplechoice" : "singlechoice"])
        if let endsAt {
            out.append(["endsAt", String(Int(endsAt.timeIntervalSince1970))])
        }
        return out
    }

    /// A 9-character alphanumeric option id, as other clients use.
    static func randomOptionId() -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<9).map { _ in chars.randomElement()! })
    }
}
