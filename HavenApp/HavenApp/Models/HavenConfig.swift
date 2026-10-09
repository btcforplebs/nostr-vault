import Foundation

/// Per-account NIP-46 remote signer configuration.
struct AccountBunkerConfig: Codable, Equatable {
    var bunkerURI: String = ""
    var signerPubkey: String = ""
    var relayURL: String = ""
    var secret: String = ""
    var clientSecretKey: String = ""
    var clientPubkey: String = ""
}

struct HavenConfig: Codable, Equatable {
    var ownerNpub: String = ""
    var relayURL: String = ""
    var relayPort: Int = 3355
    /// Loopback port the FIPS mesh tunnel forwards to: plain HTTP, blob
    /// GET/HEAD only, so mesh peers never reach the relay itself (NIP-F1).
    var meshPlainPort: Int { relayPort + 1 }
    var dbEngine: String = "badger"
    var blossomPath: String = "blossom/"
    var logLevel: String = "INFO"
    var launchAtLogin: Bool = false
    var autoStartRelay: Bool = true
    var hasCompletedSetup: Bool = false
    var hasSeenWelcome: Bool = false
    var hasAcceptedToS: Bool = false
    var setupMode: String = "full" // "full", "browse", or "newuser"
    var defaultFeedMode: String = "FOLLOWING" // "FOLLOWING", "POPULAR", etc.
    var hasCompletedInitialImport: Bool = false // Browse mode: tracks if first background import has run
    var disableMediaCache: Bool = false
    var autoplayVideos: Bool = true
    var cacheTTLDays: Int = 3
    var prefetchProfilePictures: Bool = false
    var ownerNcryptsec: String = "" // NIP-49 encrypted private key
    var ownerNsec: String = "" // Deprecated: kept for migration purposes only
    var showReplies: Bool = true // Added to toggle visibility of replies in feed
    var themeColor: String = "orange"
    var autoLoadNewPosts: Bool = false
    var showReposts: Bool = true
    /// OLED black is the only appearance now — the Appearance toggle that drove
    /// this is gone. Kept as a stored property so existing configs still decode;
    /// the decoder forces it true regardless of what was saved.
    var useOLED: Bool = true
    var textSizeScale: Double = 1.0
    var useFeedCompactMode: Bool = true // Legacy global default; per-feed overrides live in feedCompactModes
    var feedCompactModes: [String: Bool] = [:] // Per-feed compact-mode overrides, keyed by FeedMode.rawValue
    /// Per-feed layout choice (expanded / condensed / threaded), keyed by
    /// FeedMode.rawValue. Supersedes `feedCompactModes`, which is still read as
    /// the fallback so an upgrade keeps whatever compact setting was in place.
    /// New installs open the timeline feeds in Threaded View (Logen,
    /// 2026-10-08). Saved configs keep their own, including older ones
    /// without this key (see `init(from:)`).
    var feedLayoutModes: [String: String] = Dictionary(uniqueKeysWithValues:
        ["Following", "Discovery", "Global", "Hashtags", "Popular"].map { ($0, "threaded") })
    var noteDetailExpandedEngagement: Bool = false // Persisted stats/engagement toggle for NoteDetailView
    var defaultReactionEmoji: String = "❤️" // Default emoji for quick reactions
    var appIcon: String = "Default" // Selected app icon name
    var zapsOnlyMode: Bool = false // When true, likes/reactions are removed from the UI entirely; zaps become the primary engagement + notification signal
    var disableTabBarAnimation: Bool = false // When true, the bottom tab bar stays fully expanded and never shrinks/hides on scroll
    /// The floating "New Posts" pill over the feed. Off, waiting posts load
    /// on pull-to-refresh (or by themselves at the top with Auto-Load).
    var showNewPostsPill: Bool = true
    /// Lines of note text a row shows in Compact View.
    var compactLineLimit: Int = HavenConfig.defaultCompactLineLimit
    /// Lines of text a thread's root shows in Threaded View; replies show one fewer.
    var threadedLineLimit: Int = HavenConfig.defaultThreadedLineLimit
    static let defaultCompactLineLimit = 3
    static let defaultThreadedLineLimit = 3
    static let lineLimitRange = 1...12
    /// ISO 639-1 codes the Global feed is narrowed to. Empty shows every language.
    var globalFeedLanguages: [String] = []
    /// A Translate button under posts written in another language.
    var showTranslateButton: Bool = true
    /// ISO 639-1 code posts are translated into. Empty follows the device language.
    var translateTargetLanguage: String = ""
    /// Global shows everyone, not only people in your Web of Trust. Off by default.
    var globalShowsEveryone: Bool = false

    // Mac relay (iOS only)
    var macRelayURL: String = "" // wss:// URL to a remote Mac Haven relay to sync missed notes
    
    // NWC (Nostr Wallet Connect)
    var nwcURI: String = ""
    var defaultZapAmount: Int = 1000 // In millisats (default 1 sat)

    // Bitcoin Taproot wallet (derived from Nostr keypair via BIP-341)
    var showBitcoinWallet: Bool = false

    // NIP-46 Remote Signing
    var signingMode: String = "local" // "local" or "nip46"
    var nip46BunkerURI: String = "" // Full bunker:// URI for reconnection
    var nip46SignerPubkey: String = "" // Remote signer's hex pubkey
    var nip46RelayURL: String = "" // Shared relay URL for NIP-46 communication
    var nip46Secret: String = "" // Auth secret from bunker URI
    var nip46ClientSecretKey: String = "" // Client keypair hex secret (for NIP-44 channel encryption)
    var nip46ClientPubkey: String = "" // Client keypair hex pubkey

    // Notifications (generated on-device; there is no push server)
    var enableRemotePushServer: Bool = false // Kept for migration only
    var enablePushNotifications: Bool = false
    /// "N new notes in your feed" after a spell away. Off by default: it is a
    /// summary of everyone you follow, not of anything addressed to you, and it
    /// used to fire from every background wake with no way to turn it off.
    var enableFeedNotifications: Bool = false
    var notificationPrefsPerAccount: [String: NotificationPreferences] = [:]
    var notificationSoundName: String = NotificationSound.defaultSound.rawValue
    
    // Private Relay
    var privateRelayName: String = "Nostr Vault Private"
    var privateRelayDescription: String = "My private Nostr Vault relay"
    var privateRelayIcon: String = ""
    
    // Chat Relay
    var chatRelayName: String = "Nostr Vault Chat"
    var chatRelayDescription: String = "Private chat relay"
    var chatRelayIcon: String = ""
    var chatRelayWotDepth: Int = 3
    var chatRelayWotRefreshHours: Int = 24
    var wotRefreshInterval: String = "24h"
    var chatRelayMinFollowers: Int = 3
    
    // Outbox Relay (Public)
    var outboxRelayName: String = "Nostr Vault Public"
    var outboxRelayDescription: String = "Public outbox relay"
    var outboxRelayIcon: String = ""
    var outboxMaxEventsPerMinute: Int = 100
    var outboxMaxConnectionsPerMinute: Int = 5
    
    // Inbox Relay
    var inboxRelayName: String = "Nostr Vault Inbox"
    var inboxRelayDescription: String = "Personal inbox relay"
    var inboxRelayIcon: String = ""
    // Drives BOTH Go sync loops (inbox catch-up AND feed sync); each round
    // materializes the full windowed local set per store. 60s pinned the CPU
    // once the DBs grew past what a round could reconcile inside the tick —
    // live subscriptions cover real-time delivery, this only heals gaps.
    var inboxPullIntervalSeconds: Int = 900
    
    // Import
    var importStartDate: String = "2023-01-01"
    var importSeedRelaysFile: String = "relays_import.json"
    // relay.damus.io replaced nos.lol and nostr.mom (2026-10-07: both timed
    // out on connect). relay.nostr.build was tried and dropped: it wants
    // NIP-42 sign-in before it answers, which the import doesn't do.
    var importSeedRelays: [String] = [
        "wss://relay.primal.net",
        "wss://relay.damus.io",
        "wss://relay.btcforplebs.com",
        "wss://nostr-pub.wellorder.net"
    ]
    var importOwnerNotesFetchTimeoutSeconds: Int = 60
    var importTaggedNotesFetchTimeoutSeconds: Int = 120

    // Blossom Mirrors
    var blossomMirrors: [String] = []
    var autoMirrorMedia: Bool = false
    /// Picking a nostr.build GIF downloads it and uploads it to your own
    /// Blossom servers, instead of posting nostr.build's link.
    var saveGifsToBlossom: Bool = false

    /// Where a brand-new account's photos go when it has no server of its own.
    /// blossomMirrors is otherwise empty on a fresh install, and with no
    /// outside server a photo (the profile picture included) lives only on the
    /// phone and can't be shown to anyone else. Both accepted an upload signed
    /// by a never-seen key and returned the blob under its own sha256
    /// (checked 2026-10-07). nostr.build first at Logen's request (its blobs
    /// are served from blossom.band), Primal second. Only setup's New to
    /// Nostr path applies this.
    static let newAccountBlossomMirrors = ["https://blossom.nostr.build", "https://blossom.primal.net"]

    /// Former default mirrors that no longer exist (kylezien is NXDOMAIN,
    /// satellite's CDN is dead — verified 2026-07). Configs written by old
    /// builds may still carry them; they fail every upload and add timeout
    /// latency to every post, so they are dropped on config load.
    static let defunctMirrorHosts: Set<String> = ["blossom.kylezien.com", "cdn.satellite.earth"]

    static func isDefunctMirror(_ urlString: String) -> Bool {
        let lowered = urlString.lowercased()
        return defunctMirrorHosts.contains { lowered.contains($0) }
    }

    // FIPS Blossom Publishing
    var fipsPublishEnabled: Bool = false
    var fipsAddressSource: String = "detected"  // "detected" | "owner" | "custom"
    var fipsCustomNpub: String = ""

    // Blastr
    var blastrRelaysFile: String = "relays_blastr.json"
    // Default broadcast relays (Logen, 2026-10-07). nos.lol and nostr.mom
    // were timing out on connect.
    var blastrRelays: [String] = [
        "wss://relay.btcforplebs.com",
        "wss://relay.damus.io",
        "wss://relay.snort.social"
    ]
    
    // Feed Reading
    var feedRelays: [String] = [
        "wss://relay.primal.net",
        "wss://nos.lol",
        "wss://nostr.mom",
        "wss://relay.btcforplebs.com",
        "wss://nostr-pub.wellorder.net"
    ]

    // NIP-17: DM Relays (kind 10050)
    var dmRelays: [String] = [
        "wss://relay.primal.net",
        "wss://nos.lol",
        "wss://relay.btcforplebs.com"
    ]
    /// When `dmRelays` last changed, in Unix seconds: the user's own edit, or
    /// the created_at of a published kind 10050 this device adopted. Devices
    /// compare it with the newest published list at launch so the most recent
    /// change wins, instead of each device overwriting the list with whatever
    /// it happens to hold. nil = never set (the defaults), which any published
    /// list beats.
    var dmRelaysUpdatedAt: Int64? = nil

    /// Relays the app never connects to (Never connect), published as the
    /// owner's blocked relay list (NIP-51 kind 10006). Enforced in
    /// `WebSocketClient` through `RelayBlocklist`.
    var blockedRelays: [String] = []

    // Whitelisted Npubs (multi-npub support)
    var whitelistedNpubs: [String] = []
    var whitelistedNpubsFile: String = "whitelisted_npubs.json"
    
    // Active account for UI browsing (empty = use ownerNpub)
    var activeAccountNpub: String = ""
    
    // Per-account encrypted private keys: [npub: ncryptsec]
    // The owner key is stored separately (ownerNcryptsec). This dict is only for whitelisted accounts.
    var accountCredentials: [String: String] = [:]

    // Per-account NIP-46 bunker configs: [npub: AccountBunkerConfig]
    var accountBunkerConfigs: [String: AccountBunkerConfig] = [:]

    // Per-account signing mode preference: [npub: "local" | "nip46"]
    // When set, overrides auto-detection. Allows accounts to hold both a local key and a bunker.
    var accountSigningModes: [String: String] = [:]

    // Per-account NIP-65 relay list publishing: [npub: enabled]
    // When true, publishes Kind 10002 advertising this relay as the account's inbox.
    var publishRelayListPerAccount: [String: Bool] = [:]

    // Blacklisted Npubs
    var blacklistedNpubs: [String] = []
    var blacklistedNpubsFile: String = "blacklisted_npubs.json"

    // Per-account blocked list (dictionary of npub: [blocked npubs])
    var blockedNpubsPerAccount: [String: [String]] = [:]

    /// All npubs blocked on ANY configured account, combined. The relay-level
    /// blacklist (BLACKLISTED_NPUBS_FILE / the live UpdateBlacklistC push) is
    /// global, not per-account — blocking someone on any account should stop
    /// the relay importing/notifying about them for every account on this
    /// device, not just the one that blocked them. blacklistedNpubs itself is
    /// left untouched by this: it's the legacy owner-only field several UI
    /// call sites still read as a fallback, not something to repurpose.
    var allBlockedNpubsAcrossAccounts: [String] {
        var combined = Set(blockedNpubsPerAccount.values.flatMap { $0 })
        combined.formUnion(blacklistedNpubs)
        return Array(combined)
    }
    // Last processed/published Kind 10000 event timestamp per account (npub: created_at)
    var blockedNpubsLastSyncTimestamp: [String: Int64] = [:]

    // Backup
    var backupProvider: String = "none" // none, s3
    var backupIntervalHours: Int = 24

    // S3
    var s3AccessKeyId: String = ""
    var s3SecretKey: String = ""
    var s3Endpoint: String = ""
    var s3Region: String = ""
    var s3BucketName: String = ""
    
    static let `default` = HavenConfig()
    
    // MARK: - Decodable implementation to handle migrations
    
    enum CodingKeys: String, CodingKey {
        case ownerNpub, relayURL, relayPort, dbEngine, blossomPath, logLevel
        case launchAtLogin, autoStartRelay, hasCompletedSetup, hasSeenWelcome, hasAcceptedToS, setupMode, hasCompletedInitialImport, disableMediaCache, autoplayVideos, cacheTTLDays, prefetchProfilePictures, ownerNcryptsec, ownerNsec, showReplies, nwcURI, defaultZapAmount, themeColor, autoLoadNewPosts, showReposts, showBitcoinWallet
        case useOLED, textSizeScale, useFeedCompactMode, feedCompactModes, feedLayoutModes, noteDetailExpandedEngagement, defaultReactionEmoji, appIcon, zapsOnlyMode, disableTabBarAnimation, showNewPostsPill, compactLineLimit, threadedLineLimit, globalFeedLanguages, globalShowsEveryone, showTranslateButton, translateTargetLanguage
        case signingMode, nip46BunkerURI, nip46SignerPubkey, nip46RelayURL, nip46Secret, nip46ClientSecretKey, nip46ClientPubkey
        case enableRemotePushServer, enablePushNotifications, notificationPrefsPerAccount, notificationSoundName, enableFeedNotifications
        case macRelayURL
        case privateRelayName, privateRelayDescription, privateRelayIcon
        case chatRelayName, chatRelayDescription, chatRelayIcon, chatRelayWotDepth, chatRelayWotRefreshHours, wotRefreshInterval, chatRelayMinFollowers
        case outboxRelayName, outboxRelayDescription, outboxRelayIcon, outboxMaxEventsPerMinute, outboxMaxConnectionsPerMinute
        case inboxRelayName, inboxRelayDescription, inboxRelayIcon, inboxPullIntervalSeconds
        case importStartDate, importSeedRelaysFile, importSeedRelays, importOwnerNotesFetchTimeoutSeconds, importTaggedNotesFetchTimeoutSeconds
        case blossomMirrors, autoMirrorMedia, saveGifsToBlossom
        case fipsPublishEnabled, fipsAddressSource, fipsCustomNpub
        case blastrRelaysFile, blastrRelays
        case feedRelays, dmRelays, dmRelaysUpdatedAt, blockedRelays
        case whitelistedNpubs, whitelistedNpubsFile
        case blacklistedNpubs, blacklistedNpubsFile
        case blockedNpubsPerAccount
        case blockedNpubsLastSyncTimestamp
        case activeAccountNpub
        case accountCredentials
        case accountBunkerConfigs
        case accountSigningModes
        case publishRelayListPerAccount
        case backupProvider, backupIntervalHours
        case s3AccessKeyId, s3SecretKey, s3Endpoint, s3Region, s3BucketName
    }
    
    init() {}
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = HavenConfig.default
        
        ownerNpub = try container.decodeIfPresent(String.self, forKey: .ownerNpub) ?? defaults.ownerNpub
        relayURL = try container.decodeIfPresent(String.self, forKey: .relayURL) ?? defaults.relayURL
        relayPort = try container.decodeIfPresent(Int.self, forKey: .relayPort) ?? defaults.relayPort
        dbEngine = try container.decodeIfPresent(String.self, forKey: .dbEngine) ?? defaults.dbEngine
        blossomPath = try container.decodeIfPresent(String.self, forKey: .blossomPath) ?? defaults.blossomPath
        logLevel = try container.decodeIfPresent(String.self, forKey: .logLevel) ?? defaults.logLevel
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? defaults.launchAtLogin
        autoStartRelay = try container.decodeIfPresent(Bool.self, forKey: .autoStartRelay) ?? defaults.autoStartRelay
        hasCompletedSetup = try container.decodeIfPresent(Bool.self, forKey: .hasCompletedSetup) ?? defaults.hasCompletedSetup
        hasSeenWelcome = try container.decodeIfPresent(Bool.self, forKey: .hasSeenWelcome) ?? defaults.hasSeenWelcome
        hasAcceptedToS = try container.decodeIfPresent(Bool.self, forKey: .hasAcceptedToS) ?? defaults.hasAcceptedToS
        setupMode = try container.decodeIfPresent(String.self, forKey: .setupMode) ?? defaults.setupMode
        hasCompletedInitialImport = try container.decodeIfPresent(Bool.self, forKey: .hasCompletedInitialImport) ?? defaults.hasCompletedInitialImport
        disableMediaCache = try container.decodeIfPresent(Bool.self, forKey: .disableMediaCache) ?? defaults.disableMediaCache
        autoplayVideos = try container.decodeIfPresent(Bool.self, forKey: .autoplayVideos) ?? defaults.autoplayVideos
        cacheTTLDays = try container.decodeIfPresent(Int.self, forKey: .cacheTTLDays) ?? defaults.cacheTTLDays
        prefetchProfilePictures = try container.decodeIfPresent(Bool.self, forKey: .prefetchProfilePictures) ?? defaults.prefetchProfilePictures
        ownerNcryptsec = try container.decodeIfPresent(String.self, forKey: .ownerNcryptsec) ?? defaults.ownerNcryptsec
        ownerNsec = try container.decodeIfPresent(String.self, forKey: .ownerNsec) ?? defaults.ownerNsec
        showReplies = try container.decodeIfPresent(Bool.self, forKey: .showReplies) ?? defaults.showReplies
        nwcURI = try container.decodeIfPresent(String.self, forKey: .nwcURI) ?? defaults.nwcURI
        macRelayURL = try container.decodeIfPresent(String.self, forKey: .macRelayURL) ?? defaults.macRelayURL
        defaultZapAmount = try container.decodeIfPresent(Int.self, forKey: .defaultZapAmount) ?? defaults.defaultZapAmount
        // Retired themes (purple/blue/green/pink/slate) resolve to orange rather
        // than being carried forward as an unrenderable key.
        let savedTheme = try container.decodeIfPresent(String.self, forKey: .themeColor) ?? defaults.themeColor
        themeColor = AppTheme(rawValue: savedTheme)?.rawValue ?? AppTheme.orange.rawValue
        autoLoadNewPosts = try container.decodeIfPresent(Bool.self, forKey: .autoLoadNewPosts) ?? defaults.autoLoadNewPosts
        showReposts = try container.decodeIfPresent(Bool.self, forKey: .showReposts) ?? defaults.showReposts
        showBitcoinWallet = try container.decodeIfPresent(Bool.self, forKey: .showBitcoinWallet) ?? defaults.showBitcoinWallet
        // Ignore any saved value: OLED is the only appearance, so an install
        // that had it switched off must not come back looking like the old theme.
        useOLED = true
        textSizeScale = try container.decodeIfPresent(Double.self, forKey: .textSizeScale) ?? defaults.textSizeScale
        useFeedCompactMode = try container.decodeIfPresent(Bool.self, forKey: .useFeedCompactMode) ?? defaults.useFeedCompactMode
        feedCompactModes = try container.decodeIfPresent([String: Bool].self, forKey: .feedCompactModes) ?? defaults.feedCompactModes
        // Not `defaults`: a config from before this key existed keeps its
        // legacy compact choice instead of jumping to Threaded View.
        feedLayoutModes = try container.decodeIfPresent([String: String].self, forKey: .feedLayoutModes) ?? [:]
        noteDetailExpandedEngagement = try container.decodeIfPresent(Bool.self, forKey: .noteDetailExpandedEngagement) ?? defaults.noteDetailExpandedEngagement
        defaultReactionEmoji = try container.decodeIfPresent(String.self, forKey: .defaultReactionEmoji) ?? defaults.defaultReactionEmoji
        appIcon = try container.decodeIfPresent(String.self, forKey: .appIcon) ?? defaults.appIcon
        zapsOnlyMode = try container.decodeIfPresent(Bool.self, forKey: .zapsOnlyMode) ?? defaults.zapsOnlyMode
        disableTabBarAnimation = try container.decodeIfPresent(Bool.self, forKey: .disableTabBarAnimation) ?? defaults.disableTabBarAnimation
        showNewPostsPill = try container.decodeIfPresent(Bool.self, forKey: .showNewPostsPill) ?? defaults.showNewPostsPill
        compactLineLimit = try container.decodeIfPresent(Int.self, forKey: .compactLineLimit) ?? defaults.compactLineLimit
        threadedLineLimit = try container.decodeIfPresent(Int.self, forKey: .threadedLineLimit) ?? defaults.threadedLineLimit
        globalFeedLanguages = try container.decodeIfPresent([String].self, forKey: .globalFeedLanguages) ?? defaults.globalFeedLanguages
        showTranslateButton = try container.decodeIfPresent(Bool.self, forKey: .showTranslateButton) ?? defaults.showTranslateButton
        translateTargetLanguage = try container.decodeIfPresent(String.self, forKey: .translateTargetLanguage) ?? defaults.translateTargetLanguage
        globalShowsEveryone = try container.decodeIfPresent(Bool.self, forKey: .globalShowsEveryone) ?? defaults.globalShowsEveryone

        signingMode = try container.decodeIfPresent(String.self, forKey: .signingMode) ?? defaults.signingMode
        nip46BunkerURI = try container.decodeIfPresent(String.self, forKey: .nip46BunkerURI) ?? defaults.nip46BunkerURI
        nip46SignerPubkey = try container.decodeIfPresent(String.self, forKey: .nip46SignerPubkey) ?? defaults.nip46SignerPubkey
        nip46RelayURL = try container.decodeIfPresent(String.self, forKey: .nip46RelayURL) ?? defaults.nip46RelayURL
        nip46Secret = try container.decodeIfPresent(String.self, forKey: .nip46Secret) ?? defaults.nip46Secret
        nip46ClientSecretKey = try container.decodeIfPresent(String.self, forKey: .nip46ClientSecretKey) ?? defaults.nip46ClientSecretKey
        nip46ClientPubkey = try container.decodeIfPresent(String.self, forKey: .nip46ClientPubkey) ?? defaults.nip46ClientPubkey

        enableRemotePushServer = try container.decodeIfPresent(Bool.self, forKey: .enableRemotePushServer) ?? defaults.enableRemotePushServer

        enableFeedNotifications = try container.decodeIfPresent(Bool.self, forKey: .enableFeedNotifications) ?? defaults.enableFeedNotifications

        // Migrate: if enablePushNotifications was never saved, carry forward enableRemotePushServer
        if let newValue = try container.decodeIfPresent(Bool.self, forKey: .enablePushNotifications) {
            enablePushNotifications = newValue
        } else {
            enablePushNotifications = enableRemotePushServer
        }
        notificationPrefsPerAccount = try container.decodeIfPresent([String: NotificationPreferences].self, forKey: .notificationPrefsPerAccount) ?? defaults.notificationPrefsPerAccount
        // Falls back to the default whenever the saved value doesn't match a known
        // sound — covers both a fresh install and an existing config still carrying
        // the retired "notification" name from before sounds became selectable.
        let savedSound = try container.decodeIfPresent(String.self, forKey: .notificationSoundName) ?? defaults.notificationSoundName
        notificationSoundName = NotificationSound(rawValue: savedSound)?.rawValue ?? NotificationSound.defaultSound.rawValue
        
        privateRelayName = try container.decodeIfPresent(String.self, forKey: .privateRelayName) ?? defaults.privateRelayName
        privateRelayDescription = try container.decodeIfPresent(String.self, forKey: .privateRelayDescription) ?? defaults.privateRelayDescription
        privateRelayIcon = try container.decodeIfPresent(String.self, forKey: .privateRelayIcon) ?? defaults.privateRelayIcon
        
        chatRelayName = try container.decodeIfPresent(String.self, forKey: .chatRelayName) ?? defaults.chatRelayName
        chatRelayDescription = try container.decodeIfPresent(String.self, forKey: .chatRelayDescription) ?? defaults.chatRelayDescription
        chatRelayIcon = try container.decodeIfPresent(String.self, forKey: .chatRelayIcon) ?? defaults.chatRelayIcon
        chatRelayWotDepth = try container.decodeIfPresent(Int.self, forKey: .chatRelayWotDepth) ?? defaults.chatRelayWotDepth
        chatRelayWotRefreshHours = try container.decodeIfPresent(Int.self, forKey: .chatRelayWotRefreshHours) ?? defaults.chatRelayWotRefreshHours
        wotRefreshInterval = try container.decodeIfPresent(String.self, forKey: .wotRefreshInterval) ?? defaults.wotRefreshInterval
        chatRelayMinFollowers = try container.decodeIfPresent(Int.self, forKey: .chatRelayMinFollowers) ?? defaults.chatRelayMinFollowers
        
        outboxRelayName = try container.decodeIfPresent(String.self, forKey: .outboxRelayName) ?? defaults.outboxRelayName
        outboxRelayDescription = try container.decodeIfPresent(String.self, forKey: .outboxRelayDescription) ?? defaults.outboxRelayDescription
        outboxRelayIcon = try container.decodeIfPresent(String.self, forKey: .outboxRelayIcon) ?? defaults.outboxRelayIcon
        outboxMaxEventsPerMinute = try container.decodeIfPresent(Int.self, forKey: .outboxMaxEventsPerMinute) ?? defaults.outboxMaxEventsPerMinute
        outboxMaxConnectionsPerMinute = try container.decodeIfPresent(Int.self, forKey: .outboxMaxConnectionsPerMinute) ?? defaults.outboxMaxConnectionsPerMinute
        
        inboxRelayName = try container.decodeIfPresent(String.self, forKey: .inboxRelayName) ?? defaults.inboxRelayName
        inboxRelayDescription = try container.decodeIfPresent(String.self, forKey: .inboxRelayDescription) ?? defaults.inboxRelayDescription
        inboxRelayIcon = try container.decodeIfPresent(String.self, forKey: .inboxRelayIcon) ?? defaults.inboxRelayIcon
        // Clamp persisted configs that still carry the old 60s default — no
        // UI exposes this value, so anything below 5 min is a legacy save.
        inboxPullIntervalSeconds = max(
            try container.decodeIfPresent(Int.self, forKey: .inboxPullIntervalSeconds) ?? defaults.inboxPullIntervalSeconds,
            300
        )
        
        importStartDate = try container.decodeIfPresent(String.self, forKey: .importStartDate) ?? defaults.importStartDate
        importSeedRelaysFile = try container.decodeIfPresent(String.self, forKey: .importSeedRelaysFile) ?? defaults.importSeedRelaysFile
        importSeedRelays = try container.decodeIfPresent([String].self, forKey: .importSeedRelays) ?? defaults.importSeedRelays
        importOwnerNotesFetchTimeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .importOwnerNotesFetchTimeoutSeconds) ?? defaults.importOwnerNotesFetchTimeoutSeconds
        importTaggedNotesFetchTimeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .importTaggedNotesFetchTimeoutSeconds) ?? defaults.importTaggedNotesFetchTimeoutSeconds

        blossomMirrors = (try container.decodeIfPresent([String].self, forKey: .blossomMirrors) ?? defaults.blossomMirrors)
            .filter { !HavenConfig.isDefunctMirror($0) }
        autoMirrorMedia = try container.decodeIfPresent(Bool.self, forKey: .autoMirrorMedia) ?? defaults.autoMirrorMedia
        saveGifsToBlossom = try container.decodeIfPresent(Bool.self, forKey: .saveGifsToBlossom) ?? defaults.saveGifsToBlossom

        fipsPublishEnabled = try container.decodeIfPresent(Bool.self, forKey: .fipsPublishEnabled) ?? defaults.fipsPublishEnabled
        fipsAddressSource = try container.decodeIfPresent(String.self, forKey: .fipsAddressSource) ?? defaults.fipsAddressSource
        fipsCustomNpub = try container.decodeIfPresent(String.self, forKey: .fipsCustomNpub) ?? defaults.fipsCustomNpub

        blastrRelaysFile = try container.decodeIfPresent(String.self, forKey: .blastrRelaysFile) ?? defaults.blastrRelaysFile
        blastrRelays = try container.decodeIfPresent([String].self, forKey: .blastrRelays) ?? defaults.blastrRelays
        
        feedRelays = try container.decodeIfPresent([String].self, forKey: .feedRelays) ?? defaults.feedRelays
        dmRelays = try container.decodeIfPresent([String].self, forKey: .dmRelays) ?? defaults.dmRelays
        dmRelaysUpdatedAt = try container.decodeIfPresent(Int64.self, forKey: .dmRelaysUpdatedAt)
        blockedRelays = try container.decodeIfPresent([String].self, forKey: .blockedRelays) ?? []

        
        whitelistedNpubs = try container.decodeIfPresent([String].self, forKey: .whitelistedNpubs) ?? defaults.whitelistedNpubs
        whitelistedNpubsFile = try container.decodeIfPresent(String.self, forKey: .whitelistedNpubsFile) ?? defaults.whitelistedNpubsFile
        
        blacklistedNpubs = try container.decodeIfPresent([String].self, forKey: .blacklistedNpubs) ?? defaults.blacklistedNpubs
        blacklistedNpubsFile = try container.decodeIfPresent(String.self, forKey: .blacklistedNpubsFile) ?? defaults.blacklistedNpubsFile
        
        blockedNpubsPerAccount = try container.decodeIfPresent([String: [String]].self, forKey: .blockedNpubsPerAccount) ?? defaults.blockedNpubsPerAccount
        blockedNpubsLastSyncTimestamp = try container.decodeIfPresent([String: Int64].self, forKey: .blockedNpubsLastSyncTimestamp) ?? defaults.blockedNpubsLastSyncTimestamp

        activeAccountNpub = try container.decodeIfPresent(String.self, forKey: .activeAccountNpub) ?? defaults.activeAccountNpub
        accountCredentials = try container.decodeIfPresent([String: String].self, forKey: .accountCredentials) ?? defaults.accountCredentials
        accountBunkerConfigs = try container.decodeIfPresent([String: AccountBunkerConfig].self, forKey: .accountBunkerConfigs) ?? defaults.accountBunkerConfigs
        accountSigningModes = try container.decodeIfPresent([String: String].self, forKey: .accountSigningModes) ?? defaults.accountSigningModes
        publishRelayListPerAccount = try container.decodeIfPresent([String: Bool].self, forKey: .publishRelayListPerAccount) ?? defaults.publishRelayListPerAccount

        // Migration: move global NIP-46 config into per-account dict
        if accountBunkerConfigs.isEmpty {
            adoptGlobalBunkerConfigForOwner()
        }

        backupProvider = try container.decodeIfPresent(String.self, forKey: .backupProvider) ?? defaults.backupProvider
        backupIntervalHours = try container.decodeIfPresent(Int.self, forKey: .backupIntervalHours) ?? defaults.backupIntervalHours

        s3AccessKeyId = try container.decodeIfPresent(String.self, forKey: .s3AccessKeyId) ?? defaults.s3AccessKeyId
        s3SecretKey = try container.decodeIfPresent(String.self, forKey: .s3SecretKey) ?? defaults.s3SecretKey
        s3Endpoint = try container.decodeIfPresent(String.self, forKey: .s3Endpoint) ?? defaults.s3Endpoint
        s3Region = try container.decodeIfPresent(String.self, forKey: .s3Region) ?? defaults.s3Region
        s3BucketName = try container.decodeIfPresent(String.self, forKey: .s3BucketName) ?? defaults.s3BucketName
    }

    // MARK: - Per-Account Signing Mode

    /// Copies the flat nip46* fields into the owner's per-account bunker config.
    /// Setup writes only the flat fields, but activeSigningMode() reads only the
    /// per-account dict — without this the first session after bunker setup
    /// resolves to "local" and every post fails.
    mutating func adoptGlobalBunkerConfigForOwner() {
        guard signingMode == "nip46", !ownerNpub.isEmpty, accountBunkerConfigs[ownerNpub] == nil,
              !nip46BunkerURI.isEmpty || !nip46SignerPubkey.isEmpty else { return }
        accountBunkerConfigs[ownerNpub] = AccountBunkerConfig(
            bunkerURI: nip46BunkerURI,
            signerPubkey: nip46SignerPubkey,
            relayURL: nip46RelayURL,
            secret: nip46Secret,
            clientSecretKey: nip46ClientSecretKey,
            clientPubkey: nip46ClientPubkey
        )
    }

    /// Returns the signing mode for the currently active account.
    /// Respects explicit user preference in accountSigningModes if set,
    /// otherwise falls back to auto-detection based on available credentials.
    func activeSigningMode() -> String {
        let activeNpub = activeAccountNpub.isEmpty ? ownerNpub : activeAccountNpub

        // Check explicit user preference first
        if let preferred = accountSigningModes[activeNpub] {
            // Validate the preference is still usable
            if preferred == "nip46" {
                if let cfg = accountBunkerConfigs[activeNpub], !cfg.bunkerURI.isEmpty || !cfg.signerPubkey.isEmpty {
                    return "nip46"
                }
                // Bunker config was removed — fall through to auto-detect
            } else if preferred == "local" {
                return "local"
            }
        }

        // Auto-detect: if a bunker config exists, use nip46
        if let cfg = accountBunkerConfigs[activeNpub], !cfg.bunkerURI.isEmpty || !cfg.signerPubkey.isEmpty {
            return "nip46"
        }

        // Fallback for initial setup: no npub exists yet, check flat config fields
        if activeNpub.isEmpty && signingMode == "nip46" && (!nip46SignerPubkey.isEmpty || !nip46BunkerURI.isEmpty) {
            return "nip46"
        }

        return "local"
    }

    // MARK: - Mac Relay Derived URLs

    /// Strips any scheme and trailing slashes from macRelayURL to give the bare host[:port]
    var macRelayNormalizedBase: String {
        var url = macRelayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let schemes = ["wss://", "ws://", "https://", "http://"]
        for scheme in schemes {
            if url.lowercased().hasPrefix(scheme) {
                url = String(url.dropFirst(scheme.count))
            }
        }
        while url.hasSuffix("/") { url = String(url.dropLast()) }
        return url
    }

    /// Always returns the wss:// form of macRelayURL (empty string if macRelayURL is empty)
    var macRelayWssURL: String {
        let base = macRelayNormalizedBase
        return base.isEmpty ? "" : "wss://\(base)"
    }

    /// Always returns the https:// form of macRelayURL (empty string if macRelayURL is empty)
    var macRelayHttpsURL: String {
        let base = macRelayNormalizedBase
        return base.isEmpty ? "" : "https://\(base)"
    }

    // MARK: - DM Inbox (NIP-17)

    /// The owner's always-on Haven inbox as a DM relay, or "" when there is
    /// none. On iOS that is the Mac relay; on a Mac it is this relay itself,
    /// once it has a public address. Only a wss:// address counts: the list it
    /// joins is published for other people, and a plain ws:// LAN address is
    /// unreachable to them.
    var ownHavenDMInboxURL: String {
        #if os(macOS)
        guard !isLocal, !Self.isPrivateNetworkHost(sanitizedRelayURL) else { return "" }
        return Self.normalizedRelayURL(nostrURL + "/inbox")
        #else
        let base = macRelayNormalizedBase
        guard !base.isEmpty else { return "" }
        let typed = macRelayURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if typed.hasPrefix("ws://") || typed.hasPrefix("http://") { return "" }
        // A home-network address typed without a scheme would otherwise be
        // published to everyone as wss://…, put first, and be undeliverable.
        if Self.isPrivateNetworkHost(base) { return "" }
        return Self.normalizedRelayURL("wss://\(base)/inbox")
        #endif
    }

    /// True for an address only this network can reach: loopback, private
    /// and link-local IPv4/IPv6 ranges, CGNAT (Tailscale's 100.64.0.0/10),
    /// `localhost`, `.local`, and bare names with no dot. `hostPort` may carry
    /// a port and a path ("192.168.1.20:3355/x").
    static func isPrivateNetworkHost(_ hostPort: String) -> Bool {
        var host = hostPort.lowercased()
        if let slash = host.firstIndex(of: "/") { host = String(host[..<slash]) }
        if host.hasPrefix("[") {
            // [IPv6]:port
            host = String(host.dropFirst().prefix { $0 != "]" })
        } else if host.filter({ $0 == ":" }).count == 1, let colon = host.firstIndex(of: ":") {
            host = String(host[..<colon])
        }
        while host.hasSuffix(".") { host = String(host.dropLast()) }
        if host.hasPrefix("::ffff:") {
            // IPv4-mapped IPv6: judge the IPv4 address it carries.
            let v4 = String(host.dropFirst("::ffff:".count))
            if v4.contains(".") { return isPrivateNetworkHost(v4) }
        }
        if host.isEmpty || host == "localhost" { return true }
        // Home-network names, plus Tailscale MagicDNS: a .ts.net name only
        // reaches outsiders through Funnel, so it can't be relied on.
        for suffix in [".localhost", ".local", ".lan", ".home.arpa", ".internal", ".ts.net"] where host.hasSuffix(suffix) {
            return true
        }
        if host.contains(":") {
            // IPv6: loopback, unspecified, unique-local fc00::/7, link-local fe80::/10
            return host == "::1" || host == "::" || host.hasPrefix("fc") || host.hasPrefix("fd")
                || host.hasPrefix("fe8") || host.hasPrefix("fe9") || host.hasPrefix("fea") || host.hasPrefix("feb")
        }
        let octets = host.split(separator: ".").map { Int($0) }
        if octets.count == 4, octets.allSatisfy({ $0 != nil }) {
            let o = octets.map { $0! }
            switch (o[0], o[1]) {
            case (10, _), (127, _), (0, _): return true
            case (172, 16...31), (192, 168), (169, 254): return true
            case (100, 64...127): return true
            default: return false
            }
        }
        return !host.contains(".")
    }

    /// The one DM inbox list: where other people send this account's DMs,
    /// where this account's own sent copies go, and where every device reads
    /// DMs from. The owner's Haven inbox comes first, then `dmRelays`.
    var dmInboxRelays: [String] {
        Self.mergedDMInboxRelays(havenInbox: ownHavenDMInboxURL, dmRelays: dmRelays)
    }

    static func mergedDMInboxRelays(havenInbox: String, dmRelays: [String]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for raw in [havenInbox] + dmRelays {
            let url = normalizedRelayURL(raw)
            guard !url.isEmpty, seen.insert(url.lowercased()).inserted else { continue }
            result.append(url)
        }
        return result
    }

    /// Whether the active account (as a hex pubkey) moving from `previous` to
    /// `current` is a switch the app should react to. No account to an
    /// account is setup finishing, not a switch.
    static func isAccountSwitch(from previous: String, to current: String) -> Bool {
        !previous.isEmpty && previous != current
    }

    /// Trims whitespace and trailing slashes so the same relay typed two ways
    /// compares equal.
    static func normalizedRelayURL(_ raw: String) -> String {
        var url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while url.hasSuffix("/") { url = String(url.dropLast()) }
        return url
    }

    /// What launch should do with the DM inbox list, given this device's list
    /// and the newest one published for the account.
    enum DMInboxSyncAction: Equatable {
        /// Take the published list (and its timestamp) as this device's own.
        case adopt
        /// Publish this device's list: nothing is published, or ours is newer.
        case publish
        /// Already in step.
        case none
    }

    /// `published` is the newest kind 10050 found (nil = none found);
    /// `publishedAt` its created_at. `local` is this device's merged list.
    static func dmInboxSyncAction(local: [String], localUpdatedAt: Int64?,
                                  published: [String]?, publishedAt: Int64?) -> DMInboxSyncAction {
        guard let published, let publishedAt else {
            // Nothing found. For a list that was never set that means no list
            // is published, so publish one. A device that has synced before
            // more likely just couldn't reach the relays this launch, and
            // publishing would overwrite a newer list it never saw.
            return localUpdatedAt == nil ? .publish : .none
        }
        let localAt = localUpdatedAt ?? 0
        if publishedAt > localAt { return .adopt }
        if localAt > publishedAt { return .publish }
        // Compared as sets: two devices that order the same relays differently
        // must not keep republishing over each other (each publish can ask the
        // signer app for an approval).
        let same = Set(local.map { normalizedRelayURL($0).lowercased() }) == Set(published.map { normalizedRelayURL($0).lowercased() })
        return same ? .none : .publish
    }

    // MARK: - Blossom Mirrors Configuration

    /// Builds the .fips Blossom URL from the configured source, or nil if FIPS publishing is disabled.
    func fipsBlossomURL(detectedNpub: String? = nil) -> String? {
        guard fipsPublishEnabled else { return nil }
        let npub: String
        switch fipsAddressSource {
        case "detected":
            guard let detected = detectedNpub, !detected.isEmpty else { return nil }
            npub = detected
        case "custom":
            npub = fipsCustomNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        default:
            npub = ownerNpub
        }
        let clean = npub.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.hasPrefix("npub1") else { return nil }
        return "http://\(clean).fips:\(relayPort)"
    }

    /// Active Blossom mirrors with optional FIPS URL appended last (clearnet-first per BUD-14).
    func activeBlossomMirrors(detectedNpub: String? = nil) -> [String] {
        var mirrors = blossomMirrors
        let macHttps = macRelayHttpsURL
        if !macHttps.isEmpty, !mirrors.contains(macHttps) {
            mirrors.insert(macHttps, at: 0)
        }
        if let fipsURL = fipsBlossomURL(detectedNpub: detectedNpub), !mirrors.contains(fipsURL) {
            mirrors.append(fipsURL)
        }
        return mirrors
    }

    /// Active Blossom mirrors (convenience, no detected FIPS npub).
    var activeBlossomMirrors: [String] {
        activeBlossomMirrors(detectedNpub: nil)
    }

    /// Whether any mirror works for apps without the FIPS mesh. A fipsmesh
    /// entry must never be a user's only server (NIP-F1).
    var hasPublicBlossomMirror: Bool {
        activeBlossomMirrors.contains { $0.hasPrefix("https://") && !$0.contains(".fips") }
    }

    /// Active feed relays, including the Mac relay if configured.
    var activeFeedRelays: [String] {
        var relays = feedRelays
        let macWss = macRelayWssURL
        if !macWss.isEmpty {
            if !relays.contains(macWss) {
                relays.insert(macWss, at: 0)
            }
        }
        return relays
    }

    /// Active blastr relays, including the Mac relay if configured.
    var activeBlastrRelays: [String] {
        var relays = blastrRelays
        let macWss = macRelayWssURL
        if !macWss.isEmpty {
            if !relays.contains(macWss) {
                relays.insert(macWss, at: 0)
            }
        }
        return relays
    }

    /// Active import seed relays, including the Mac relay if configured.
    var activeImportSeedRelays: [String] {
        var relays = importSeedRelays
        let macWss = macRelayWssURL
        if !macWss.isEmpty {
            if !relays.contains(macWss) {
                relays.insert(macWss, at: 0)
            }
        }
        return relays
    }

    // MARK: - Relay roles

    /// Where features read when the owner has no read relays.
    static let fallbackRelays = ["wss://relay.primal.net", "wss://nos.lol"]

    /// Where the owner's events go when there are no write relays: the
    /// default broadcast list (`blastrRelays`).
    static let fallbackWriteRelays = ["wss://relay.btcforplebs.com", "wss://relay.damus.io", "wss://relay.snort.social"]

    /// The relays features read other people's events from: the feed relays
    /// (Mac relay first), or `fallbackRelays` when there are none. Ask this
    /// rather than building a list per feature.
    var readRelays: [String] {
        let relays = activeFeedRelays
        return relays.isEmpty ? Self.fallbackRelays : relays
    }

    /// The relays the owner's events are sent to: the broadcast relays (Mac
    /// relay first), or `fallbackWriteRelays` when there are none.
    var writeRelays: [String] {
        let relays = activeBlastrRelays
        return relays.isEmpty ? Self.fallbackWriteRelays : relays
    }

    /// The owner's own relays others can reach: the Haven domain (unless it is
    /// this device only) and the Mac relay.
    var ownPublicRelays: [String] {
        var relays: [String] = []
        if !isLocal { relays.append("wss://\(sanitizedRelayURL)") }
        relays.append(macRelayWssURL)
        return relays
    }

    /// NIP-65 kind 10002 tags: the relay list other clients use for this
    /// account. It is the grid's Read and Write columns, so the world sees
    /// what the owner actually uses.
    var publicRelayListTags: [[String]] {
        Self.publicRelayListTags(ownRelays: ownPublicRelays, read: feedRelays, write: blastrRelays)
    }

    /// The owner's own relays go first with no marker, which NIP-65 reads as
    /// both read and write, so they always stay in Write. Then each relay in
    /// both lists has no marker, and one in only one list is marked "read" or
    /// "write". Only wss:// relays others can reach are listed, once each.
    static func publicRelayListTags(ownRelays: [String], read: [String], write: [String]) -> [[String]] {
        func key(_ url: String) -> String { url.lowercased() }
        func publishable(_ raw: String) -> String? {
            let url = normalizedRelayURL(raw)
            guard url.lowercased().hasPrefix("wss://") else { return nil }
            let hostPort = String(url.dropFirst("wss://".count))
            guard !hostPort.isEmpty, !isPrivateNetworkHost(hostPort) else { return nil }
            return url
        }
        let readKeys = Set(read.compactMap(publishable).map(key))
        let writeKeys = Set(write.compactMap(publishable).map(key))
        var seen = Set<String>()
        var tags: [[String]] = []
        for url in ownRelays.compactMap(publishable) where seen.insert(key(url)).inserted {
            tags.append(["r", url])
        }
        for url in (read + write).compactMap(publishable) where seen.insert(key(url)).inserted {
            switch (readKeys.contains(key(url)), writeKeys.contains(key(url))) {
            case (true, true): tags.append(["r", url])
            case (true, false): tags.append(["r", url, "read"])
            default: tags.append(["r", url, "write"])
            }
        }
        return tags
    }

    // MARK: - Protocol Selection Logic

    /// Returns the relay URL without any protocol schemes or trailing slashes
    var sanitizedRelayURL: String {
        var url = relayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let schemes = ["wss://", "ws://", "https://", "http://"]
        for scheme in schemes {
            if url.lowercased().hasPrefix(scheme) {
                url = String(url.dropFirst(scheme.count))
            }
        }
        while url.hasSuffix("/") {
            url = String(url.dropLast())
        }
        return url
    }
    
    /// Returns true if the relay is running locally (empty URL, localhost, or 127.0.0.1)
    var isLocal: Bool {
        let url = sanitizedRelayURL.lowercased()
        if url.isEmpty { return true }
        
        // Split by colon to ignore port
        let host = url.split(separator: ":").first.map(String.init) ?? url
        return host == "localhost" || host == "127.0.0.1"
    }
    
    /// Returns the appropriate WebSocket URL (ws:// for local, wss:// for remote)
    var nostrURL: String {
        if isLocal {
            #if os(macOS)
            return "ws://127.0.0.1:\(relayPort)"
            #else
            return "wss://127.0.0.1:\(relayPort)"
            #endif
        } else {
            return "wss://\(sanitizedRelayURL)"
        }
    }

    /// The relay to name in a tag's relay hint for other clients: this relay
    /// when the world can reach it, otherwise none. A loopback or home-network
    /// address points every other client at itself, or at nothing.
    var publicRelayHint: String {
        guard !isLocal, !Self.isPrivateNetworkHost(sanitizedRelayURL) else { return "" }
        return nostrURL
    }

    /// Returns the appropriate Web/Blossom URL (https:// on iOS for Blossom, http:// on macOS)
    var webURL: String {
        if isLocal {
            #if os(macOS)
            return "http://127.0.0.1:\(relayPort)"
            #else
            return "https://127.0.0.1:\(relayPort)"
            #endif
        } else {
            return "https://\(sanitizedRelayURL)"
        }
    }

    /// Returns the hex private key decoded from ownerNsec (fallback for old plaintext keys)
    var ownerHexKey: String? {
        let clean = ownerNsec.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { return nil }
        if let decoded = Bech32.decode(clean), decoded.hrp == "nsec" {
            return decoded.hexString
        }
        // Fallback for raw hex
        if clean.count == 64 && clean.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil {
            return clean
        }
        return nil
    }

    /// Decrypts the ncryptsec with a password to get the plaintext nsec
    /// - Parameter password: The password to decrypt the key
    /// - Returns: The plaintext nsec if successfully decrypted
    /// - Throws: NIP49Service.NIP49Error if decryption fails
    func getDecryptedNsec(password: String) throws -> String {
        let clean = ownerNcryptsec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            // Fall back to plaintext nsec if no encrypted key exists (migration)
            return ownerNsec
        }
        return try NIP49Service.decrypt(ncryptsec: clean, password: password)
    }

    /// Encrypts an nsec and stores it as ownerNcryptsec
    /// - Parameters:
    ///   - nsec: The plaintext nsec to encrypt
    ///   - password: The password to use for encryption
    /// - Throws: NIP49Service.NIP49Error if encryption fails
    mutating func setEncryptedNsec(nsec: String, password: String) throws {
        ownerNcryptsec = try NIP49Service.encrypt(nsec: nsec, password: password)
        // Clear plaintext key for security
        self.ownerNsec = ""
    }

    /// Gets the hex key by decrypting ncryptsec with a password
    /// - Parameter password: The password to decrypt the key
    /// - Returns: The hex private key if decryption succeeds
    /// - Throws: NIP49Service.NIP49Error if decryption fails
    func getDecryptedHexKey(password: String) throws -> String {
        let nsec = try getDecryptedNsec(password: password)
        let clean = nsec.trimmingCharacters(in: .whitespacesAndNewlines)

        if let decoded = Bech32.decode(clean), decoded.hrp == "nsec" {
            return decoded.hexString
        }
        // Fallback for raw hex
        if clean.count == 64 && clean.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil {
            return clean
        }
        throw NIP49Service.NIP49Error.decodingFailed
    }
}
