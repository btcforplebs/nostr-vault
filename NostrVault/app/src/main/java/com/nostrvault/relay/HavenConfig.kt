package com.nostrvault.relay

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
    /**
     * Someone new follows you. The per-account toggle lives in
     * [PushPrefs.follows]; this is the global fallback for an account with no
     * stored entry, which [pushPrefsFor] used to leave out entirely — so the
     * global switch could not turn new-follower notifications off at all.
     */
    val pushNotifyFollows: Boolean = true,
    /** Setup's "Stay in the Loop" step (or the one launch-time ask for paths
     *  without it) has dealt with POST_NOTIFICATIONS; don't ask again. */
    val notificationPermissionAsked: Boolean = false,
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
    fun blockedForActiveAccount(): List<String> = blockedFor(activeOrOwnerNpub())

    /**
     * Every npub blocked on any account, combined. The relay's blacklist is
     * global, not per-account: a block on any account stops the relay storing
     * and notifying about that person for every account on this device.
     * iOS: HavenConfig.allBlockedNpubsAcrossAccounts.
     */
    fun allBlockedNpubsAcrossAccounts(): List<String> =
        (blockedNpubsPerAccount.values.flatten() + blockedNpubs.orEmpty())
            .map { it.trim() }.filter { it.isNotEmpty() }.distinct().sorted()

    /** Blocked npubs for one account, falling back to the legacy flat list. */
    fun blockedFor(npub: String): List<String> =
        blockedNpubsPerAccount[npub] ?: blockedNpubs ?: emptyList()

    /** Per-account push preferences, falling back to the global flags. */
    fun pushPrefsFor(npub: String): PushPrefs =
        pushPrefsPerAccount[npub] ?: PushPrefs(
            mentions = pushNotifyMentions,
            replies = pushNotifyReplies,
            dms = pushNotifyDMs,
            zaps = pushNotifyZaps,
            reactions = pushNotifyReactions,
            reposts = pushNotifyReposts,
            follows = pushNotifyFollows,
        )
}
