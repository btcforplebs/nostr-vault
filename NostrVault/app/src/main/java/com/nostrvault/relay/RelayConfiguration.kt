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
            "DM_RELAYS_FILE" to "relays_dm.json",

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
        )
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
    // Per-account block/throttle (mirrors iOS blockedNpubsPerAccount /
    // throttledAccountsPerAccount, keyed by account npub). Throttle is local-only
    // (never published); blocked accounts are published as a NIP-51 kind-10000
    // mute list. Default-empty for backward compatibility with old configs.
    val blockedNpubsPerAccount: Map<String, List<String>> = emptyMap(),
    val throttledAccountsPerAccount: Map<String, Map<String, Int>> = emptyMap(),

    // Private Relay
    val privateRelayName: String = "Nostr Vault Private",
    val privateRelayDescription: String = "Private relay",
    val privateRelayIcon: String = "",

    // Chat Relay
    val chatRelayName: String = "Nostr Vault Chat",
    val chatRelayDescription: String = "Chat relay",
    val chatRelayIcon: String = "",
    val chatRelayWotDepth: Int = 2,
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
    val importSeedRelays: List<String> = listOf(
        "wss://relay.primal.net",
        "wss://nos.lol",
        "wss://nostr.mom",
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
    val blastrRelays: List<String> = listOf(
        "wss://relay.primal.net",
        "wss://nos.lol",
        "wss://nostr.mom",
        "wss://relay.btcforplebs.com",
        "wss://nostr-pub.wellorder.net",
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

    // Blossom
    val blossomMirrors: List<String> = emptyList(),

    // Paths (set at runtime by app)
    val relayDataDir: String? = null,
    val appSupportDir: String? = null,

    // NIP-29 Groups (serialized as list of {relayURL, groupId, displayName})
    val joinedGroups: List<JoinedGroupConfig>? = null,

    // NWC (Nostr Wallet Connect)
    val nwcURI: String? = null,
    val defaultZapAmount: Int = 21, // sats

    // Cashu Ecash
    val cashuMintURL: String = "",

    // Bitcoin (BIP-341 taproot address derived from the Nostr keypair)
    val showBitcoinWallet: Boolean = false,

    // Appearance
    val themeColor: String = "orange",
    val textSizeScale: Float = 1.0f,
    /** OLED black is the only appearance now; the Appearance toggle is gone. */
    val oledMode: Boolean = true,
    val useFeedCompactMode: Boolean = true,
    val feedCompactModes: Map<String, Boolean> = emptyMap(),
    val noteDetailCompactView: Boolean = false,
    val noteDetailExpandedEngagement: Boolean = false,
    val defaultReactionEmoji: String = "+",
    // When true, likes/reactions are removed from the UI entirely; zaps become the
    // primary engagement + notification signal. Mirrors iOS HavenConfig.zapsOnlyMode.
    val zapsOnlyMode: Boolean = false,
    // When true, the bottom tab bar stays fully expanded and never shrinks/hides
    // on scroll. Mirrors iOS HavenConfig.disableTabBarAnimation.
    val disableTabBarAnimation: Boolean = false,
    val autoplayVideos: Boolean = true,

    // Performance
    val prefetchAvatars: Boolean = true,

    // Advanced / media (client-side; not sent to the Go relay)
    val disableMediaCache: Boolean = false,
    val cacheTTLDays: Int = 7, // 0 = never evict
    val autoStartRelay: Boolean = true,

    // Notifications. These drive the on-device notifications the embedded
    // relay generates; there is no push server. The APNs forwarder that
    // pushServerURL used to point at was deleted in cd604a3 — it only ever
    // spoke APNs and had no clients left.
    val enablePushNotifications: Boolean = false,
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
) {
    /** Computed local relay WebSocket URL.
     *  Always uses ws:// for localhost since the local relay runs without TLS.
     *  Handles persisted configs that still have wss://127.0.0.1. */
    val nostrURL: String?
        get() {
            if (ownerNpub.isEmpty()) return null
            // Local relay runs without TLS; convert any persisted wss:// to ws://
            return relayURL
                .replace("wss://127.0.0.1", "ws://127.0.0.1")
                .replace("wss://localhost", "ws://localhost")
        }

    /** Computed local inbox relay URL. */
    val localInboxURL: String?
        get() = nostrURL?.let { "$it/inbox" }

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
                    "wss://relay.primal.net",
                    "wss://nos.lol",
                    "wss://nostr.mom",
                    "wss://relay.btcforplebs.com",
                    "wss://nostr-pub.wellorder.net",
                )
            }.toMutableList()
            val macWss = macRelayWssURL
            if (macWss.isNotEmpty() && macWss !in relays) {
                relays.add(0, macWss)
            }
            return relays
        }

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
    fun activeSigningMode(): String {
        val npub = activeOrOwnerNpub()
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

    /** Throttled npub -> max-visible-posts map for the active account (local-only). */
    fun throttledForActiveAccount(): Map<String, Int> =
        throttledAccountsPerAccount[activeOrOwnerNpub()] ?: emptyMap()

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
