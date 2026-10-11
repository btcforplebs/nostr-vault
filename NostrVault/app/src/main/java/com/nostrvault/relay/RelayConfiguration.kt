package com.nostrvault.relay

import java.io.File

/**
 * Relay environment configuration -- port of RelayConfiguration.swift.
 * Generates the environment dictionary consumed by the Go relay via
 * HavenBridge.setEnv() before calling startRelay().
 *
 * No Android framework dependencies beyond java.io.File.
 */
object RelayConfiguration {
    /** Where features read when the owner has no read relays. */
    val FALLBACK_RELAYS = listOf("wss://relay.primal.net", "wss://nos.lol")

    /** Where the owner's events go when there are no write relays: the default broadcast list. */
    val FALLBACK_WRITE_RELAYS = listOf("wss://relay.btcforplebs.com", "wss://relay.damus.io", "wss://relay.snort.social")


    /** Top-level subdirectories created under the relay data root. */
    val dataSubdirs = listOf("data", "blossom", "cache", "db")

    /** Individual database subdirectories under db/. */
    val dbSubdirs = listOf("private", "chat", "outbox", "inbox", "blossom")

    /** Create all required relay directories under the given root. */
    fun ensureDirectories(root: File) {
        root.mkdirs()
        for (sub in dataSubdirs) {
            File(root, sub).mkdirs()
        }
        for (db in dbSubdirs) {
            File(root, "db/$db").mkdirs()
        }
    }

    /**
     * Build the full environment dictionary from a HavenConfig.
     *
     * @param config The relay configuration
     * @param relayDataDir Absolute path to the relay data directory
     */
    fun generateEnvDictionary(
        config: HavenConfig,
        relayDataDir: File,
    ): Map<String, String> {
        val cleanNpub = config.ownerNpub
            .trim()
            .filter { it.isLetterOrDigit() }

        val relayBindAddress = "127.0.0.1"

        // Disable TLS for local relay -- localhost (127.0.0.1) is exempt from
        // Android's cleartext traffic restrictions, and the self-signed cert
        // generation can fail on some devices/Android versions, causing the
        // Go relay to fall back to HTTP while the client expects WSS.
        val enableTLS = "0"

        return mapOf(
            "OWNER_NPUB" to cleanNpub,
            // Bare host[:port] — the Go relay builds its ServiceURL as
            // "https://" + RELAY_URL + "/chat", so a scheme here produces a
            // malformed "https://ws://127.0.0.1:3355/chat" that never matches the
            // NIP-42 AUTH relay tag → "failed to authenticate" → no NIP-17 DMs.
            "RELAY_URL" to config.relayURL.substringAfter("://").trimEnd('/'),
            "RELAY_PORT" to config.relayPort.toString(),
            "RELAY_BIND_ADDRESS" to relayBindAddress,
            "DB_ENGINE" to config.dbEngine,
            "LMDB_MAPSIZE" to "0",
            "DATABASE_PATH" to "${File(relayDataDir, "data").absolutePath}/",
            "BLOSSOM_PATH" to "${File(relayDataDir, config.blossomPath).absolutePath}/",
            "HAVEN_LOG_LEVEL" to config.logLevel,
            "LOG_FORMAT" to "\$\$host \$\$remote_addr - \$\$remote_user [\$\$time_local] \"\$\$request\" \$\$status \$\$body_bytes_sent \"\$\$http_referer\" \"\$\$http_user_agent\" \"\$\$upstream_addr\"",
            "TZ" to "UTC",

            // Whitelisted Npubs
            "WHITELISTED_NPUBS_FILE" to config.whitelistedNpubsFile,

            // Blacklisted Npubs
            "BLACKLISTED_NPUBS_FILE" to config.blacklistedNpubsFile,

            // Private Relay
            "PRIVATE_RELAY_NAME" to config.privateRelayName,
            "PRIVATE_RELAY_NPUB" to config.ownerNpub,
            "PRIVATE_RELAY_DESCRIPTION" to config.privateRelayDescription,
            "PRIVATE_RELAY_ICON" to config.privateRelayIcon,
            "PRIVATE_RELAY_EVENT_IP_LIMITER_TOKENS_PER_INTERVAL" to "50",
            "PRIVATE_RELAY_EVENT_IP_LIMITER_INTERVAL" to "1",
            "PRIVATE_RELAY_EVENT_IP_LIMITER_MAX_TOKENS" to "100",
            "PRIVATE_RELAY_ALLOW_EMPTY_FILTERS" to "true",
            "PRIVATE_RELAY_ALLOW_COMPLEX_FILTERS" to "true",
            "PRIVATE_RELAY_CONNECTION_RATE_LIMITER_TOKENS_PER_INTERVAL" to "3",
            "PRIVATE_RELAY_CONNECTION_RATE_LIMITER_INTERVAL" to "5",
            "PRIVATE_RELAY_CONNECTION_RATE_LIMITER_MAX_TOKENS" to "9",

            // Chat Relay
            "CHAT_RELAY_NAME" to config.chatRelayName,
            "CHAT_RELAY_NPUB" to config.ownerNpub,
            "CHAT_RELAY_DESCRIPTION" to config.chatRelayDescription,
            "CHAT_RELAY_ICON" to config.chatRelayIcon,
            "CHAT_RELAY_WOT_DEPTH" to config.chatRelayWotDepth.toString(),
            "CHAT_RELAY_WOT_REFRESH_INTERVAL_HOURS" to config.chatRelayWotRefreshHours.toString(),
            "WOT_REFRESH_INTERVAL" to config.wotRefreshInterval,
            "WOT_DEPTH" to config.chatRelayWotDepth.toString(),
            "WOT_MINIMUM_FOLLOWERS" to config.chatRelayMinFollowers.toString(),
            "CHAT_RELAY_MINIMUM_FOLLOWERS" to config.chatRelayMinFollowers.toString(),
            "CHAT_RELAY_EVENT_IP_LIMITER_TOKENS_PER_INTERVAL" to "50",
            "CHAT_RELAY_EVENT_IP_LIMITER_INTERVAL" to "1",
            "CHAT_RELAY_EVENT_IP_LIMITER_MAX_TOKENS" to "100",
            "CHAT_RELAY_ALLOW_EMPTY_FILTERS" to "true",
            "CHAT_RELAY_ALLOW_COMPLEX_FILTERS" to "false",
            "CHAT_RELAY_CONNECTION_RATE_LIMITER_TOKENS_PER_INTERVAL" to "3",
            "CHAT_RELAY_CONNECTION_RATE_LIMITER_INTERVAL" to "3",
            "CHAT_RELAY_CONNECTION_RATE_LIMITER_MAX_TOKENS" to "9",

            // Outbox Relay
            "OUTBOX_RELAY_NAME" to config.outboxRelayName,
            "OUTBOX_RELAY_NPUB" to config.ownerNpub,
            "OUTBOX_RELAY_DESCRIPTION" to config.outboxRelayDescription,
            "OUTBOX_RELAY_ICON" to config.outboxRelayIcon,
            "OUTBOX_MAX_EVENTS_PER_MINUTE" to config.outboxMaxEventsPerMinute.toString(),
            "OUTBOX_MAX_CONNECTIONS_PER_MINUTE" to config.outboxMaxConnectionsPerMinute.toString(),
            "OUTBOX_RELAY_EVENT_IP_LIMITER_TOKENS_PER_INTERVAL" to "10",
            "OUTBOX_RELAY_EVENT_IP_LIMITER_INTERVAL" to "60",
            "OUTBOX_RELAY_EVENT_IP_LIMITER_MAX_TOKENS" to "100",
            "OUTBOX_RELAY_ALLOW_EMPTY_FILTERS" to "true",
            "OUTBOX_RELAY_ALLOW_COMPLEX_FILTERS" to "false",
            "OUTBOX_RELAY_CONNECTION_RATE_LIMITER_TOKENS_PER_INTERVAL" to "3",
            "OUTBOX_RELAY_CONNECTION_RATE_LIMITER_INTERVAL" to "1",
            "OUTBOX_RELAY_CONNECTION_RATE_LIMITER_MAX_TOKENS" to "9",

            // Inbox Relay
            "INBOX_RELAY_NAME" to config.inboxRelayName,
            "INBOX_RELAY_NPUB" to config.ownerNpub,
            "INBOX_RELAY_DESCRIPTION" to config.inboxRelayDescription,
            "INBOX_RELAY_ICON" to config.inboxRelayIcon,
            "INBOX_PULL_INTERVAL_SECONDS" to config.inboxPullIntervalSeconds.toString(),
            "INBOX_RELAY_EVENT_IP_LIMITER_TOKENS_PER_INTERVAL" to "10",
            "INBOX_RELAY_EVENT_IP_LIMITER_INTERVAL" to "1",
            "INBOX_RELAY_EVENT_IP_LIMITER_MAX_TOKENS" to "20",
            "INBOX_RELAY_ALLOW_EMPTY_FILTERS" to "true",
            "INBOX_RELAY_ALLOW_COMPLEX_FILTERS" to "false",
            "INBOX_RELAY_CONNECTION_RATE_LIMITER_TOKENS_PER_INTERVAL" to "3",
            "INBOX_RELAY_CONNECTION_RATE_LIMITER_INTERVAL" to "1",
            "INBOX_RELAY_CONNECTION_RATE_LIMITER_MAX_TOKENS" to "9",

            // Import
            "IMPORT_START_DATE" to config.importStartDate,
            "IMPORT_SEED_RELAYS_FILE" to config.importSeedRelaysFile,
            "IMPORT_QUERY_INTERVAL_SECONDS" to "600",
            "IMPORT_OWNER_NOTES_FETCH_TIMEOUT_SECONDS" to "300",
            "IMPORT_TAGGED_NOTES_FETCH_TIMEOUT_SECONDS" to "600",

            // DM Relays
            "DM_RELAYS_FILE" to DM_RELAYS_FILE_NAME,

            // Mac relay: synced like any other relay, plus a one-time
            // full-history copy whose result lands in mac_sync_status.json
            // (iOS passes the same; see MacSync).
            "MAC_RELAY_URL" to MacSync.macRelayURL(config),

            // Backup
            "BACKUP_PROVIDER" to config.backupProvider,
            "BACKUP_INTERVAL_HOURS" to config.backupIntervalHours.toString(),
            "S3_ACCESS_KEY_ID" to config.s3AccessKeyId,
            "S3_SECRET_KEY" to config.s3SecretKey,
            "S3_ENDPOINT" to config.s3Endpoint,
            "S3_REGION" to config.s3Region,
            "S3_BUCKET_NAME" to config.s3BucketName,

            // Blastr
            "BLASTR_RELAYS_FILE" to config.blastrRelaysFile,

            // WoT
            "WOT_FETCH_TIMEOUT_SECONDS" to "60",

            // Notifications: which kinds the relay may raise a marker for.
            // Its catch-up summary ("N more new items while you were away") is
            // one number, so nothing can filter it after the fact — the kinds
            // have to be decided before the relay starts.
            "NOTIFY_KINDS" to notifyKinds(config).joinToString(","),

            // TLS
            "HAVEN_ENABLE_TLS" to enableTLS,
        )
    }

    /**
     * Kind 0 (profile metadata) never raises a notification, so a list holding
     * only it is how "notify for nothing" is said to the relay: an EMPTY
     * NOTIFY_KINDS means "no preference, notify for everything"
     * (haven-go/config.go getKindSet). Same as iOS NotificationPolicy.silentKind.
     */
    const val SILENT_NOTIFY_KIND = 0

    /**
     * Event kinds the relay should raise notifications for, given what the user
     * has switched on — the union across every account on the device, since the
     * relay is shared and the client still applies each account's own
     * preferences to the individual markers. Port of iOS
     * RelayConfiguration.notifyKinds + NotificationPolicy.notifyKinds.
     */
    fun notifyKinds(config: HavenConfig): List<Int> {
        // An account with no stored entry runs on PushPrefs()'s defaults
        // everywhere else, so it has to count here too — a user who never
        // opened the notification settings has no entries at all, and leaving
        // them out would report "notify for nothing".
        val prefs = config.allAccountNpubs().map { config.pushPrefsFor(it) }
            .ifEmpty { listOf(config.pushPrefsFor(config.ownerNpub)) }

        // With phone notifications off, DMs are still marked: the in-app banner
        // shows them while the app is open, and that banner is part of the app,
        // not a phone notification.
        if (!config.enablePushNotifications) {
            return notifyKinds(mentionsOrReplies = false, dms = prefs.any { it.dms })
        }
        return notifyKinds(
            mentionsOrReplies = prefs.any { it.mentions || it.replies },
            dms = prefs.any { it.dms },
            zaps = prefs.any { it.zaps },
            reactions = !config.zapsOnlyMode && prefs.any { it.reactions },
            reposts = prefs.any { it.reposts },
        )
    }

    /** The kind set for one combination of switches; see [notifyKinds]. */
    fun notifyKinds(
        mentionsOrReplies: Boolean,
        dms: Boolean,
        zaps: Boolean = false,
        reactions: Boolean = false,
        reposts: Boolean = false,
    ): List<Int> {
        val kinds = mutableListOf<Int>()
        // A mention and a reply are both kind 1, and a reply may also be a
        // NIP-22 comment (kind 1111), so either switch enables both.
        if (mentionsOrReplies) kinds += listOf(1, 1111)
        if (dms) kinds += listOf(4, 1059)
        // Kind 16 is the generic repost: an article, a picture, anything but a
        // plain text note.
        if (reposts) kinds += listOf(6, 16)
        if (reactions) kinds += 7
        if (zaps) kinds += 9735
        return if (kinds.isEmpty()) listOf(SILENT_NOTIFY_KIND) else kinds.sorted()
    }

    /**
     * Everything the relay reads when it starts: its environment plus the
     * list files written beside it. Two configs with equal inputs run an
     * identical relay, so this is what decides whether a saved settings
     * change needs a restart (see [RelayConfigApplier]). The service writes
     * the list files from this same struct, so the restart check cannot drift
     * from what the relay actually reads. Port of iOS
     * RelayConfiguration.LaunchInputs.
     */
    data class LaunchInputs(
        val env: Map<String, String>,
        val importSeedRelays: List<String>,
        val blastrRelays: List<String>,
        val dmRelays: List<String>,
    )

    /** Name of the DM relay list file the relay reads (DM_RELAYS_FILE). */
    const val DM_RELAYS_FILE_NAME = "relays_dm.json"

    /** The blocked-people file when config names none (iOS's default name). */
    const val BLACKLIST_FILE_NAME = "blacklisted_npubs.json"

    fun launchInputs(config: HavenConfig, relayDataDir: File): LaunchInputs = LaunchInputs(
        env = generateEnvDictionary(config, relayDataDir),
        importSeedRelays = config.importSeedRelays,
        blastrRelays = config.blastrRelays,
        dmRelays = config.dmRelays,
    )

    /**
     * Writes the relay lists the Go relay reads from files and points their
     * env vars at them by absolute path: Go opens the bare filename, but the
     * app's working directory is not the relay data dir. Rewritten every
     * time, because config is the source of truth. Call after the env from
     * [launchInputs] is set, since that sets these vars to bare names.
     */
    fun writeRelayListFiles(config: HavenConfig, inputs: LaunchInputs, relayDataDir: File) {
        fun write(envKey: String, fileName: String, content: List<String>) {
            if (fileName.isEmpty()) return
            val file = File(relayDataDir, fileName)
            file.writeText(npubListJson(content))
            HavenBridge.setEnv(envKey, file.absolutePath)
        }
        write("IMPORT_SEED_RELAYS_FILE", config.importSeedRelaysFile, inputs.importSeedRelays)
        write("BLASTR_RELAYS_FILE", config.blastrRelaysFile, inputs.blastrRelays)
        write("DM_RELAYS_FILE", DM_RELAYS_FILE_NAME, inputs.dmRelays)
        // Read once at start; blocks made while it runs reach it through
        // HavenBridge.updateBlacklist. Not a launch input: a block must not
        // restart the relay.
        write("BLACKLISTED_NPUBS_FILE", config.blacklistedNpubsFile.ifEmpty { BLACKLIST_FILE_NAME }, config.allBlockedNpubsAcrossAccounts())
    }

    /** A JSON array of plain strings (npubs, relay URLs), as the relay reads it. */
    fun npubListJson(items: List<String>): String =
        "[" + items.joinToString(",") { "\"$it\"" } + "]"

    /** Format an environment dictionary as a .env file string. */
    fun formatEnvFile(envDict: Map<String, String>): String = buildString {
        for ((key, value) in envDict.toSortedMap()) {
            when {
                value.contains(" ") || value.contains("\"") -> {
                    val escaped = value.replace("\"", "\\\"")
                    appendLine("$key=\"$escaped\"")
                }
                value.isEmpty() -> appendLine("$key=\"\"")
                else -> appendLine("$key=$value")
            }
        }
    }

    /**
     * The NIP-65 relay list for a new account whose relay is this device.
     * The device's own relay can't be reached from outside, so it is not
     * advertised; the public relays every event is broadcast to are. No
     * marker, so each is both read and write. Loopback and non-wss entries
     * are left out. Same as iOS.
     */
    fun newAccountRelayListTags(broadcastRelays: List<String>): List<List<String>> {
        val loopback = setOf("localhost", "127.0.0.1", "0.0.0.0", "::1", "[::1]")
        return broadcastRelays.map { it.trim() }
            .filter { url ->
                val uri = runCatching { java.net.URI(url) }.getOrNull() ?: return@filter false
                uri.scheme == "wss" && !uri.host.isNullOrEmpty() && uri.host.lowercase() !in loopback
            }
            .distinct()
            .map { listOf("r", it) }
    }

    /**
     * Where a brand-new account's photos go when it has no server of its
     * own: blossomMirrors is empty on a fresh install, and with no outside
     * server a photo (the profile picture included) can't be shown to anyone
     * else. Both accepted an upload signed by a never-seen key (2026-10-07).
     * nostr.build first at Logen's request. Only setup's New to Nostr path
     * applies this. Same as iOS.
     */
    val newAccountBlossomMirrors = listOf("https://blossom.nostr.build", "https://blossom.primal.net")
}
