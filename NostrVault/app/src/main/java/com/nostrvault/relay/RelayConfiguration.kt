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

            // TLS
            "HAVEN_ENABLE_TLS" to enableTLS,

            // Loopback port the FIPS mesh forwards to: blob reads only.
            "HAVEN_MESH_PLAIN_PORT" to config.meshPort.toString(),
        )
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
            file.writeText("[" + content.joinToString(",") { "\"$it\"" } + "]")
            HavenBridge.setEnv(envKey, file.absolutePath)
        }
        write("IMPORT_SEED_RELAYS_FILE", config.importSeedRelaysFile, inputs.importSeedRelays)
        write("BLASTR_RELAYS_FILE", config.blastrRelaysFile, inputs.blastrRelays)
        write("DM_RELAYS_FILE", DM_RELAYS_FILE_NAME, inputs.dmRelays)
    }

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

/**
 * Relay configuration data class -- Kotlin equivalent of the Swift HavenConfig struct.
 * Contains all fields needed by RelayConfiguration, services, and UI.
 */
@kotlinx.serialization.Serializable
data class HavenConfig(
    val ownerNpub: String = "",
    val relayURL: String = "ws://127.0.0.1:3355",
    val relayPort: Int = 3355,
    val dbEngine: String = "badger",
    val blossomPath: String = "blossom",
    val logLevel: String = "info",
    // Setup
    val hasCompletedSetup: Boolean = false,
    val setupMode: String = "full", // "full", "browse", or "newuser"
    val defaultFeedMode: String = "FOLLOWING", // "FOLLOWING", "POPULAR", etc.
    val hasCompletedInitialImport: Boolean = false, // Browse mode: tracks if first background import has run

    // Account management
    val activeAccountNpub: String? = null,
    val ownerHexKey: String? = null,
    val ownerNcryptsec: String? = null,
    val signingMode: String = "local", // "local", "nip46", "amber"
    val amberSignerPackage: String = "com.greenart7c3.nostrsigner",

    // Multi-account (mirrors iOS HavenConfig per-account dictionaries).
    // accountNpubs is the roster of non-owner accounts; the owner is synthesized
    // by allAccountNpubs(). All maps are keyed by account npub. Default-empty for
    // backward compatibility with single-owner configs.
    val accountNpubs: List<String> = emptyList(),
    val accountBunkerConfigs: Map<String, AccountBunkerConfig> = emptyMap(),
    val accountSigningModes: Map<String, String> = emptyMap(),
    val publishRelayListPerAccount: Map<String, Boolean> = emptyMap(),

    // Whitelisted / Blacklisted
    val whitelistedNpubsFile: String = "",
    val blacklistedNpubsFile: String = "",
    val whitelistedNpubs: List<String>? = null,
    val blockedNpubs: List<String>? = null,
    // Per-account block list (mirrors iOS blockedNpubsPerAccount, keyed by
    // account npub), published as a NIP-51 kind-10000 mute list.
    // Default-empty for backward compatibility with old configs.
    val blockedNpubsPerAccount: Map<String, List<String>> = emptyMap(),

    // Private Relay
    val privateRelayName: String = "Nostr Vault Private",
    val privateRelayDescription: String = "Private relay",
    val privateRelayIcon: String = "",

    // Chat Relay
    val chatRelayName: String = "Nostr Vault Chat",
    val chatRelayDescription: String = "Chat relay",
    val chatRelayIcon: String = "",
    // 3 = follows plus who they follow, matching iOS. At 2 the trust graph is
    // exactly your follows, so Global (Web of Trust) equals Following and
    // Discovery (trusted but not followed) is always empty.
    val chatRelayWotDepth: Int = 3,
    val chatRelayWotRefreshHours: Int = 24,
    val chatRelayMinFollowers: Int = 3,
    val wotRefreshInterval: String = "24h",

    // Outbox Relay
    val outboxRelayName: String = "Nostr Vault Outbox",
    val outboxRelayDescription: String = "Outbox relay",
    val outboxRelayIcon: String = "",
    val outboxMaxEventsPerMinute: Int = 100,
    val outboxMaxConnectionsPerMinute: Int = 30,

    // Inbox Relay
    val inboxRelayName: String = "Nostr Vault Inbox",
    val inboxRelayDescription: String = "Inbox relay",
    val inboxRelayIcon: String = "",
    val inboxPullIntervalSeconds: Int = 900, // match iOS; sub-5-min rounds treadmill the sync loop (Go clamps ≥300)

    // Import
    val importStartDate: String = "2023-01-01",
    val importSeedRelaysFile: String = "relays_import.json",
    // Same as iOS HavenConfig.importSeedRelays: relay.damus.io replaced
    // nos.lol and nostr.mom (2026-10-07).
    val importSeedRelays: List<String> = listOf(
        "wss://relay.primal.net",
        "wss://relay.damus.io",
        "wss://relay.btcforplebs.com",
        "wss://nostr-pub.wellorder.net",
    ),

    // Backup
    val backupProvider: String = "",
    val backupIntervalHours: Int = 24,
    val s3AccessKeyId: String = "",
    val s3SecretKey: String = "",
    val s3Endpoint: String = "",
    val s3Region: String = "",
    val s3BucketName: String = "",

    // Blastr
    val blastrRelaysFile: String = "relays_blastr.json",
    // Default broadcast relays, same as iOS HavenConfig.blastrRelays.
    val blastrRelays: List<String> = listOf(
        "wss://relay.btcforplebs.com",
        "wss://relay.damus.io",
        "wss://relay.snort.social",
    ),

    // DM Relays — the Go relay merges these with importSeedRelays for the
    // inbox tagged-event (#p = owner) subscription. Was hardcoded empty on
    // Android, so tagged notes on relays not in importSeedRelays (e.g.
    // nos.lol) never reached the inbox. Mirrors iOS HavenConfig.dmRelays.
    val dmRelays: List<String> = listOf(
        "wss://relay.primal.net",
        "wss://nos.lol",
        "wss://relay.btcforplebs.com",
    ),
    /**
     * When [dmRelays] last changed, in Unix seconds: the created_at of a
     * published kind 10050 this device adopted, or the time this device
     * published its own. null = never set, which any published list beats.
     */
    val dmRelaysUpdatedAt: Long? = null,
    /** Never connect: published as the blocked relay list (NIP-51 kind 10006). See [RelayBlocklist]. */
    val blockedRelays: List<String> = emptyList(),

    // Relay URLs
    val inboxRelays: List<String>? = listOf(
        "wss://relay.primal.net",
        "wss://nos.lol",
        "wss://nostr.mom",
        "wss://relay.btcforplebs.com",
        "wss://nostr-pub.wellorder.net",
    ),
    val feedRelays: List<String>? = listOf(
        "wss://relay.primal.net",
        "wss://nos.lol",
        "wss://nostr.mom",
        "wss://relay.btcforplebs.com",
        "wss://nostr-pub.wellorder.net",
    ),

    // Haven Relay (wss:// URL to a remote Haven relay to sync missed notes)
    val macRelayURL: String = "",

    // FIPS mesh. The preference only; the identity itself is a private key and
    // lives in CredentialStore, not in this file, which is plaintext JSON.
    val fipsMeshEnabled: Boolean = false,

    // Offer this device's relay (and the Blossom server sharing its port) to
    // mesh peers. Separate from fipsMeshEnabled, and off by default: being
    // findable on the mesh and being reachable are different decisions.
    val fipsShareRelay: Boolean = false,

    // Npubs allowed to reach this device over the mesh. Nobody else can.
    val fipsPeers: List<String> = emptyList(),

    // What one sharing session may send to the mesh before sharing stops (NIP-F1).
    val fipsServeLimitBytes: Long = 1L shl 30,

    // Bytes this sharing session has sent the mesh, across engine restarts and
    // app launches. Reset when sharing is switched off or on.
    val fipsServedBytes: Long = 0,

    // Blossom
    val blossomMirrors: List<String> = emptyList(),
    /** Download own media from the Blossom mirrors when the Media tab opens (iOS autoMirrorMedia). */
    val autoMirrorMedia: Boolean = false,
    /**
     * Picking a nostr.build GIF downloads it and uploads it to your own Blossom
     * servers with the note, instead of posting nostr.build's link. iOS
     * saveGifsToBlossom; off by default.
     */
    val saveGifsToBlossom: Boolean = false,

    // Paths (set at runtime by app)
    val relayDataDir: String? = null,
    val appSupportDir: String? = null,

    // NIP-29 Groups (serialized as list of {relayURL, groupId, displayName})
    val joinedGroups: List<JoinedGroupConfig>? = null,

    // NWC (Nostr Wallet Connect)
    val nwcURI: String? = null,
    val defaultZapAmount: Int = 21, // sats


    // Bitcoin (BIP-341 taproot address derived from the Nostr keypair)
    val showBitcoinWallet: Boolean = false,

    // Appearance
    val themeColor: String = "orange",
    val textSizeScale: Float = 1.0f,
    /** OLED black is the only appearance now; the Appearance toggle is gone. */
    val oledMode: Boolean = true,
    val useFeedCompactMode: Boolean = true,
    val feedCompactModes: Map<String, Boolean> = emptyMap(),
    /**
     * FeedLayoutMode.storageKey per feed. Supersedes [feedCompactModes], which
     * is still read as the fallback so an upgrade keeps whatever compact
     * setting was in place. Mirrors iOS HavenConfig.feedLayoutModes.
     */
    val feedLayoutModes: Map<String, String> = emptyMap(),
    val noteDetailExpandedEngagement: Boolean = false,
    val defaultReactionEmoji: String = "+",
    // When true, likes/reactions are removed from the UI entirely; zaps become the
    // primary engagement + notification signal. Mirrors iOS HavenConfig.zapsOnlyMode.
    val zapsOnlyMode: Boolean = false,
    // When true, the bottom tab bar stays fully expanded and never shrinks/hides
    // on scroll. Mirrors iOS HavenConfig.disableTabBarAnimation.
    val disableTabBarAnimation: Boolean = false,
    /** Lines of note text a row shows in Compact View. Mirrors iOS HavenConfig.compactLineLimit. */
    val compactLineLimit: Int = 3,
    /** Lines a thread's root shows in Threaded View; replies show one fewer. Mirrors iOS. */
    val threadedLineLimit: Int = 3,
    val autoplayVideos: Boolean = true,
    /**
     * New posts join the feed on their own while you are at the top, instead
     * of waiting behind the "New Posts" pill. Off by default. Mirrors iOS
     * HavenConfig.autoLoadNewPosts.
     */
    val autoLoadNewPosts: Boolean = false,
    /** Reposts in the feed. Mirrors iOS HavenConfig.showReposts. */
    val showReposts: Boolean = true,
    /** Replies in the feed. Mirrors iOS HavenConfig.showReplies. */
    val showReplies: Boolean = true,
    /**
     * The floating "New Posts" pill over the feed. Off, waiting posts load on
     * pull-to-refresh (or by themselves at the top with Auto-Load). On by
     * default. Mirrors iOS HavenConfig.showNewPostsPill.
     */
    val showNewPostsPill: Boolean = true,
    /** ISO 639-1 codes the Global feed is narrowed to. Empty shows every language. Mirrors iOS. */
    val globalFeedLanguages: List<String> = emptyList(),
    /** Global (and Media's Global) shows everyone, not only your Web of Trust. Off by default. Mirrors iOS. */
    val globalShowsEveryone: Boolean = false,
    /** A "Translate" button under notes written in another language (on-device ML Kit). On by default. */
    val showTranslateButton: Boolean = true,
    /** ISO 639-1 code notes translate into. Empty follows the device language. */
    val translateTargetLanguage: String = "",

    // Performance
    val prefetchAvatars: Boolean = true,

    // Advanced / media (client-side; not sent to the Go relay)
    val disableMediaCache: Boolean = false,
    val cacheTTLDays: Int = 3, // 0 = never evict
    val autoStartRelay: Boolean = true,

    // External relay (Android only). Some users keep the client and their
    // relay/Blossom server in separate apps for sandboxing (e.g. Citrine on
    // the same phone), or run their own relay elsewhere (Nostr Vault for Mac
    // on a domain). When on, the embedded relay never starts and every
    // read, write and upload that targeted it goes to these URLs instead.
    val useExternalRelay: Boolean = false,
    val externalRelayURL: String = "",
    val externalBlossomURL: String = "",
    /**
     * Load Blossom media through a local Blossom cache app (Morganite on
     * 127.0.0.1:24242) when one is running. See LocalBlossomCache.
     */
    val useLocalBlossomCache: Boolean = true,

    // Notifications. These drive the on-device notifications the embedded
    // relay generates; there is no push server. The APNs forwarder that
    // pushServerURL used to point at was deleted in cd604a3 — it only ever
    // spoke APNs and had no clients left.
    val enablePushNotifications: Boolean = false,
    /** "New Notes in Your Feed": one summary per absence of 2h+ (iOS enableFeedNotifications). */
    val enableFeedNotifications: Boolean = false,
    /** The picked notification sound's name (iOS notificationSoundName); see NotificationSound. */
    val notificationSoundName: String = "Chime",
    val pushNotifyMentions: Boolean = true,
    val pushNotifyReplies: Boolean = true,
    val pushNotifyDMs: Boolean = true,
    val pushNotifyZaps: Boolean = true,
    val pushNotifyReactions: Boolean = false,
    val pushNotifyReposts: Boolean = false,
    // Per-account push preferences (mirrors iOS). Master enable + server URL
    // stay global above; each account keeps its own per-type toggles. Falls
    // back to the global flags for accounts without an entry (back-compat).
    val pushPrefsPerAccount: Map<String, PushPrefs> = emptyMap(),

    // Search
    val recentSearches: List<String> = emptyList(),
    /**
     * NIP-50 relays Global search queries. Null = never edited, use
     * [DEFAULT_SEARCH_RELAYS] (so a later change to the defaults reaches
     * everyone who has not customised the list); an empty list is a real
     * choice and is kept. Per device, like the rest of config.json.
     */
    val searchRelays: List<String>? = null,
) {
    /** The search relays in effect: the user's list, or the defaults. */
    val activeSearchRelays: List<String>
        get() = searchRelays ?: com.nostrvault.data.model.DEFAULT_SEARCH_RELAYS

    /** Loopback port the FIPS mesh forwards to. The relay serves blob reads
     *  there and nothing else, so mesh peers never reach the relay itself. */
    val meshPort: Int
        get() = relayPort + 1

    companion object {
        /**
         * New installs open the timeline feeds in Threaded View (iOS
         * e3decc63, Logen 2026-10-08). Not the [feedLayoutModes] default:
         * config.json leaves out values equal to their default, so a saved
         * config from before this setting reads back without the key and
         * would jump to Threaded View. Only a config that never existed
         * gets it ([newInstall]); saved ones keep their legacy compact choice.
         */
        val NEW_INSTALL_FEED_LAYOUTS: Map<String, String> = listOf(
            com.nostrvault.data.model.FeedMode.FOLLOWING,
            com.nostrvault.data.model.FeedMode.DISCOVERY,
            com.nostrvault.data.model.FeedMode.GLOBAL,
            com.nostrvault.data.model.FeedMode.HASHTAGS,
            com.nostrvault.data.model.FeedMode.POPULAR,
        ).associate { it.name to com.nostrvault.data.model.FeedLayoutMode.THREADED.storageKey }

        /** The config for an install with none saved yet (or just reset). */
        fun newInstall(): HavenConfig = HavenConfig(feedLayoutModes = NEW_INSTALL_FEED_LAYOUTS)
    }


    /** Computed local relay WebSocket URL.
     *  Always uses ws:// for localhost since the local relay runs without TLS.
     *  Handles persisted configs that still have wss://127.0.0.1. */
    val nostrURL: String?
        get() {
            if (ownerNpub.isEmpty()) return null
            if (useExternalRelay) return normalizeExternalRelayURL(externalRelayURL)
            // Local relay runs without TLS; convert any persisted wss:// to ws://
            return relayURL
                .replace("wss://127.0.0.1", "ws://127.0.0.1")
                .replace("wss://localhost", "ws://localhost")
        }

    /**
     * One of the embedded relay's sub-relays (`inbox`, `chat`, `private`,
     * `feed`). An external relay is a single endpoint with no such paths, so
     * every sub-relay collapses onto its base URL.
     */
    fun localRelayURL(path: String): String? {
        val base = nostrURL ?: return null
        return if (useExternalRelay) base else "${base.trimEnd('/')}/$path"
    }

    /** Computed local inbox relay URL. */
    val localInboxURL: String?
        get() = localRelayURL("inbox")

    /** Base URL of the Blossom server the app stores media on first. */
    val localBlossomBaseURL: String?
        get() = if (useExternalRelay) {
            normalizeExternalBlossomURL(externalBlossomURL)
        } else {
            // Android relay runs without TLS (HAVEN_ENABLE_TLS=0), so plain HTTP.
            "http://localhost:$relayPort"
        }

    // ── Haven Relay Derived URLs ──────────────────────────────────

    /** Strips any scheme and trailing slashes from macRelayURL to give the bare host[:port]. */
    val macRelayNormalizedBase: String
        get() {
            var url = macRelayURL.trim()
            for (scheme in listOf("wss://", "ws://", "https://", "http://")) {
                if (url.lowercase().startsWith(scheme)) {
                    url = url.drop(scheme.length)
                }
            }
            while (url.endsWith("/")) url = url.dropLast(1)
            // Reject hostnames with spaces or other invalid characters
            if (url.contains(' ') || url.isEmpty()) return ""
            return url
        }

    /** Always returns the wss:// form of macRelayURL (empty string if macRelayURL is empty). */
    val macRelayWssURL: String
        get() = macRelayNormalizedBase.let { if (it.isEmpty()) "" else "wss://$it" }

    /** Always returns the https:// form of macRelayURL (empty string if macRelayURL is empty). */
    val macRelayHttpsURL: String
        get() = macRelayNormalizedBase.let { if (it.isEmpty()) "" else "https://$it" }

    /** The Mac relay's inbox as a DM relay, or "" — see [DMInbox.havenInboxURL]. */
    val ownHavenDMInboxURL: String
        get() = DMInbox.havenInboxURL(macRelayURL, macRelayNormalizedBase)

    /** The one DM inbox list: the Haven inbox first, then [dmRelays]. */
    val dmInboxRelays: List<String>
        get() = DMInbox.merged(ownHavenDMInboxURL, dmRelays)

    // ── Active Relay Lists (with Haven relay prepended) ───────────

    /** Active inbox/feed relays (user-configured or defaults). */
    val activeInboxRelays: List<String>
        get() = inboxRelays ?: listOf(
            "wss://relay.primal.net",
            "wss://nos.lol",
            "wss://nostr.mom",
            "wss://relay.btcforplebs.com",
            "wss://nostr-pub.wellorder.net",
        )

    /** Active feed relays, including the Haven relay if configured. */
    val activeFeedRelays: List<String>
        get() {
            val relays = (feedRelays ?: activeInboxRelays).toMutableList()
            val macWss = macRelayWssURL
            if (macWss.isNotEmpty() && macWss !in relays) {
                relays.add(0, macWss)
            }
            return relays
        }

    /** Active blastr relays, including the Haven relay if configured. */
    val activeBlastrRelays: List<String>
        get() {
            val relays = blastrRelays.ifEmpty {
                listOf(
                    "wss://relay.btcforplebs.com",
                    "wss://relay.damus.io",
                    "wss://relay.snort.social",
                )
            }.toMutableList()
            val macWss = macRelayWssURL
            if (macWss.isNotEmpty() && macWss !in relays) {
                relays.add(0, macWss)
            }
            return relays
        }

    /**
     * The relays features read other people's events from: the feed relays
     * (Haven relay first), or [RelayConfiguration.FALLBACK_RELAYS] when there
     * are none. Ask this rather than building a list per feature.
     */
    val readRelays: List<String>
        get() = activeFeedRelays.ifEmpty { RelayConfiguration.FALLBACK_RELAYS }

    /**
     * The relays the owner's events are sent to: the broadcast relays (Haven
     * relay first), or [RelayConfiguration.FALLBACK_WRITE_RELAYS] when there are none.
     */
    val writeRelays: List<String>
        get() = activeBlastrRelays.ifEmpty { RelayConfiguration.FALLBACK_WRITE_RELAYS }

    /**
     * Kind 10002 tags: the Haven relay, then the Read relays (the feed list,
     * or the setup wizard's inbox list when the feed list was never set) and
     * the Write relays. See [PublicRelayList].
     */
    val publicRelayListTags: List<List<String>>
        get() = PublicRelayList.tags(
            ownRelays = listOf(macRelayWssURL),
            read = feedRelays ?: activeInboxRelays,
            write = blastrRelays,
        )

    /** Active import seed relays, including the Haven relay if configured. */
    val activeImportSeedRelays: List<String>
        get() {
            val relays = importSeedRelays.toMutableList()
            val macWss = macRelayWssURL
            if (macWss.isNotEmpty() && macWss !in relays) {
                relays.add(0, macWss)
            }
            return relays
        }

    /** Active blossom mirror servers, including the Haven relay if configured. */
    val activeBlossomMirrors: List<String>
        get() {
            val mirrors = blossomMirrors.toMutableList()
            val macHttps = macRelayHttpsURL
            if (macHttps.isNotEmpty() && macHttps !in mirrors) {
                mirrors.add(0, macHttps)
            }
            return mirrors
        }

    /** Full account roster: owner first, then any added accounts (deduped). */
    fun allAccountNpubs(): List<String> =
        (listOf(ownerNpub) + accountNpubs)
            .filter { it.isNotEmpty() }
            .distinct()

    /** Per-account signing mode, defaulting sensibly. */
    fun signingMode(forNpub: String): String {
        accountSigningModes[forNpub]?.let { return it }
        return if (forNpub == ownerNpub) signingMode else "local"
    }

    /** NIP-46 bunker config for the given account, if configured. */
    fun bunkerConfig(forNpub: String): AccountBunkerConfig? =
        accountBunkerConfigs[forNpub]?.takeIf { it.isConfigured }

    /** Current signing mode for the active account (resolves per-account state). */
    fun activeSigningMode(): String = effectiveSigningMode(activeOrOwnerNpub())

    /**
     * The signing mode [npub] actually signs with: its chosen mode, with
     * nip46 only when a bunker is configured for it. Owner-forced events use
     * this for the owner, never the active account's mode (#168 parity).
     */
    fun effectiveSigningMode(npub: String): String {
        when (accountSigningModes[npub]) {
            "nip46" -> if (bunkerConfig(npub) != null) return "nip46"
            "amber" -> return "amber"
            "local" -> return "local"
        }
        if (bunkerConfig(npub) != null) return "nip46"
        // Legacy single-owner fallback.
        if (npub == ownerNpub) return signingMode
        return "local"
    }

    /** The npub of the currently-active account, falling back to the owner. */
    fun activeOrOwnerNpub(): String {
        val active = activeAccountNpub?.trim().orEmpty()
        return active.ifEmpty { ownerNpub }
    }

    /** Blocked npubs for the active account, falling back to the legacy flat list. */
    fun blockedForActiveAccount(): List<String> =
        blockedNpubsPerAccount[activeOrOwnerNpub()] ?: blockedNpubs ?: emptyList()

    /** Per-account push preferences, falling back to the global flags. */
    fun pushPrefsFor(npub: String): PushPrefs =
        pushPrefsPerAccount[npub] ?: PushPrefs(
            mentions = pushNotifyMentions,
            replies = pushNotifyReplies,
            dms = pushNotifyDMs,
            zaps = pushNotifyZaps,
            reactions = pushNotifyReactions,
            reposts = pushNotifyReposts,
        )
}

/** Per-account push notification preferences (mirrors iOS). */
@kotlinx.serialization.Serializable
data class PushPrefs(
    val mentions: Boolean = true,
    val replies: Boolean = true,
    val dms: Boolean = true,
    val zaps: Boolean = true,
    val reactions: Boolean = false,
    val reposts: Boolean = false,
    /** Someone new follows this account (or comes back after a week away). */
    val follows: Boolean = true,
) {
    /**
     * Whether any notification at all is wanted. The relay's catch-up summary
     * ("N more new items while you were away") counts events of every type at
     * once, so no single preference governs it — but turning everything off has
     * to silence it too, which it previously did not.
     */
    val wantsAnything: Boolean
        get() = mentions || replies || dms || zaps || reactions || reposts
}

/** Config-level joined group (no dependency on service layer). */
@kotlinx.serialization.Serializable
data class JoinedGroupConfig(
    val relayURL: String,
    val groupId: String,
    val displayName: String? = null,
)

/**
 * Per-account NIP-46 remote-signer (bunker) configuration.
 * Mirrors iOS AccountBunkerConfig. Non-secret metadata is persisted in config
 * JSON; the clientSecretKey is sensitive but kept here for parity with iOS
 * (the bunker session needs it to reconnect on account switch).
 */
@kotlinx.serialization.Serializable
data class AccountBunkerConfig(
    val bunkerURI: String = "",
    val signerPubkey: String = "",
    val relayURL: String = "",
    val secret: String = "",
    val clientSecretKey: String = "",
    val clientPubkey: String = "",
) {
    val isConfigured: Boolean
        get() = bunkerURI.isNotEmpty() || signerPubkey.isNotEmpty()
}

/**
 * Normalizes a user-typed relay address: trims it, drops trailing slashes and
 * adds a scheme when none was given. Two kinds of address are accepted:
 *
 * - A relay app on this phone (Citrine): `ws://` or `wss://` on 127.0.0.1 or
 *   localhost. A bare address gets `ws://`.
 * - A relay somewhere else (Nostr Vault for Mac on a domain): `wss://` only.
 *   A bare address gets `wss://`.
 *
 * Plain `ws://` to any other host is refused: network_security_config only
 * allows cleartext to loopback, so it would validate and then silently fail.
 * `.onion` is refused too; the app has no Tor client.
 */
fun normalizeExternalRelayURL(raw: String): String? =
    normalizeExternalURL(raw, secure = "wss://", plain = "ws://")

/** Same as [normalizeExternalRelayURL] for a Blossom server (`https://`, or `http://` on this phone). */
fun normalizeExternalBlossomURL(raw: String): String? =
    normalizeExternalURL(raw, secure = "https://", plain = "http://")

private val IPV4_LITERAL = Regex("^(\\d{1,3})\\.(\\d{1,3})\\.\\d{1,3}\\.\\d{1,3}$")

/**
 * Whether [url] points at this phone or a private network: loopback, the
 * RFC 1918 ranges, Tailscale's 100.64/10, `.local` and `.ts.net` names. A
 * link to such a host only opens for its owner, so it must never be the
 * only link a post carries. Hostnames are matched as IP literals, so
 * `10.example.com` is public.
 */
fun isPrivateNetworkURL(url: String): Boolean {
    val host = runCatching { java.net.URI(url).host }.getOrNull()?.lowercase()?.trim('[', ']') ?: return false
    if (host == "localhost" || host == "::1" || host.endsWith(".local") || host.endsWith(".ts.net")) return true
    val m = IPV4_LITERAL.matchEntire(host) ?: return false
    val a = m.groupValues[1].toInt()
    val b = m.groupValues[2].toInt()
    return a == 127 || a == 10 || (a == 192 && b == 168) || (a == 172 && b in 16..31) ||
        (a == 100 && b in 64..127)
}

private fun normalizeExternalURL(raw: String, secure: String, plain: String): String? {
    var url = raw.trim().trimEnd('/')
    if (url.isEmpty() || url.any { it.isWhitespace() }) return null
    val lower = url.lowercase()
    if ("://" !in lower) {
        val bareHost = lower.substringBefore('/').substringBefore(':')
        url = (if (bareHost == "127.0.0.1" || bareHost == "localhost") plain else secure) + url
    } else if (!lower.startsWith(secure) && !lower.startsWith(plain)) {
        return null
    }
    val uri = runCatching { java.net.URI(url) }.getOrNull() ?: return null
    val host = uri.host?.lowercase() ?: return null
    if (host.endsWith(".onion")) return null
    val onDevice = host == "127.0.0.1" || host == "localhost"
    if (!onDevice && !url.lowercase().startsWith(secure)) return null
    return url
}
