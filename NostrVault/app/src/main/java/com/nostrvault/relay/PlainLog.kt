package com.nostrvault.relay

import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Plain-language view of the relay log for the dashboard console -- port of
 * PlainLog.swift, same rules and API.
 *
 * The raw log (Settings > Logs) is for debugging. This turns each raw line
 * into a short sentence or drops it as noise, folds repeats together, and
 * builds copy/export text that carries no keys, event ids, IP addresses or paths.
 */
object PlainLog {

    enum class Severity(val label: String) {
        /** Normal operation worth seeing: relay up, new activity, import done. */
        GOOD("OK"),
        /** Recoverable: a remote relay unreachable or refusing a post. */
        HEADS_UP("Heads-up"),
        /** Needs the user: relay can't start, database locked, port taken. */
        PROBLEM("Problem"),
    }

    /** One translated line. [key] identifies "the same thing happening again". */
    data class Message(val key: String, val severity: Severity, val title: String, val hint: String?)

    /** A message and how often it happened in the window. */
    data class Item(
        val key: String,
        val severity: Severity,
        val title: String,
        val hint: String?,
        val count: Int,
        val firstSeen: Date,
        val lastSeen: Date,
    ) {
        val id: String get() = key
    }

    // ── Translation ──────────────────────────────────────────────────

    /** Translates one raw log line, or returns null when it is noise. */
    fun translate(level: String, message: String): Message? {
        val m = message
        val lower = m.lowercase()
        val lvl = level.uppercase()

        if (lvl == "DEBUG") return null
        if (isNoise(m, lower)) return null

        // Problems the user has to act on.
        if (lower.contains("cannot acquire directory lock") ||
            lower.contains("another process is using this badger database") ||
            (lower.contains("mdb_env_open") && lower.contains("operation not permitted"))
        ) {
            return Message("db-locked", Severity.PROBLEM,
                "The relay database is in use by another copy of the app",
                "Quit every copy of Nostr Vault, then open it again.")
        }
        if (lower.contains("address already in use")) {
            return Message("port-in-use", Severity.PROBLEM,
                "Another app is using the relay's port",
                "Quit the other app, or change the port in Settings > Advanced.")
        }
        if (lower.contains("relay stop exceeded")) {
            return Message("stop-slow", Severity.PROBLEM,
                "The relay is taking too long to stop",
                "If it doesn't finish, quit and reopen the app.")
        }
        if (lower.contains("boot watchdog triggered")) {
            return Message("boot-slow", Severity.PROBLEM,
                "The relay is taking too long to start",
                "Try Force Restart on the dashboard.")
        }
        if (lower.contains("cannot start relay") || lower.contains("cannot restart: no saved config")) {
            return Message("start-blocked", Severity.PROBLEM,
                "The relay couldn't start",
                "Stop it, wait a few seconds and start it again.")
        }
        if (lower.startsWith("blossom: upload to") && lower.contains("failed")) {
            return Message("blossom-local-upload", Severity.PROBLEM,
                "Couldn't save media to your relay",
                "Make sure the relay is running.")
        }
        if (lower.contains("error decoding configuration") || lower.contains("failed to save config") ||
            lower.contains("error reloading configuration")
        ) {
            return Message("config", Severity.PROBLEM,
                "Your settings couldn't be read or saved",
                "Open Settings and save again.")
        }

        // Remote relays: recoverable, grouped per relay host.
        val host = relayHost(m)
        if (host != null) {
            if (lower.contains("error connecting to relay")) {
                return Message("connect|$host", Severity.HEADS_UP,
                    "Couldn't reach $host",
                    "That relay may be down. Nothing to do unless it keeps happening.")
            }
            if (lower.contains("timeout publishing")) {
                return Message("slow|$host", Severity.HEADS_UP, "$host was too slow to accept a post", null)
            }
            if (lower.contains("error publishing")) {
                val membersOnly = listOf("restricted", "sign up", "paid", "whitelist", "not allowed", "auth-required")
                    .any { lower.contains(it) }
                if (membersOnly) {
                    return Message("members|$host", Severity.HEADS_UP,
                        "$host only accepts posts from its members",
                        "Remove it from your outbox relays if you don't pay for it.")
                }
                if (lower.contains("created_at")) {
                    return Message("old|$host", Severity.HEADS_UP,
                        "$host refused an older post",
                        "Normal while backing up old posts.")
                }
                return Message("publish|$host", Severity.HEADS_UP, "$host refused a post", null)
            }
        }
        if (lower.contains("dm wrap") && lower.contains("not stored")) {
            return Message("dm-not-stored", Severity.HEADS_UP,
                "A private message didn't reach one of the recipient's relays", null)
        }
        if (lower.contains("dm chat relay disconnected")) {
            return Message("dm-disconnected", Severity.HEADS_UP,
                "Lost the connection for private messages",
                "It reconnects on its own.")
        }

        // Normal operation.
        if (lower.contains("is booting up")) return Message("booting", Severity.GOOD, "Relay starting", null)
        if (lower.contains("listening at") || lower.contains("listening on")) {
            return Message("running", Severity.GOOD, "Relay is running", null)
        }
        if (lower.contains("relay settings changed; restarting")) {
            return Message("settings-restart", Severity.GOOD, "Restarting the relay to apply new settings", null)
        }
        if (lower.contains("subscribing to inbox on")) {
            val n = firstNumber("on ", m)
            return Message("inbox-watch", Severity.GOOD,
                if (n != null) "Watching $n relays for replies and messages" else "Watching for replies and messages",
                null)
        }
        if (lower.contains("import successful") || lower.contains("tagged import complete")) {
            return Message("import-done", Severity.GOOD, "Import finished", null)
        }
        if (lower.contains("in your inbox") || lower.contains("in your chat relay")) {
            return when {
                lower.contains("gift-wrapped") || lower.contains("encrypted message") ->
                    Message("new-dm", Severity.GOOD, "New private message", null)
                lower.contains("zap") -> Message("new-zap", Severity.GOOD, "New zap", null)
                lower.contains("reaction") -> Message("new-reaction", Severity.GOOD, "New reaction", null)
                lower.contains("repost") -> Message("new-repost", Severity.GOOD, "New repost of your post", null)
                else -> Message("new-mention", Severity.GOOD, "New reply or mention", null)
            }
        }

        // Unrecognised errors still surface, scrubbed and shortened, so a new
        // failure mode is never silently hidden. Unrecognised INFO/WARN lines
        // are background chatter and stay in the full log only.
        if (lvl == "ERROR") {
            val text = scrub(m).take(120)
            return Message("error|$text", Severity.PROBLEM,
                "Something went wrong: $text",
                "Copy the logs and send them to support if this keeps happening.")
        }
        return null
    }

    private val NOISE = listOf(
        "tls handshake error", "badger", "💾", "🔔notify|", "nostrservice:",
        "negentropy", "nip-77", "neg-open", "catch-up pull", "relay limits",
        "self-signed certificate", "starter pack", "invalid npub", "error writing ping",
        "event stored", "popular tally", "subscribing to engagement", "cloud backup disabled",
        "wrote .env", "working directory", "copied templates", "captured output natively",
        "database ready", "loading databases", "starting background services",
        "initializing web of trust", "waiting for web of trust",
    )

    /**
     * Lines that never mean anything to a user: TLS probes against the
     * self-signed endpoint, database housekeeping, the relay's settings dump,
     * notification plumbing, and sync fallbacks that recover on their own.
     */
    private fun isNoise(m: String, lower: String): Boolean {
        val trimmed = m.trim()
        if (trimmed.isEmpty() || trimmed == "{" || trimmed == "}" || trimmed.startsWith("\"")) return true
        return NOISE.any { lower.contains(it) }
    }

    // ── Grouping ─────────────────────────────────────────────────────

    /**
     * Folds translated lines into items, oldest first (the console scrolls to
     * the bottom). A repeat updates the existing item's count and lastSeen
     * and moves it to the end, so the newest activity is always last.
     */
    fun summarize(entries: List<RelayLogParser.LogEntry>): List<Item> {
        val items = LinkedHashMap<String, Item>()
        for (entry in entries) {
            val msg = translate(entry.level, entry.message) ?: continue
            val existing = items.remove(msg.key)
            items[msg.key] = existing?.copy(count = existing.count + 1, lastSeen = entry.timestamp)
                ?: Item(msg.key, msg.severity, msg.title, msg.hint, 1, entry.timestamp, entry.timestamp)
        }
        return items.values.toList()
    }

    /**
     * Worst severity seen since the relay last came up, for a status pill.
     * A problem from before the latest "Relay is running" no longer counts.
     */
    fun health(items: List<Item>): Severity {
        val lastUp = items.firstOrNull { it.key == "running" }?.lastSeen?.time ?: Long.MIN_VALUE
        return items.filter { it.lastSeen.time >= lastUp && it.key != "running" }
            .maxByOrNull { it.severity.ordinal }?.severity ?: Severity.GOOD
    }

    // ── Safe export ──────────────────────────────────────────────────

    /** Copy/export text. Built from the translated items only, never the raw lines, then scrubbed again. */
    fun exportText(items: List<Item>, header: List<String> = emptyList(), now: Date = Date()): String {
        val time = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US)
        val lines = mutableListOf("Nostr Vault relay report — ${time.format(now)}")
        lines += header
        lines += "Status: ${health(items).label}"
        lines += ""
        for (item in items) {
            var line = "[${time.format(item.lastSeen)}] ${item.severity.label}: ${item.title}"
            if (item.count > 1) line += " (×${item.count})"
            lines += line
            item.hint?.let { lines += "    $it" }
        }
        if (items.isEmpty()) lines += "Nothing to report."
        return scrub(lines.joinToString("\n"))
    }

    private val SCRUB_RULES: List<Pair<Regex, String>> = listOf(
        // Wallet connection strings carry a spending secret.
        """nostr\+walletconnect://\S+""" to "[wallet-connect]",
        """\b(nsec|ncryptsec)1[02-9ac-hj-np-z]+""" to "[secret-key]",
        """\b(npub|nprofile|note|nevent|naddr|nrelay)1[02-9ac-hj-np-z]{8,}""" to "[nostr-id]",
        """\b[0-9a-fA-F]{32,}\b""" to "[id]",
        """\b(?:\d{1,3}\.){3}\d{1,3}(?::\d+)?\b""" to "[ip]",
        """\[?[0-9a-fA-F]{1,4}(?::[0-9a-fA-F]{0,4}){3,7}]?(?::\d+)?""" to "[ip]",
        """[\w.+-]+@[\w-]+\.[\w.-]+""" to "[email]",
        """(?:/Users|/var/mobile|/private|/data/user|/storage|/home)/\S*""" to "[path]",
        // Private relay addresses (Tor, LAN, Tailscale) point at the user's own box.
        """\b(?:[\w-]+\.)+(?:onion|local|lan|internal|home\.arpa|ts\.net|localhost)\b|\blocalhost\b""" to "[private-relay]",
        // Keep a URL's scheme and host; drop path and query, where tokens live.
        """\b((?:wss?|https?)://[^/\s?#'"]+)[^\s'"]*""" to "$1",
    ).map { (pattern, template) -> Regex(pattern) to template }

    /**
     * Removes keys, nostr ids, hex ids, IPs, emails, file paths and URL
     * paths/queries. Relay host names stay: they are what makes a report useful.
     */
    fun scrub(text: String): String = SCRUB_RULES.fold(text) { acc, (regex, template) -> regex.replace(acc, template) }

    // ── Helpers ──────────────────────────────────────────────────────

    private val RELAY_REGEX = Regex("""relay[=:]\s*"?(wss?://[^\s"/]+)""")

    /** Host of the relay named in a `relay=wss://…` (or parsed `relay: wss://…`) field. */
    fun relayHost(message: String): String? {
        val url = RELAY_REGEX.find(message)?.groupValues?.get(1) ?: return null
        return runCatching { java.net.URI(url).host }.getOrNull()
    }

    private fun firstNumber(marker: String, text: String): Int? {
        val i = text.indexOf(marker).takeIf { it >= 0 } ?: return null
        return text.substring(i + marker.length).split(" ").firstOrNull()?.toIntOrNull()
    }
}
