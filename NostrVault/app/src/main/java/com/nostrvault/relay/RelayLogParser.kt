package com.nostrvault.relay

import java.util.Date
import java.util.UUID

/**
 * Relay log parsing and metrics extraction -- port of RelayLogParser.swift.
 * Pure string parsing with no Android framework dependencies.
 */
object RelayLogParser {

    data class LogEntry(
        val id: String = UUID.randomUUID().toString(),
        val timestamp: Date = Date(),
        val level: String,
        val message: String,
    ) {
        companion object {
            private val LOG_PREFIX_REGEX = Regex(
                """^\d{4}/\d{2}/\d{2}\s\d{2}:\d{2}:\d{2}\s(?:INFO|WARN|ERROR|DEBUG)\s""",
                RegexOption.IGNORE_CASE,
            )
            private val KV_REGEX = Regex("""(\w+)=(\S+)""")

            fun parse(line: String): LogEntry {
                var message = line

                val level = when {
                    line.contains("ERROR") -> "ERROR"
                    line.contains("WARN") -> "WARN"
                    else -> "INFO"
                }

                // Strip timestamp + level prefix
                message = LOG_PREFIX_REGEX.replace(message, "")

                // Strip standalone level prefixes
                message = when {
                    message.startsWith("INFO ") -> message.removePrefix("INFO ")
                    message.startsWith("WARN ") -> message.removePrefix("WARN ")
                    message.startsWith("ERROR ") -> message.removePrefix("ERROR ")
                    else -> message
                }

                // Prettify badger logs
                if (message.startsWith("badger ")) {
                    message = message.replace("badger ", "\uD83D\uDCBE ") // floppy disk emoji
                }

                // Convert key=value to key: value
                message = KV_REGEX.replace(message, "$1: $2")

                return LogEntry(
                    level = level,
                    message = message.trim(),
                )
            }
        }
    }

    /**
     * Accumulated state changes from background log parsing.
     * Applied in a single main-thread dispatch by the caller.
     */
    data class BatchedStateUpdate(
        var importProgress: Double? = null,
        var importStatusMessage: String? = null,
        var importCompleted: Boolean = false,
        var stopImporting: Boolean = false,
        var bootStatusMessage: String? = null,
        var stopBooting: Boolean = false,
        var stopWotSyncing: Boolean = false,
        var eventsStoredDelta: Int = 0,
        // Inbound events from OTHERS that tag you (replies, reactions, zaps,
        // reposts, DMs / gift-wraps). Drives the "new relay activity" red dot --
        // deliberately excludes your own posts/blasts and private/outbox writes.
        var inboxActivityDelta: Int = 0,
        var connectionsDelta: Int = 0,
        var isLocked: Boolean = false,
        var isPortConflict: Boolean = false,
        var progressDateStr: String? = null,
        var progressBump: Boolean = false,
    )

    private val ANALYSED_REGEX = Regex("""(?:analysed|count=)(\d+)""", RegexOption.IGNORE_CASE)
    private val TRUST_GRAPH_REGEX = Regex("""(?:kept=|followers: )(\d+)""", RegexOption.IGNORE_CASE)
    private val PUBKEYS_REGEX = Regex("""pubkeys=(\d+)""", RegexOption.IGNORE_CASE)

    /**
     * Extract state changes from a single log line.
     * Pure string parsing -- no UI dependencies.
     */
    fun collectStateChanges(line: String, batch: BatchedStateUpdate) {
        // ---- Import state ----
        when {
            line.contains("connected successfully") -> {
                batch.importProgress = 0.1
                batch.importStatusMessage = "Connected to relays..."
            }
            line.contains("Imported") && line.contains("notes") && !line.contains("complete") -> {
                line.substringAfterLast("to ", "").take(10).let { dateStr ->
                    if (dateStr.isNotEmpty()) batch.progressDateStr = dateStr
                }
                val from = line.substringAfter("from ", "").substringBefore(" to", "")
                batch.importStatusMessage = if (from.isNotEmpty()) {
                    "Found notes from $from..."
                } else {
                    "Found notes..."
                }
            }
            line.contains("Initializing WoT") || line.contains("building WoT") || line.contains("fetching Nostr events") -> {
                batch.importStatusMessage = "Building Web of Trust..."
                batch.importProgress = 0.2
            }
            line.contains("analysing Nostr events") -> {
                batch.importStatusMessage = "Analysing Web of Trust..."
                batch.importProgress = 0.3
            }
            line.contains("importing inbox notes") || line.contains("Importing inbox notes") -> {
                batch.importStatusMessage = "Importing tagged notes..."
                batch.importProgress = 0.85
            }
            line.contains("subscribing to inbox") || line.contains("tagged import complete") -> {
                batch.stopImporting = true
                batch.importCompleted = true
                batch.importProgress = 1.0
                batch.importStatusMessage = "Import Complete!"
            }
            line.contains("imported") && line.contains("tagged notes") -> {
                val count = line.split(" ").firstOrNull { it.toIntOrNull() != null }
                batch.importProgress = 0.95
                batch.importStatusMessage = if (count != null) {
                    "Imported $count tagged notes"
                } else {
                    "Tagged notes imported"
                }
            }
            line.contains("Import complete") || line.contains("import complete") -> {
                batch.importProgress = 1.0
                batch.importStatusMessage = "Import Complete!"
                if (line.contains("tagged import complete")) {
                    batch.stopImporting = true
                    batch.importCompleted = true
                }
            }
            line.contains("No notes found") -> {
                // An empty 10-day window (import.go): still progress through
                // the history, so the bar and the import tour's "Looking
                // through <month>" line keep moving for someone with gaps (or
                // a key with no notes at all). Same as iOS.
                val dateStr = line.substringAfterLast("to ", "").take(10)
                if (dateStr.isNotEmpty()) {
                    batch.progressDateStr = dateStr
                    val fromIndex = line.substringAfterLast("for ", "").take(10)
                    if (fromIndex.isNotEmpty()) {
                        batch.importStatusMessage = "Looking through notes from $fromIndex..."
                    }
                } else {
                    batch.progressBump = true
                }
            }
        }

        // ---- Event counts ----
        when {
            line.contains("Imported") && line.contains("notes") && !line.contains("complete") -> {
                val parts = line.split(" ")
                val idx = parts.indexOf("Imported")
                if (idx >= 0 && idx + 1 < parts.size) {
                    parts[idx + 1].toIntOrNull()?.let { batch.eventsStoredDelta += it }
                }
            }
            line.contains("imported") && line.contains("tagged notes") -> {
                val parts = line.split(" ")
                val idx = parts.indexOf("imported")
                if (idx >= 0 && idx + 1 < parts.size) {
                    parts[idx + 1].toIntOrNull()?.let { batch.eventsStoredDelta += it }
                }
            }
            line.contains("event stored") ||
            line.contains("new note") ||
            line.contains("new repost") ||
            line.contains("new reaction") ||
            line.contains("new zap") ||
            line.contains("new encrypted message") ||
            line.contains("new event kind") ||
            line.contains("blasted event") -> {
                batch.eventsStoredDelta += 1
            }
        }

        // Activity from OTHERS only -- the inbox/chat import handler logs these
        // exclusively for events authored by other people that tag you. Your own
        // posts ("event stored"/"blasted event") never hit this path, so this is
        // the precise signal for the "new relay activity" red dot.
        if (line.contains("in your inbox") || line.contains("in your chat relay")) {
            batch.inboxActivityDelta += 1
        }

        // ---- Booting status ----
        val lower = line.lowercase()
        when {
            lower.contains("subscribing to") -> {
                val topic = line.substringAfterLast("to ", "").trimEnd('.', ',', '!')
                if (topic.isNotEmpty()) {
                    batch.bootStatusMessage = "Subscribing to $topic..."
                }
            }
            lower.contains("is booting up") -> {
                batch.bootStatusMessage = "Booting Haven..."
            }
            lower.contains("starting deeper web of trust") -> {
                batch.bootStatusMessage = "Analyzing trust graph..."
            }
            lower.contains("starting") -> {
                val service = (line.substringAfterLast("starting ", "")
                    .ifEmpty { line.substringAfterLast("Starting ", "") })
                    .substringBefore("\"")
                    .trim()
                    .trimEnd('.', ',', '!')
                if (service.isNotEmpty()) {
                    batch.bootStatusMessage = "Starting $service..."
                }
            }
            lower.contains("listening at") || lower.contains("listening on") -> {
                batch.bootStatusMessage = "Initializing network listeners..."
                batch.stopBooting = true
            }
            lower.contains("building web of trust graph") || lower.contains("initializing wot") -> {
                batch.bootStatusMessage = "Building trust network..."
            }
            lower.contains("analysed") || lower.contains("analysing nostr events") -> {
                ANALYSED_REGEX.find(line)?.groupValues?.getOrNull(1)?.let { count ->
                    batch.bootStatusMessage = "Analyzing network connections ($count profiles)..."
                }
            }
            lower.contains("network size") -> {
                val count = line.substringAfterLast(":").trim()
                if (count.isNotEmpty()) {
                    batch.bootStatusMessage = "Discovered $count network peers"
                }
            }
            lower.contains("totals") && lower.contains("pubkeys") -> {
                PUBKEYS_REGEX.find(line)?.groupValues?.getOrNull(1)?.let { count ->
                    batch.bootStatusMessage = "Discovered $count network peers"
                }
            }
            lower.contains("relays discovered") -> {
                val count = line.substringAfterLast(":").trim()
                if (count.isNotEmpty()) {
                    batch.bootStatusMessage = "Connecting to $count remote relays..."
                }
            }
            lower.contains("pubkeys with minimum followers") || lower.contains("eliminating pubkeys") -> {
                TRUST_GRAPH_REGEX.find(line)?.groupValues?.getOrNull(1)?.let { count ->
                    batch.bootStatusMessage = "Securing feed for $count trusted users"
                }
            }
        }

        if (line.contains("subscribing to inbox") || line.contains("Subscribing to inbox")) {
            batch.stopWotSyncing = true
        }

        // ---- Connection tracking ----
        when {
            line.contains("accepted connection") ||
            line.contains("new connection") ||
            line.contains("WS connect") -> {
                batch.connectionsDelta += 1
            }
            line.contains("connection closed") ||
            line.contains("WS disconnect") ||
            line.contains("disconnected") -> {
                batch.connectionsDelta -= 1
            }
        }

        // ---- Error states ----
        if (line.contains("Cannot acquire directory lock") ||
            line.contains("Another process is using this Badger database")) {
            batch.isLocked = true
        }
        if (line.contains("bind: address already in use")) {
            batch.isPortConflict = true
        }
        if (line.contains("mdb_env_open") && line.contains("operation not permitted")) {
            batch.isLocked = true
        }
    }
}
