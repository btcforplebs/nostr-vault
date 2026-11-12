import Foundation

/// Relay log parsing and metrics extraction — no Combine, no SwiftUI.
/// Portable: identical string parsing logic on both iOS and Android.
enum RelayLogParser {

    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let level: String
        let message: String

        private static let logPattern = try? NSRegularExpression(
            pattern: "^\\d{4}/\\d{2}/\\d{2}\\s\\d{2}:\\d{2}:\\d{2}\\s(INFO|WARN|ERROR|DEBUG)\\s",
            options: .caseInsensitive
        )
        // `\b` first: without it the engine retried from every character of
        // a long word, so one 4 KB line took 0.8 s and 32 KB took 55 s.
        // Same matches (a key always starts at a word boundary).
        private static let kvPattern = try? NSRegularExpression(
            pattern: "\\b(\\w+)=([^\\s]+)",
            options: []
        )

        static func parse(_ line: String) -> LogEntry {
            var message = line

            let level = RelayLogBytes.contains(line, "ERROR") ? "ERROR" :
                        RelayLogBytes.contains(line, "WARN") ? "WARN" : "INFO"

            if let regex = logPattern {
                let range = NSRange(location: 0, length: message.utf16.count)
                message = regex.stringByReplacingMatches(in: message, options: [], range: range, withTemplate: "")
            }

            if message.hasPrefix("INFO ") { message = String(message.dropFirst(5)) }
            else if message.hasPrefix("WARN ") { message = String(message.dropFirst(5)) }
            else if message.hasPrefix("ERROR ") { message = String(message.dropFirst(6)) }

            if message.hasPrefix("badger ") {
                message = message.replacingOccurrences(of: "badger ", with: "\u{1F4BE} ")
            }

            if let kvRegex = kvPattern {
                let range = NSRange(location: 0, length: message.utf16.count)
                message = kvRegex.stringByReplacingMatches(in: message, options: [], range: range, withTemplate: "$1: $2")
            }

            return LogEntry(timestamp: Date(), level: level, message: message.trimmingCharacters(in: .whitespaces))
        }
    }

    /// Accumulated state changes from background log parsing — applied
    /// in a single MainActor dispatch by the caller.
    struct BatchedStateUpdate {
        var importProgress: Double?
        var importStatusMessage: String?
        var bootStatusMessage: String?
        var stopBooting: Bool = false
        var stopWotSyncing: Bool = false
        var eventsStoredDelta: Int = 0
        /// Kinds of the inbound events from OTHERS that tag you (replies,
        /// reactions, zaps, reposts, DMs / gift-wraps). Drives the "new relay
        /// activity" red dot, which needs the kind to say where to look —
        /// deliberately excludes your own posts/blasts and private/outbox writes.
        var inboxActivityKinds: Set<Int> = []
        var connectionsDelta: Int = 0
        var isLocked: Bool = false
        var isPortConflict: Bool = false
        var progressDateStr: String?
        var progressBump: Bool = false
        /// Bodies of `🔔NOTIFY|` markers (everything after the prefix) collected
        /// in this batch. Forwarded to LocalNotificationService on the main actor.
        var notifyMarkers: [String] = []
        /// `type=listversion` markers: a new version of one of the owner's
        /// lists reached the vault. Never a notification or an unread count
        /// of their own; ListWipeWatcher runs the wipe-alarm rule on them.
        var listVersionMarkers: [String] = []
        /// Moving in's list history scan started (true) or ended (false).
        var listHistoryScanning: Bool?
        /// The scan's closing count line.
        var listHistoryNote: String?
        /// The Go side began an import cycle (ImportStartGate).
        var importEngineStarted = false
        /// A start the Go side refused or that failed (its
        /// `RELAY_START_FAILED|` line), with the reason. StartRelayC returns
        /// nothing, so without this the app sat on "Booting…" for the whole
        /// watchdog with every control disabled.
        var startFailed: String?
        /// `IMPORT_JOB` lines (ImportJobs): a first-run or Vault job moved.
        var importJobLines: [ImportJobs.Line] = []
        /// `COPY` lines (MeshCopyV2): the mesh vault copy moved.
        var copyLines: [MeshCopyV2.Progress] = []
    }

    /// Longest line handed to the parser. It runs ~50 substring scans, a
    /// lowercased copy and (window up) two regexes per line, so one 200 KB
    /// line (an event dump) cost as much as thousands of normal ones; the
    /// Mac reader sat at a full core on Logen's .99 Mac (2026-11-11). Every
    /// state line it looks for fits well inside this; relay.log itself
    /// keeps the whole line.
    static let maxParsedLineBytes = 4096

    /// Lines acted on in full, never cut: a notification marker carries the
    /// whole recipient list.
    static let wholeLineMarkers = ["🔔NOTIFY|"]

    /// The lines of a chunk of relay output, empty lines left out, each cut
    /// to `maxParsedLineBytes` (marker lines excepted).
    static func lines(in output: String) -> [String] {
        output.components(separatedBy: .newlines).compactMap { $0.isEmpty ? nil : capped($0) }
    }

    /// `line` cut to `maxParsedLineBytes` on a character boundary, unless a
    /// marker shows in its first 256 bytes.
    static func capped(_ line: String) -> String {
        let utf8 = line.utf8
        guard utf8.count > maxParsedLineBytes else { return line }
        let head = String(decoding: utf8.prefix(256), as: UTF8.self)
        if wholeLineMarkers.contains(where: { head.contains($0) }) { return line }
        var end = utf8.index(utf8.startIndex, offsetBy: maxParsedLineBytes)
        while end > utf8.startIndex, end.samePosition(in: line) == nil {
            end = utf8.index(before: end)
        }
        return String(line[..<end])
    }

    /// The `RELAY_START_FAILED|` line (haven-go cshared.go logStartFailed).
    static let startFailedMarker = "RELAY_START_FAILED|"

    /// Whether a batch must be applied even while the app's window isn't up.
    /// The ones that change what the menu bar shows (Booting, Syncing,
    /// Online, the connection count, the activity dot) are here: dropping
    /// them left "Syncing" up for good after a background restart.
    static func isCritical(_ batch: BatchedStateUpdate) -> Bool {
        batch.isLocked || batch.isPortConflict
            || batch.stopBooting
            || batch.stopWotSyncing
            || batch.startFailed != nil
            || batch.importEngineStarted
            || batch.eventsStoredDelta != 0
            || batch.connectionsDelta != 0
            || !batch.inboxActivityKinds.isEmpty
            || !batch.notifyMarkers.isEmpty
            || !batch.listVersionMarkers.isEmpty
            || !batch.importJobLines.isEmpty
            || !batch.copyLines.isEmpty
    }

    // Cached regex patterns for boot/import status parsing
    private static let analysedPattern = try? NSRegularExpression(
        pattern: "(?:analysed|count=)(\\d+)", options: .caseInsensitive
    )
    private static let trustGraphPattern = try? NSRegularExpression(
        pattern: "(?:kept=|followers: )(\\d+)", options: .caseInsensitive
    )
    private static let pubkeysPattern = try? NSRegularExpression(
        pattern: "pubkeys=(\\d+)", options: .caseInsensitive
    )

    /// The kind of the event an inbox/chat import line (`logInboxImport` in
    /// haven-go/import.go) reports, or nil for any other line. A "new note"
    /// line covers comments too; both live in the Notes list, so 1 stands
    /// for either. Reactions go first: their line leads with the reaction's
    /// own content, which could say anything.
    static func inboxActivityKind(in line: String) -> Int? {
        if RelayLogBytes.contains(line, "new reaction in your inbox") { return 7 }
        if RelayLogBytes.contains(line, "new note in your inbox") { return 1 }
        if RelayLogBytes.contains(line, "new zap in your inbox") { return 9735 }
        if RelayLogBytes.contains(line, "new encrypted message in your inbox") { return 4 }
        if RelayLogBytes.contains(line, "new gift-wrapped message in your chat relay") { return 1059 }
        if RelayLogBytes.contains(line, "new repost in your inbox") { return 6 }
        if RelayLogBytes.contains(line, "event in your inbox"), let r = line.range(of: "new event kind ") {
            return Int(line[r.upperBound...].prefix { $0.isNumber })
        }
        return nil
    }

    /// "2024-03-15": a log line's date, not some other ten characters.
    static func isDay(_ s: String) -> Bool {
        s.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }

    /// Extract state changes from a single log line.
    /// Pure string parsing — no MainActor, no UI dependencies.
    /// The per-event lines take one byte comparison (fastStateChanges);
    /// the rest get the full parse.
    static func collectStateChanges(from line: String, into batch: inout BatchedStateUpdate) {
        if fastStateChanges(from: line, into: &batch) { return }
        fullStateChanges(from: line, into: &batch)
    }

    /// Every check, as byte searches (RelayLogBytes): Foundation's
    /// `contains` walked grapheme clusters on every emoji line.
    static func fullStateChanges(from line: String, into batch: inout BatchedStateUpdate) {
        if ImportStartGate.isEngineStart(line) { batch.importEngineStarted = true }
        if let job = ImportJobs.parseLine(line) {
            batch.importJobLines.append(job)
            return
        }
        if let copy = MeshCopyV2.parseLine(line) {
            batch.copyLines.append(copy)
            return
        }
        if ListHistoryScan.collect(from: line, into: &batch) { return }
        // Import state
        if RelayLogBytes.contains(line, "connected successfully") {
            batch.importProgress = 0.1
            batch.importStatusMessage = "Connected to relays..."
        } else if RelayLogBytes.contains(line, "No notes found for") {
            // An empty 10-day window (import.go): still progress through the
            // history, so the bar and the "from <month>" line keep moving for
            // someone with gaps (or a new key with no notes at all).
            if let dateStr = line.components(separatedBy: "to ").last?.prefix(10) {
                batch.progressDateStr = String(dateStr)
            }
            // Search for " to" only AFTER "for " — a " to" earlier in the
            // line would make the slice's end precede its start and trap.
            if let rangeStart = line.range(of: "for ")?.upperBound,
               let rangeEnd = line.range(of: " to", range: rangeStart..<line.endIndex)?.lowerBound {
                batch.importStatusMessage = "Looking through notes from \(line[rangeStart..<rangeEnd])..."
            }
        } else if RelayLogBytes.contains(line, "Imported") && RelayLogBytes.contains(line, "notes") {
            let dateStr = line.components(separatedBy: "to ").last.map { String($0.prefix(10)) }
            if let dateStr {
                batch.progressDateStr = dateStr
            }
            // The month on screen is the range's END: a whole-history lane
            // (import_owner.go) logs "from <start> to <today>", and showing
            // its start held the screen on "Jan 2023" (12 mini, 2026-11-05).
            // A window's end is the month just read.
            if let dateStr, line.range(of: "from ") != nil, isDay(dateStr) {
                batch.importStatusMessage = "Found notes from \(dateStr)..."
            } else {
                batch.importStatusMessage = "Found notes..."
            }
        } else if RelayLogBytes.contains(line, "Initializing WoT") || RelayLogBytes.contains(line, "building WoT") || RelayLogBytes.contains(line, "fetching Nostr events") {
            batch.importStatusMessage = "Building Web of Trust..."
            batch.importProgress = 0.2
        } else if RelayLogBytes.contains(line, "analysing Nostr events") {
            batch.importStatusMessage = "Analysing Web of Trust..."
            batch.importProgress = 0.3
        } else if RelayLogBytes.contains(line, "importing inbox notes") || RelayLogBytes.contains(line, "Importing inbox notes") {
            batch.importStatusMessage = "Importing tagged notes..."
            batch.importProgress = 0.85
        } else if RelayLogBytes.contains(line, "tagged import complete") {
            // Not the end: only IMPORT_RESULT says how the import went
            // (ImportResult). "subscribing to inbox" is a normal relay boot
            // line and says nothing about an import.
            batch.importProgress = 0.95
            batch.importStatusMessage = "Tagged notes imported"
        } else if RelayLogBytes.contains(line, "imported") && RelayLogBytes.contains(line, "tagged notes") {
            if let countMatch = line.components(separatedBy: " ").first(where: { Int($0) != nil }) {
                batch.importProgress = 0.95
                batch.importStatusMessage = "Imported \(countMatch) tagged notes"
            } else {
                batch.importProgress = 0.95
                batch.importStatusMessage = "Tagged notes imported"
            }
        } else if RelayLogBytes.contains(line, "Import complete") || RelayLogBytes.contains(line, "import complete") {
            batch.importProgress = 0.95
        } else if RelayLogBytes.contains(line, "No notes found") {
            if let dateStr = line.components(separatedBy: "to ").last?.prefix(10) {
                batch.progressDateStr = String(dateStr)
                if let fromIndex = line.components(separatedBy: "for ").last?.prefix(10) {
                    batch.importStatusMessage = "Checking \(fromIndex)... (No notes found)"
                }
            } else {
                batch.progressBump = true
            }
        }

        // Event counts
        if RelayLogBytes.contains(line, "Imported") && RelayLogBytes.contains(line, "notes") && !RelayLogBytes.contains(line, "complete") {
            let components = line.components(separatedBy: " ")
            if let importedIndex = components.firstIndex(of: "Imported"),
               importedIndex + 1 < components.count,
               let count = Int(components[importedIndex + 1]) {
                batch.eventsStoredDelta += count
            }
        } else if RelayLogBytes.contains(line, "imported") && RelayLogBytes.contains(line, "tagged notes") {
            let components = line.components(separatedBy: " ")
            if let importedIndex = components.firstIndex(of: "imported"),
               importedIndex + 1 < components.count,
               let count = Int(components[importedIndex + 1]) {
                batch.eventsStoredDelta += count
            }
        } else if RelayLogBytes.contains(line, "event stored") {
            batch.eventsStoredDelta += 1
        } else if RelayLogBytes.contains(line, "new note") ||
                  RelayLogBytes.contains(line, "new repost") ||
                  RelayLogBytes.contains(line, "new reaction") ||
                  RelayLogBytes.contains(line, "new zap") ||
                  RelayLogBytes.contains(line, "new encrypted message") ||
                  RelayLogBytes.contains(line, "new event kind") ||
                  RelayLogBytes.contains(line, "blasted event") {
            batch.eventsStoredDelta += 1
        }

        // Activity from OTHERS only — the inbox/chat import handler logs these
        // exclusively for events authored by other people that tag you. Your own
        // posts ("event stored"/"blasted event") never hit this path, so this is
        // the precise signal for the "new relay activity" red dot.
        if let kind = inboxActivityKind(in: line) {
            batch.inboxActivityKinds.insert(kind)
        }

        if RelayLogBytes.contains(line, startFailedMarker), let r = line.range(of: startFailedMarker) {
            batch.startFailed = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        }

        // Local notification markers — collect for LocalNotificationService.
        let notifyPrefix = "🔔NOTIFY|"
        if RelayLogBytes.contains(line, notifyPrefix), let r = line.range(of: notifyPrefix) {
            let body = String(line[r.upperBound...])
            if body.hasPrefix("type=listversion|") {
                batch.listVersionMarkers.append(body)
            } else {
                batch.notifyMarkers.append(body)
            }
        }

        // Booting status
        let lowerLine = RelayLogBytes.asciiLowercased(line)
        if RelayLogBytes.contains(lowerLine, "subscribing to") {
            if let topic = line.components(separatedBy: "to ").last {
                batch.bootStatusMessage = "Subscribing to \(topic.trimmingCharacters(in: .punctuationCharacters))..."
            }
        } else if RelayLogBytes.contains(lowerLine, "is booting up") {
            batch.bootStatusMessage = "Booting Haven..."
        } else if RelayLogBytes.contains(lowerLine, "starting deeper web of trust") {
            batch.bootStatusMessage = "Analyzing trust graph..."
        } else if RelayLogBytes.contains(lowerLine, "starting") {
            if let service = line.components(separatedBy: "starting ").last ?? line.components(separatedBy: "Starting ").last {
                let cleanService = service.components(separatedBy: "\"").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? service
                batch.bootStatusMessage = "Starting \(cleanService.trimmingCharacters(in: .punctuationCharacters))..."
            }
        } else if RelayLogBytes.contains(lowerLine, "listening at") || RelayLogBytes.contains(lowerLine, "listening on") {
            batch.bootStatusMessage = "Initializing network listeners..."
            batch.stopBooting = true
        } else if RelayLogBytes.contains(lowerLine, "building web of trust graph") || RelayLogBytes.contains(lowerLine, "initializing wot") {
            batch.bootStatusMessage = "Building trust network..."
        } else if RelayLogBytes.contains(lowerLine, "analysed") || RelayLogBytes.contains(lowerLine, "analysing nostr events") {
            if let regex = analysedPattern,
               let match = regex.firstMatch(in: line, options: [], range: NSRange(line.startIndex..., in: line)),
               let range = Range(match.range(at: 1), in: line) {
                batch.bootStatusMessage = "Analyzing network connections (\(String(line[range])) profiles)..."
            }
        } else if RelayLogBytes.contains(lowerLine, "network size") {
            if let count = line.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces) {
                batch.bootStatusMessage = "Discovered \(count) network peers"
            }
        } else if RelayLogBytes.contains(lowerLine, "totals") && RelayLogBytes.contains(lowerLine, "pubkeys") {
            if let regex = pubkeysPattern,
               let match = regex.firstMatch(in: line, options: [], range: NSRange(line.startIndex..., in: line)),
               let range = Range(match.range(at: 1), in: line) {
                batch.bootStatusMessage = "Discovered \(String(line[range])) network peers"
            }
        } else if RelayLogBytes.contains(lowerLine, "relays discovered") {
            if let count = line.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces) {
                batch.bootStatusMessage = "Connecting to \(count) remote relays..."
            }
        } else if RelayLogBytes.contains(lowerLine, "pubkeys with minimum followers") || RelayLogBytes.contains(lowerLine, "eliminating pubkeys") {
            if let regex = trustGraphPattern,
               let match = regex.firstMatch(in: line, options: [], range: NSRange(line.startIndex..., in: line)),
               let range = Range(match.range(at: 1), in: line) {
                batch.bootStatusMessage = "Securing feed for \(String(line[range])) trusted users"
            }
        }

        // The inbox subscription itself ("📢 subscribing to inbox on N relays",
        // import.go), which starts only once the Web of Trust is ready. Not
        // the line before it ("waiting for Web of Trust before subscribing to
        // inbox"), which ended "Syncing" while the trust graph still built.
        if RelayLogBytes.contains(lowerLine, "subscribing to inbox on") {
            batch.stopWotSyncing = true
        }

        // Connection tracking
        if RelayLogBytes.contains(line, "accepted connection") || RelayLogBytes.contains(line, "new connection") || RelayLogBytes.contains(line, "WS connect") {
            batch.connectionsDelta += 1
        } else if RelayLogBytes.contains(line, "connection closed") || RelayLogBytes.contains(line, "WS disconnect") || RelayLogBytes.contains(line, "disconnected") {
            batch.connectionsDelta -= 1
        }

        // Error states
        if RelayLogBytes.contains(line, "Cannot acquire directory lock") || RelayLogBytes.contains(line, "Another process is using this Badger database") {
            batch.isLocked = true
        }
        if RelayLogBytes.contains(line, "bind: address already in use") {
            batch.isPortConflict = true
        }
        if RelayLogBytes.contains(line, "mdb_env_open") && RelayLogBytes.contains(line, "operation not permitted") {
            batch.isLocked = true
        }
    }
}
