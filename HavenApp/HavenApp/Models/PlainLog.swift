import Foundation

/// Plain-language view of the relay log for the dashboard console.
///
/// The raw log (Settings › Logs) is for debugging: TLS handshake chatter,
/// database housekeeping, settings dumps, full pubkeys. Most of it means
/// nothing to someone asking "is my relay OK?". This turns each raw line into
/// a short sentence or drops it as noise, folds repeats together, and builds
/// copy/export text that carries no keys, event ids, IP addresses or paths.
///
/// Pure Foundation, so MediaLogicTests compiles and tests it directly.
enum PlainLog {

    enum Severity: Int, Comparable, Sendable {
        /// Normal operation worth seeing: relay up, new activity, import done.
        case good = 0
        /// Recoverable: a remote relay unreachable or refusing a post.
        case headsUp = 1
        /// Needs the user: relay can't start, database locked, port taken.
        case problem = 2

        static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }

        var label: String {
            switch self {
            case .good: return "OK"
            case .headsUp: return "Heads-up"
            case .problem: return "Problem"
            }
        }
    }

    /// One translated line. `key` identifies "the same thing happening again"
    /// so repeats fold into one `Item`.
    struct Message: Equatable, Sendable {
        let key: String
        let severity: Severity
        let title: String
        /// Optional advice on what to do about it.
        let hint: String?
    }

    /// A message and how often it happened in the window.
    struct Item: Identifiable, Equatable, Sendable {
        var id: String { key }
        let key: String
        let severity: Severity
        let title: String
        let hint: String?
        var count: Int
        var firstSeen: Date
        var lastSeen: Date
    }

    // MARK: - Translation

    /// Translates one raw log line, or returns nil when it is noise.
    static func translate(level: String, message: String) -> Message? {
        let m = message
        let lower = m.lowercased()
        let level = level.uppercased()

        if level == "DEBUG" { return nil }
        if isNoise(m, lower: lower) { return nil }

        // Problems the user has to act on.
        if lower.contains("cannot acquire directory lock")
            || lower.contains("another process is using this badger database")
            || (lower.contains("mdb_env_open") && lower.contains("operation not permitted")) {
            return Message(key: "db-locked", severity: .problem,
                           title: "The relay database is in use by another copy of the app",
                           hint: "Quit every copy of Nostr Vault, then open it again.")
        }
        if lower.contains("address already in use") {
            return Message(key: "port-in-use", severity: .problem,
                           title: "Another app is using the relay's port",
                           hint: "Quit the other app, or change the port in Settings › Advanced.")
        }
        if lower.contains("relay stop exceeded") {
            return Message(key: "stop-slow", severity: .problem,
                           title: "The relay is taking too long to stop",
                           hint: "If it doesn't finish, quit and reopen the app.")
        }
        if lower.contains("boot watchdog triggered") {
            return Message(key: "boot-slow", severity: .problem,
                           title: "The relay is taking too long to start",
                           hint: "Try Force Restart on the dashboard.")
        }
        if lower.contains("cannot start relay") || lower.contains("cannot restart: no saved config") {
            return Message(key: "start-blocked", severity: .problem,
                           title: "The relay couldn't start",
                           hint: "Stop it, wait a few seconds and start it again.")
        }
        if lower.hasPrefix("blossom: upload to") && lower.contains("failed") {
            return Message(key: "blossom-local-upload", severity: .problem,
                           title: "Couldn't save media to your relay",
                           hint: "Make sure the relay is running.")
        }
        if lower.contains("error decoding configuration") || lower.contains("failed to save config")
            || lower.contains("error reloading configuration") {
            return Message(key: "config", severity: .problem,
                           title: "Your settings couldn't be read or saved",
                           hint: "Open Settings and save again.")
        }

        // Remote relays: recoverable, grouped per relay host.
        if let host = relayHost(in: m) {
            if lower.contains("error connecting to relay") {
                return Message(key: "connect|\(host)", severity: .headsUp,
                               title: "Couldn't reach \(host)",
                               hint: "That relay may be down. Nothing to do unless it keeps happening.")
            }
            if lower.contains("timeout publishing") {
                return Message(key: "slow|\(host)", severity: .headsUp,
                               title: "\(host) was too slow to accept a post",
                               hint: nil)
            }
            if lower.contains("error publishing") {
                if lower.contains("restricted") || lower.contains("sign up") || lower.contains("paid")
                    || lower.contains("whitelist") || lower.contains("not allowed") || lower.contains("auth-required") {
                    return Message(key: "members|\(host)", severity: .headsUp,
                                   title: "\(host) only accepts posts from its members",
                                   hint: "Remove it from your outbox relays if you don't pay for it.")
                }
                if lower.contains("created_at") {
                    return Message(key: "old|\(host)", severity: .headsUp,
                                   title: "\(host) refused an older post",
                                   hint: "Normal while backing up old posts.")
                }
                return Message(key: "publish|\(host)", severity: .headsUp,
                               title: "\(host) refused a post", hint: nil)
            }
        }
        if lower.contains("dm wrap") && lower.contains("not stored") {
            return Message(key: "dm-not-stored", severity: .headsUp,
                           title: "A private message didn't reach one of the recipient's relays",
                           hint: nil)
        }
        if lower.contains("dm chat relay disconnected") {
            return Message(key: "dm-disconnected", severity: .headsUp,
                           title: "Lost the connection for private messages",
                           hint: "It reconnects on its own.")
        }

        // Normal operation.
        if lower.contains("is booting up") {
            return Message(key: "booting", severity: .good, title: "Relay starting", hint: nil)
        }
        if lower.contains("listening at") || lower.contains("listening on") {
            return Message(key: "running", severity: .good, title: "Relay is running", hint: nil)
        }
        if lower.contains("c-shared relay natively stopped") {
            return Message(key: "stopped", severity: .good, title: "Relay stopped", hint: nil)
        }
        if lower.contains("relay settings changed; restarting") {
            return Message(key: "settings-restart", severity: .good,
                           title: "Restarting the relay to apply new settings", hint: nil)
        }
        if lower.contains("subscribing to inbox on") {
            let n = firstNumber(after: "on ", in: m)
            return Message(key: "inbox-watch", severity: .good,
                           title: n.map { "Watching \($0) relays for replies and messages" }
                               ?? "Watching for replies and messages",
                           hint: nil)
        }
        if lower.contains("import successful") || lower.contains("tagged import complete") {
            return Message(key: "import-done", severity: .good, title: "Import finished", hint: nil)
        }
        if lower.contains("c-shared import sequence started") {
            return Message(key: "import-start", severity: .good, title: "Importing your notes", hint: nil)
        }
        if lower.contains("in your inbox") || lower.contains("in your chat relay") {
            if lower.contains("gift-wrapped") || lower.contains("encrypted message") {
                return Message(key: "new-dm", severity: .good, title: "New private message", hint: nil)
            }
            if lower.contains("zap") { return Message(key: "new-zap", severity: .good, title: "New zap", hint: nil) }
            if lower.contains("reaction") { return Message(key: "new-reaction", severity: .good, title: "New reaction", hint: nil) }
            if lower.contains("repost") { return Message(key: "new-repost", severity: .good, title: "New repost of your post", hint: nil) }
            return Message(key: "new-mention", severity: .good, title: "New reply or mention", hint: nil)
        }

        // Unrecognised errors still surface, scrubbed and shortened, so a
        // new failure mode is never silently hidden. Unrecognised INFO/WARN
        // lines are background chatter and stay in the full log only.
        if level == "ERROR" {
            let text = String(scrub(m).prefix(120))
            return Message(key: "error|\(text)", severity: .problem,
                           title: "Something went wrong: \(text)",
                           hint: "Copy the logs and send them to support if this keeps happening.")
        }
        return nil
    }

    /// Lines that never mean anything to a user: TLS probes against the
    /// self-signed endpoint, database housekeeping, the relay's settings dump,
    /// notification plumbing, and sync fallbacks that recover on their own.
    private static func isNoise(_ m: String, lower: String) -> Bool {
        let trimmed = m.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "{" || trimmed == "}" || trimmed.hasPrefix("\"") { return true }
        let fragments = [
            "tls handshake error", "badger", "💾", "🔔notify|", "nostrservice:",
            "negentropy", "nip-77", "neg-open", "catch-up pull", "relay limits",
            "self-signed certificate", "starter pack", "invalid npub", "error writing ping",
            "event stored", "popular tally", "subscribing to engagement", "cloud backup disabled",
            "wrote .env", "working directory", "copied templates", "captured output natively",
            "database ready", "loading databases", "starting background services",
            "initializing web of trust", "waiting for web of trust",
        ]
        return fragments.contains { lower.contains($0) }
    }

    // MARK: - Grouping

    /// Folds translated lines into items, oldest first (the console scrolls to
    /// the bottom). A repeat updates the existing item's count and lastSeen
    /// and moves it to the end, so the newest activity is always last.
    static func summarize(_ entries: [RelayLogParser.LogEntry]) -> [Item] {
        var order: [String] = []
        var items: [String: Item] = [:]
        for entry in entries {
            guard let msg = translate(level: entry.level, message: entry.message) else { continue }
            if var existing = items[msg.key] {
                existing.count += 1
                existing.lastSeen = entry.timestamp
                items[msg.key] = existing
                if let i = order.firstIndex(of: msg.key) { order.remove(at: i) }
            } else {
                items[msg.key] = Item(key: msg.key, severity: msg.severity, title: msg.title, hint: msg.hint,
                                      count: 1, firstSeen: entry.timestamp, lastSeen: entry.timestamp)
            }
            order.append(msg.key)
        }
        return order.compactMap { items[$0] }
    }

    /// Worst severity seen since the relay last came up, for a status pill.
    /// A problem from before the latest "Relay is running" no longer counts.
    static func health(_ items: [Item]) -> Severity {
        let lastUp = items.first { $0.key == "running" }?.lastSeen ?? .distantPast
        return items.filter { $0.lastSeen >= lastUp && $0.key != "running" }
            .map(\.severity).max() ?? .good
    }

    // MARK: - Safe export

    /// Copy/export text. Built from the translated items only, never the raw
    /// lines, then scrubbed again as a backstop.
    static func exportText(_ items: [Item], header: [String] = [], now: Date = Date()) -> String {
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_US_POSIX")
        time.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var lines = ["Nostr Vault relay report — \(time.string(from: now))"]
        lines.append(contentsOf: header)
        lines.append("Status: \(health(items).label)")
        lines.append("")
        for item in items {
            var line = "[\(time.string(from: item.lastSeen))] \(item.severity.label): \(item.title)"
            if item.count > 1 { line += " (×\(item.count))" }
            lines.append(line)
            if let hint = item.hint { lines.append("    \(hint)") }
        }
        if items.isEmpty { lines.append("Nothing to report.") }
        return scrub(lines.joined(separator: "\n"))
    }

    private static let scrubRules: [(NSRegularExpression, String)] = {
        let rules: [(String, String)] = [
            // Wallet connection strings carry a spending secret.
            (#"nostr\+walletconnect://\S+"#, "[wallet-connect]"),
            (#"\b(nsec|ncryptsec)1[02-9ac-hj-np-z]+"#, "[secret-key]"),
            (#"\b(npub|nprofile|note|nevent|naddr|nrelay)1[02-9ac-hj-np-z]{8,}"#, "[nostr-id]"),
            (#"\b[0-9a-fA-F]{32,}\b"#, "[id]"),
            (#"\b(?:\d{1,3}\.){3}\d{1,3}(?::\d+)?\b"#, "[ip]"),
            (#"\[?[0-9a-fA-F]{1,4}(?::[0-9a-fA-F]{0,4}){3,7}\]?(?::\d+)?"#, "[ip]"),
            (#"[\w.+-]+@[\w-]+\.[\w.-]+"#, "[email]"),
            (#"(?:/Users|/var/mobile|/private|/data/user|/storage|/home)/\S*"#, "[path]"),
            // Keep a URL's scheme and host; drop path and query, where tokens live.
            (#"\b((?:wss?|https?)://[^/\s?#'"]+)[^\s'"]*"#, "$1"),
        ]
        return rules.compactMap { pattern, template in
            (try? NSRegularExpression(pattern: pattern)).map { ($0, template) }
        }
    }()

    /// Removes keys, nostr ids, hex ids, IPs, emails, file paths and URL
    /// paths/queries. Relay host names stay: they are what makes a report useful.
    static func scrub(_ text: String) -> String {
        var out = text
        for (regex, template) in scrubRules {
            let range = NSRange(out.startIndex..., in: out)
            out = regex.stringByReplacingMatches(in: out, range: range, withTemplate: template)
        }
        return out
    }

    // MARK: - Helpers

    private static let relayPattern = try? NSRegularExpression(pattern: #"relay[=:]\s*"?(wss?://[^\s"/]+)"#)

    /// Host of the relay named in a `relay=wss://…` (or parsed `relay: wss://…`) field.
    static func relayHost(in message: String) -> String? {
        guard let regex = relayPattern,
              let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
              let range = Range(match.range(at: 1), in: message),
              let url = URL(string: String(message[range])), let host = url.host else { return nil }
        return host
    }

    private static func firstNumber(after marker: String, in text: String) -> Int? {
        guard let r = text.range(of: marker) else { return nil }
        return text[r.upperBound...].split(separator: " ").first.flatMap { Int($0) }
    }
}
