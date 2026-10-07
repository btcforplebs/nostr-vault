import Foundation

/// The relay matrix: every relay the owner uses, one row each, and the jobs
/// it does. Each job is still its own list underneath, so every feature that
/// reads a list keeps working:
///
/// - Read: `feedRelays` (`HavenConfig.readRelays`)
/// - Write: `blastrRelays` (`HavenConfig.writeRelays`)
/// - DMs: `dmRelays` (published as kind 10050)
/// - Search: the NIP-50 search list (`SearchRelaySettings`)
/// - Import: `importSeedRelays`
///
/// Read and Write together are the public relay list (kind 10002).
enum RelayMatrix {

    enum Job: String, CaseIterable, Identifiable {
        case read, write, dms, search, importing

        var id: String { rawValue }

        var title: String {
            switch self {
            case .read: return "Read"
            case .write: return "Write"
            case .dms: return "DMs"
            case .search: return "Search"
            case .importing: return "Import"
            }
        }

        var detail: String {
            switch self {
            case .read: return "Load your feed, profiles and threads from here"
            case .write: return "Publish your posts here"
            case .dms: return "Inbox for private messages"
            case .search: return "Send searches here"
            case .importing: return "Pull your history into your relay"
            }
        }

        /// The jobs shown as grid columns; the rest are tags under the name
        /// and switches in the relay's detail.
        static let columns: [Job] = [.read, .write, .dms]
        static let advanced: [Job] = [.search, .importing]
    }

    /// The lists the matrix edits, as stored.
    struct Lists: Equatable {
        var read: [String]
        var write: [String]
        var dms: [String]
        var search: [String]
        var importing: [String]

        subscript(job: Job) -> [String] {
            get {
                switch job {
                case .read: return read
                case .write: return write
                case .dms: return dms
                case .search: return search
                case .importing: return importing
                }
            }
            set {
                switch job {
                case .read: read = newValue
                case .write: write = newValue
                case .dms: dms = newValue
                case .search: search = newValue
                case .importing: importing = newValue
                }
            }
        }
    }

    struct Row: Identifiable, Equatable {
        /// The URL as first listed, for display and for the probe.
        let url: String
        let jobs: Set<Job>
        var id: String { RelayMatrix.key(url) }

        func has(_ job: Job) -> Bool { jobs.contains(job) }
    }

    /// Two spellings of one relay compare equal: case, whitespace and trailing
    /// slashes are ignored.
    static func key(_ url: String) -> String {
        HavenConfig.normalizedRelayURL(url).lowercased()
    }

    /// One row per relay, in the order relays first appear across the jobs
    /// (Read, Write, DMs, Search, Import). `pinned` (the owner's own relay) is
    /// left out: it has its own row.
    static func rows(_ lists: Lists, pinned: String = "") -> [Row] {
        var order: [String] = []
        var firstSpelling: [String: String] = [:]
        var jobs: [String: Set<Job>] = [:]
        let pinnedKey = pinned.isEmpty ? nil : key(pinned)
        for job in Job.allCases {
            for raw in lists[job] {
                let url = HavenConfig.normalizedRelayURL(raw)
                guard !url.isEmpty else { continue }
                let k = key(url)
                if k == pinnedKey { continue }
                if firstSpelling[k] == nil {
                    firstSpelling[k] = url
                    order.append(k)
                }
                jobs[k, default: []].insert(job)
            }
        }
        return order.map { Row(url: firstSpelling[$0]!, jobs: jobs[$0] ?? []) }
    }

    /// Turns one job on or off for one relay. Off removes every spelling of
    /// it from that job's list; on appends it once.
    static func setting(_ job: Job, _ on: Bool, for url: String, in lists: Lists) -> Lists {
        var result = lists
        let k = key(url)
        let present = lists[job].contains { key($0) == k }
        if on {
            // Already there: leave the list (and its order) alone.
            if !present { result[job].append(HavenConfig.normalizedRelayURL(url)) }
        } else {
            result[job] = lists[job].filter { key($0) != k }
        }
        return result
    }

    /// Takes a relay out of every job.
    static func removing(_ url: String, from lists: Lists) -> Lists {
        var result = lists
        for job in Job.allCases {
            result = setting(job, false, for: url, in: result)
        }
        return result
    }

    /// What someone typed, as a relay URL: trimmed, `wss://` added when there
    /// is no scheme, trailing slashes dropped. Nil when it can't be a relay.
    static func relayURL(from typed: String) -> String? {
        var url = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, !url.contains(" ") else { return nil }
        let lower = url.lowercased()
        if !lower.hasPrefix("wss://") && !lower.hasPrefix("ws://") {
            if lower.contains("://") { return nil }
            url = "wss://" + url
        }
        url = HavenConfig.normalizedRelayURL(url)
        guard let parsed = URL(string: url), let host = parsed.host, !host.isEmpty else { return nil }
        return url
    }

    /// A relay added from the + button starts with Read and Write: the jobs
    /// people mean when they "add a relay".
    static func adding(_ url: String, to lists: Lists) -> Lists {
        var result = lists
        for job in [Job.read, .write] {
            result = setting(job, true, for: url, in: result)
        }
        return result
    }

    // MARK: - Problems

    enum Problem: Equatable {
        case noRead, noWrite, noDMs, oneDM, noSearch
        case unreachable(String)

        var title: String {
            switch self {
            case .noRead: return "No Read relay"
            case .noWrite: return "No Write relay"
            case .noDMs: return "No DM relay"
            case .oneDM: return "Only one DM relay"
            case .noSearch: return "No Search relay"
            case .unreachable(let url): return "\(RelayMatrix.label(url)) isn't answering"
            }
        }

        var detail: String {
            switch self {
            case .noRead: return "Your feed falls back to relay.primal.net and nos.lol."
            case .noWrite: return "Your posts fall back to relay.primal.net and nos.lol."
            case .noDMs: return "People can't message you."
            case .oneDM: return "If it goes down, nobody can message you. Add a second."
            case .noSearch: return "Search won't find anything."
            case .unreachable: return "It didn't answer just now. Remove it if it stays down."
            }
        }
    }

    /// Problems with the lists, worst first. `ownDMInbox` is the owner's own
    /// inbox, which counts as a DM relay. `unreachable` are relays the probe
    /// could not reach.
    static func problems(_ lists: Lists, ownDMInbox: String, unreachable: [String]) -> [Problem] {
        var result: [Problem] = []
        let nonEmpty = { (list: [String]) in list.contains { !HavenConfig.normalizedRelayURL($0).isEmpty } }
        if !nonEmpty(lists.read) { result.append(.noRead) }
        if !nonEmpty(lists.write) { result.append(.noWrite) }
        let dmCount = HavenConfig.mergedDMInboxRelays(havenInbox: ownDMInbox, dmRelays: lists.dms).count
        if dmCount == 0 { result.append(.noDMs) } else if dmCount == 1 { result.append(.oneDM) }
        if !nonEmpty(lists.search) { result.append(.noSearch) }
        result += unreachable.map { .unreachable($0) }
        return result
    }

    /// The host, for a compact label: "wss://relay.primal.net/" → "relay.primal.net".
    static func label(_ url: String) -> String {
        var s = HavenConfig.normalizedRelayURL(url)
        for scheme in ["wss://", "ws://"] where s.lowercased().hasPrefix(scheme) {
            s = String(s.dropFirst(scheme.count))
        }
        return s
    }
}
