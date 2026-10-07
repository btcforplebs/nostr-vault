import Foundation

/// "I use Nostr"'s relay check, before the import: which relays to import
/// from. The import reads one fixed list (`importSeedRelays`) and only gives
/// up when every relay on it fails, each after a long timeout, so one dead
/// relay can stall it and notes kept elsewhere never arrive. The check puts
/// the person's own write relays first, asks every relay for one of their
/// notes at once, and switches off the ones that don't answer.
enum RelayCheck {
    /// Past this a relay is "slow". Past `timeout` it's "not answering".
    static let slowAfter: TimeInterval = 2
    static let timeout: TimeInterval = 4

    enum Result: Equatable {
        case checking
        /// Answered in time. `hasNotes`: it sent one of their notes.
        case ready(seconds: Double, hasNotes: Bool)
        case slow(seconds: Double, hasNotes: Bool)
        case notAnswering
        /// Answered, but refused the request (CLOSED): e.g. a chat-only
        /// relay that doesn't keep notes.
        case refused

        init(answeredAfter seconds: Double?, hasNotes: Bool) {
            guard let seconds, seconds <= RelayCheck.timeout else { self = .notAnswering; return }
            self = seconds > RelayCheck.slowAfter
                ? .slow(seconds: seconds, hasNotes: hasNotes)
                : .ready(seconds: seconds, hasNotes: hasNotes)
        }

        /// On by default: answered, and if slow, only when it has their notes.
        var onByDefault: Bool {
            switch self {
            case .ready: return true
            case .slow(_, let hasNotes): return hasNotes
            case .checking, .notAnswering, .refused: return false
            }
        }

        var label: String {
            switch self {
            case .checking: return "Checking…"
            case .ready(let s, true): return "Ready · \(Self.format(s))"
            case .ready(let s, false): return "Ready · none of your notes found · \(Self.format(s))"
            case .slow(let s, true): return "Slow, but has your notes · \(Self.format(s))"
            case .slow(let s, false): return "Slow · none of your notes found · \(Self.format(s))"
            case .notAnswering: return "Not answering · skipped"
            case .refused: return "Doesn't keep notes · skipped"
            }
        }

        private static func format(_ seconds: Double) -> String {
            String(format: "%.1fs", seconds)
        }
    }

    struct Row: Equatable, Identifiable {
        let url: String
        /// From their own relay list (kind 10002).
        let isYours: Bool
        var result: Result = .checking
        var isOn = false
        var id: String { url }
    }

    /// Their write relays first (marked yours), then the defaults, without
    /// duplicates. `relayListTags` are the kind-10002 `r` tags; a relay
    /// marked "read" only is where they read, not where their notes are.
    static func rows(relayListTags: [[String]], defaults: [String]) -> [Row] {
        var seen = Set<String>()
        var rows: [Row] = []
        for tag in relayListTags where tag.first == "r" && tag.count >= 2 {
            let marker = tag.count >= 3 ? tag[2] : ""
            guard marker != "read", let url = normalize(tag[1]), seen.insert(url).inserted else { continue }
            rows.append(Row(url: url, isYours: true))
        }
        for raw in defaults {
            guard let url = normalize(raw), seen.insert(url).inserted else { continue }
            rows.append(Row(url: url, isYours: false))
        }
        return rows
    }

    /// `wss://host[:port][/path]`, lowercased host, no trailing slash. A bare
    /// host gets `wss://`. Anything that isn't a websocket address is nil.
    static func normalize(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text.contains(" ") { return nil }
        if !text.contains("://") { text = "wss://" + text }
        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), scheme == "wss" || scheme == "ws",
              let host = components.host?.lowercased(), host.contains("."),
              !host.hasPrefix("."), !host.hasSuffix(".") else { return nil }
        var out = "\(scheme)://\(host)"
        if let port = components.port { out += ":\(port)" }
        let path = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        out += path
        return out
    }

    /// "6 relays are ready to import from. 1 didn't answer, so we'll skip it."
    static func summary(_ rows: [Row]) -> String {
        let on = rows.filter(\.isOn).count
        let dead = rows.filter { $0.result == .notAnswering }.count
        var text = on == 1 ? "1 relay is ready to import from." : "\(on) relays are ready to import from."
        if on == 0 { text = "No relays are ready to import from. Add one, or check again." }
        if dead == 1 { text += " 1 didn't answer, so we'll skip it." }
        if dead > 1 { text += " \(dead) didn't answer, so we'll skip them." }
        let refused = rows.filter { $0.result == .refused }.count
        if refused == 1 { text += " 1 doesn't keep notes." }
        if refused > 1 { text += " \(refused) don't keep notes." }
        return text
    }

    /// What the import reads, in order.
    static func importList(_ rows: [Row]) -> [String] {
        rows.filter(\.isOn).map(\.url)
    }
}
