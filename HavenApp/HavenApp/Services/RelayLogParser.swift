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
        private static let kvPattern = try? NSRegularExpression(
            pattern: "(\\w+)=([^\\s]+)",
            options: []
        )

        static func parse(_ line: String) -> LogEntry {
            var message = line

            let level = line.contains("ERROR") ? "ERROR" :
                        line.contains("WARN") ? "WARN" : "INFO"

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
        var importCompleted: Bool = false
        var stopImporting: Bool = false
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
        if line.contains("new reaction in your inbox") { return 7 }
        if line.contains("new note in your inbox") { return 1 }
        if line.contains("new zap in your inbox") { return 9735 }
        if line.contains("new encrypted message in your inbox") { return 4 }
        if line.contains("new gift-wrapped message in your chat relay") { return 1059 }
        if line.contains("new repost in your inbox") { return 6 }
        if line.contains("event in your inbox"), let r = line.range(of: "new event kind ") {
            return Int(line[r.upperBound...].prefix { $0.isNumber })
        }
        return nil
    }

    /// Extract state changes from a single log line.
    /// Pure string parsing — no MainActor, no UI dependencies.
    static func collectStateChanges(from line: String, into batch: inout BatchedStateUpdate) {
        // Import state
        if line.contains("connected successfully") {
            batch.importProgress = 0.1
            batch.importStatusMessage = "Connected to relays..."
        } else if line.contains("No notes found for") {
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
        } else if line.contains("Imported") && line.contains("notes") {
            if let dateStr = line.components(separatedBy: "to ").last?.prefix(10) {
                batch.progressDateStr = String(dateStr)
            }
            if let rangeStart = line.range(of: "from ")?.upperBound,
               let rangeEnd = line.range(of: " to", range: rangeStart..<line.endIndex)?.lowerBound {
                batch.importStatusMessage = "Found notes from \(line[rangeStart..<rangeEnd])..."
            } else {
                batch.importStatusMessage = "Found notes..."
            }
        } else if line.contains("Initializing WoT") || line.contains("building WoT") || line.contains("fetching Nostr events") {
            batch.importStatusMessage = "Building Web of Trust..."
            batch.importProgress = 0.2
        } else if line.contains("analysing Nostr events") {
            batch.importStatusMessage = "Analysing Web of Trust..."
            batch.importProgress = 0.3
        } else if line.contains("importing inbox notes") || line.contains("Importing inbox notes") {
            batch.importStatusMessage = "Importing tagged notes..."
            batch.importProgress = 0.85
        } else if line.contains("subscribing to inbox") || line.contains("tagged import complete") {
            batch.stopImporting = true
            batch.importCompleted = true
            batch.importProgress = 1.0
            batch.importStatusMessage = "Import Complete!"
        } else if line.contains("imported") && line.contains("tagged notes") {
            if let countMatch = line.components(separatedBy: " ").first(where: { Int($0) != nil }) {
                batch.importProgress = 0.95
                batch.importStatusMessage = "Imported \(countMatch) tagged notes"
            } else {
                batch.importProgress = 0.95
                batch.importStatusMessage = "Tagged notes imported"
            }
        } else if line.contains("Import complete") || line.contains("import complete") {
            batch.importProgress = 1.0
            batch.importStatusMessage = "Import Complete!"
            if line.contains("tagged import complete") {
                batch.stopImporting = true
                batch.importCompleted = true
            }
        } else if line.contains("No notes found") {
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
        if line.contains("Imported") && line.contains("notes") && !line.contains("complete") {
            let components = line.components(separatedBy: " ")
            if let importedIndex = components.firstIndex(of: "Imported"),
               importedIndex + 1 < components.count,
               let count = Int(components[importedIndex + 1]) {
                batch.eventsStoredDelta += count
            }
        } else if line.contains("imported") && line.contains("tagged notes") {
            let components = line.components(separatedBy: " ")
            if let importedIndex = components.firstIndex(of: "imported"),
               importedIndex + 1 < components.count,
               let count = Int(components[importedIndex + 1]) {
                batch.eventsStoredDelta += count
            }
        } else if line.contains("event stored") {
            batch.eventsStoredDelta += 1
        } else if line.contains("new note") ||
                  line.contains("new repost") ||
                  line.contains("new reaction") ||
                  line.contains("new zap") ||
                  line.contains("new encrypted message") ||
                  line.contains("new event kind") ||
                  line.contains("blasted event") {
            batch.eventsStoredDelta += 1
        }

        // Activity from OTHERS only — the inbox/chat import handler logs these
        // exclusively for events authored by other people that tag you. Your own
        // posts ("event stored"/"blasted event") never hit this path, so this is
        // the precise signal for the "new relay activity" red dot.
        if let kind = inboxActivityKind(in: line) {
            batch.inboxActivityKinds.insert(kind)
        }

        // Local notification markers — collect for LocalNotificationService.
        let notifyPrefix = "🔔NOTIFY|"
        if let r = line.range(of: notifyPrefix) {
            batch.notifyMarkers.append(String(line[r.upperBound...]))
        }

        // Booting status
        let lowerLine = line.lowercased()
        if lowerLine.contains("subscribing to") {
            if let topic = line.components(separatedBy: "to ").last {
                batch.bootStatusMessage = "Subscribing to \(topic.trimmingCharacters(in: .punctuationCharacters))..."
            }
        } else if lowerLine.contains("is booting up") {
            batch.bootStatusMessage = "Booting Haven..."
        } else if lowerLine.contains("starting deeper web of trust") {
            batch.bootStatusMessage = "Analyzing trust graph..."
        } else if lowerLine.contains("starting") {
            if let service = line.components(separatedBy: "starting ").last ?? line.components(separatedBy: "Starting ").last {
                let cleanService = service.components(separatedBy: "\"").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? service
                batch.bootStatusMessage = "Starting \(cleanService.trimmingCharacters(in: .punctuationCharacters))..."
            }
        } else if lowerLine.contains("listening at") || lowerLine.contains("listening on") {
            batch.bootStatusMessage = "Initializing network listeners..."
            batch.stopBooting = true
        } else if lowerLine.contains("building web of trust graph") || lowerLine.contains("initializing wot") {
            batch.bootStatusMessage = "Building trust network..."
        } else if lowerLine.contains("analysed") || lowerLine.contains("analysing nostr events") {
            if let regex = analysedPattern,
               let match = regex.firstMatch(in: line, options: [], range: NSRange(line.startIndex..., in: line)),
               let range = Range(match.range(at: 1), in: line) {
                batch.bootStatusMessage = "Analyzing network connections (\(String(line[range])) profiles)..."
            }
        } else if lowerLine.contains("network size") {
            if let count = line.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces) {
                batch.bootStatusMessage = "Discovered \(count) network peers"
            }
        } else if lowerLine.contains("totals") && lowerLine.contains("pubkeys") {
            if let regex = pubkeysPattern,
               let match = regex.firstMatch(in: line, options: [], range: NSRange(line.startIndex..., in: line)),
               let range = Range(match.range(at: 1), in: line) {
                batch.bootStatusMessage = "Discovered \(String(line[range])) network peers"
            }
        } else if lowerLine.contains("relays discovered") {
            if let count = line.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces) {
                batch.bootStatusMessage = "Connecting to \(count) remote relays..."
            }
        } else if lowerLine.contains("pubkeys with minimum followers") || lowerLine.contains("eliminating pubkeys") {
            if let regex = trustGraphPattern,
               let match = regex.firstMatch(in: line, options: [], range: NSRange(line.startIndex..., in: line)),
               let range = Range(match.range(at: 1), in: line) {
                batch.bootStatusMessage = "Securing feed for \(String(line[range])) trusted users"
            }
        }

        if line.contains("subscribing to inbox") || line.contains("Subscribing to inbox") {
            batch.stopWotSyncing = true
        }

        // Connection tracking
        if line.contains("accepted connection") || line.contains("new connection") || line.contains("WS connect") {
            batch.connectionsDelta += 1
        } else if line.contains("connection closed") || line.contains("WS disconnect") || line.contains("disconnected") {
            batch.connectionsDelta -= 1
        }

        // Error states
        if line.contains("Cannot acquire directory lock") || line.contains("Another process is using this Badger database") {
            batch.isLocked = true
        }
        if line.contains("bind: address already in use") {
            batch.isPortConflict = true
        }
        if line.contains("mdb_env_open") && line.contains("operation not permitted") {
            batch.isLocked = true
        }
    }
}
