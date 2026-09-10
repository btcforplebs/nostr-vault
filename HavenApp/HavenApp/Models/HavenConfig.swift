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
    var cacheTTLDays: Int = 7
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
    var noteDetailCompactView: Bool = false // Persisted compact mode for NoteDetailView
    var noteDetailExpandedEngagement: Bool = false // Persisted stats/engagement toggle for NoteDetailView
    var defaultReactionEmoji: String = "❤️" // Default emoji for quick reactions
    var appIcon: String = "Default" // Selected app icon name
    var zapsOnlyMode: Bool = false // When true, likes/reactions are removed from the UI entirely; zaps become the primary engagement + notification signal
    var disableTabBarAnimation: Bool = false // When true, the bottom tab bar stays fully expanded and never shrinks/hides on scroll

    // Mac Relay Sync (iOS only)
    var macRelayURL: String = "" // wss:// URL to a remote Mac Haven relay to sync missed notes
    
    // NWC (Nostr Wallet Connect)
    var nwcURI: String = ""
    var defaultZapAmount: Int = 1000 // In millisats (default 1 sat)

    // Bitcoin Taproot wallet (derived from Nostr keypair via BIP-341)
    var showBitcoinWallet: Bool = false

    // Cashu Ecash Mint
    var cashuMintURL: String = ""

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
    var notificationPrefsPerAccount: [String: NotificationPreferences] = [:]
    
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
    var importSeedRelays: [String] = [
        "wss://relay.primal.net",
        "wss://nos.lol",
        "wss://nostr.mom",
        "wss://relay.btcforplebs.com",
        "wss://nostr-pub.wellorder.net"
    ]
    var importOwnerNotesFetchTimeoutSeconds: Int = 60
    var importTaggedNotesFetchTimeoutSeconds: Int = 120

    // Blossom Mirrors
    var blossomMirrors: [String] = []
    var autoMirrorMedia: Bool = false

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
    var blastrRelays: [String] = [
        "wss://relay.primal.net",
        "wss://nos.lol",
        "wss://nostr.mom",
        "wss://relay.btcforplebs.com",
        "wss://nostr-pub.wellorder.net"
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

    // NIP-29: Group Relays
    var groupRelayURLs: [String] = []
    var joinedGroups: [JoinedGroup] = []

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

    // Per-account throttled list (dictionary of account npub: {throttled npub: max visible posts})
    var throttledAccountsPerAccount: [String: [String: Int]] = [:]

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
        case launchAtLogin, autoStartRelay, hasCompletedSetup, hasSeenWelcome, hasAcceptedToS, setupMode, hasCompletedInitialImport, disableMediaCache, autoplayVideos, cacheTTLDays, prefetchProfilePictures, ownerNcryptsec, ownerNsec, showReplies, nwcURI, defaultZapAmount, themeColor, autoLoadNewPosts, showReposts, showBitcoinWallet, cashuMintURL
        case useOLED, textSizeScale, useFeedCompactMode, feedCompactModes, noteDetailCompactView, noteDetailExpandedEngagement, defaultReactionEmoji, appIcon, zapsOnlyMode, disableTabBarAnimation
        case signingMode, nip46BunkerURI, nip46SignerPubkey, nip46RelayURL, nip46Secret, nip46ClientSecretKey, nip46ClientPubkey
        case enableRemotePushServer, enablePushNotifications, notificationPrefsPerAccount
        case macRelayURL
        case privateRelayName, privateRelayDescription, privateRelayIcon
        case chatRelayName, chatRelayDescription, chatRelayIcon, chatRelayWotDepth, chatRelayWotRefreshHours, wotRefreshInterval, chatRelayMinFollowers
        case outboxRelayName, outboxRelayDescription, outboxRelayIcon, outboxMaxEventsPerMinute, outboxMaxConnectionsPerMinute
        case inboxRelayName, inboxRelayDescription, inboxRelayIcon, inboxPullIntervalSeconds
        case importStartDate, importSeedRelaysFile, importSeedRelays, importOwnerNotesFetchTimeoutSeconds, importTaggedNotesFetchTimeoutSeconds
        case blossomMirrors, autoMirrorMedia
        case fipsPublishEnabled, fipsAddressSource, fipsCustomNpub
        case blastrRelaysFile, blastrRelays
        case feedRelays, dmRelays
        case whitelistedNpubs, whitelistedNpubsFile
        case blacklistedNpubs, blacklistedNpubsFile
        case blockedNpubsPerAccount
        case blockedNpubsLastSyncTimestamp
        case throttledAccountsPerAccount
        case activeAccountNpub
        case accountCredentials
        case accountBunkerConfigs
        case accountSigningModes
        case publishRelayListPerAccount
        case backupProvider, backupIntervalHours
        case s3AccessKeyId, s3SecretKey, s3Endpoint, s3Region, s3BucketName
        case groupRelayURLs, joinedGroups
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
        cashuMintURL = try container.decodeIfPresent(String.self, forKey: .cashuMintURL) ?? defaults.cashuMintURL
        // Ignore any saved value: OLED is the only appearance, so an install
        // that had it switched off must not come back looking like the old theme.
        useOLED = true
        textSizeScale = try container.decodeIfPresent(Double.self, forKey: .textSizeScale) ?? defaults.textSizeScale
        useFeedCompactMode = try container.decodeIfPresent(Bool.self, forKey: .useFeedCompactMode) ?? defaults.useFeedCompactMode
        feedCompactModes = try container.decodeIfPresent([String: Bool].self, forKey: .feedCompactModes) ?? defaults.feedCompactModes
        noteDetailCompactView = try container.decodeIfPresent(Bool.self, forKey: .noteDetailCompactView) ?? defaults.noteDetailCompactView
        noteDetailExpandedEngagement = try container.decodeIfPresent(Bool.self, forKey: .noteDetailExpandedEngagement) ?? defaults.noteDetailExpandedEngagement
        defaultReactionEmoji = try container.decodeIfPresent(String.self, forKey: .defaultReactionEmoji) ?? defaults.defaultReactionEmoji
        appIcon = try container.decodeIfPresent(String.self, forKey: .appIcon) ?? defaults.appIcon
        zapsOnlyMode = try container.decodeIfPresent(Bool.self, forKey: .zapsOnlyMode) ?? defaults.zapsOnlyMode
        disableTabBarAnimation = try container.decodeIfPresent(Bool.self, forKey: .disableTabBarAnimation) ?? defaults.disableTabBarAnimation

        signingMode = try container.decodeIfPresent(String.self, forKey: .signingMode) ?? defaults.signingMode
        nip46BunkerURI = try container.decodeIfPresent(String.self, forKey: .nip46BunkerURI) ?? defaults.nip46BunkerURI
        nip46SignerPubkey = try container.decodeIfPresent(String.self, forKey: .nip46SignerPubkey) ?? defaults.nip46SignerPubkey
        nip46RelayURL = try container.decodeIfPresent(String.self, forKey: .nip46RelayURL) ?? defaults.nip46RelayURL
        nip46Secret = try container.decodeIfPresent(String.self, forKey: .nip46Secret) ?? defaults.nip46Secret
        nip46ClientSecretKey = try container.decodeIfPresent(String.self, forKey: .nip46ClientSecretKey) ?? defaults.nip46ClientSecretKey
        nip46ClientPubkey = try container.decodeIfPresent(String.self, forKey: .nip46ClientPubkey) ?? defaults.nip46ClientPubkey

        enableRemotePushServer = try container.decodeIfPresent(Bool.self, forKey: .enableRemotePushServer) ?? defaults.enableRemotePushServer

        // Migrate: if enablePushNotifications was never saved, carry forward enableRemotePushServer
        if let newValue = try container.decodeIfPresent(Bool.self, forKey: .enablePushNotifications) {
            enablePushNotifications = newValue
        } else {
            enablePushNotifications = enableRemotePushServer
        }
        notificationPrefsPerAccount = try container.decodeIfPresent([String: NotificationPreferences].self, forKey: .notificationPrefsPerAccount) ?? defaults.notificationPrefsPerAccount
        
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

        fipsPublishEnabled = try container.decodeIfPresent(Bool.self, forKey: .fipsPublishEnabled) ?? defaults.fipsPublishEnabled
        fipsAddressSource = try container.decodeIfPresent(String.self, forKey: .fipsAddressSource) ?? defaults.fipsAddressSource
        fipsCustomNpub = try container.decodeIfPresent(String.self, forKey: .fipsCustomNpub) ?? defaults.fipsCustomNpub

        blastrRelaysFile = try container.decodeIfPresent(String.self, forKey: .blastrRelaysFile) ?? defaults.blastrRelaysFile
        blastrRelays = try container.decodeIfPresent([String].self, forKey: .blastrRelays) ?? defaults.blastrRelays
        
        feedRelays = try container.decodeIfPresent([String].self, forKey: .feedRelays) ?? defaults.feedRelays
        dmRelays = try container.decodeIfPresent([String].self, forKey: .dmRelays) ?? defaults.dmRelays

        groupRelayURLs = try container.decodeIfPresent([String].self, forKey: .groupRelayURLs) ?? defaults.groupRelayURLs
        joinedGroups = try container.decodeIfPresent([JoinedGroup].self, forKey: .joinedGroups) ?? defaults.joinedGroups
        
        whitelistedNpubs = try container.decodeIfPresent([String].self, forKey: .whitelistedNpubs) ?? defaults.whitelistedNpubs
        whitelistedNpubsFile = try container.decodeIfPresent(String.self, forKey: .whitelistedNpubsFile) ?? defaults.whitelistedNpubsFile
        
        blacklistedNpubs = try container.decodeIfPresent([String].self, forKey: .blacklistedNpubs) ?? defaults.blacklistedNpubs
        blacklistedNpubsFile = try container.decodeIfPresent(String.self, forKey: .blacklistedNpubsFile) ?? defaults.blacklistedNpubsFile
        
        blockedNpubsPerAccount = try container.decodeIfPresent([String: [String]].self, forKey: .blockedNpubsPerAccount) ?? defaults.blockedNpubsPerAccount
        blockedNpubsLastSyncTimestamp = try container.decodeIfPresent([String: Int64].self, forKey: .blockedNpubsLastSyncTimestamp) ?? defaults.blockedNpubsLastSyncTimestamp
        throttledAccountsPerAccount = try container.decodeIfPresent([String: [String: Int]].self, forKey: .throttledAccountsPerAccount) ?? defaults.throttledAccountsPerAccount

        activeAccountNpub = try container.decodeIfPresent(String.self, forKey: .activeAccountNpub) ?? defaults.activeAccountNpub
        accountCredentials = try container.decodeIfPresent([String: String].self, forKey: .accountCredentials) ?? defaults.accountCredentials
        accountBunkerConfigs = try container.decodeIfPresent([String: AccountBunkerConfig].self, forKey: .accountBunkerConfigs) ?? defaults.accountBunkerConfigs
        accountSigningModes = try container.decodeIfPresent([String: String].self, forKey: .accountSigningModes) ?? defaults.accountSigningModes
        publishRelayListPerAccount = try container.decodeIfPresent([String: Bool].self, forKey: .publishRelayListPerAccount) ?? defaults.publishRelayListPerAccount

        // Migration: move global NIP-46 config into per-account dict
        if signingMode == "nip46" && accountBunkerConfigs.isEmpty && !ownerNpub.isEmpty {
            accountBunkerConfigs[ownerNpub] = AccountBunkerConfig(
                bunkerURI: nip46BunkerURI,
                signerPubkey: nip46SignerPubkey,
                relayURL: nip46RelayURL,
                secret: nip46Secret,
                clientSecretKey: nip46ClientSecretKey,
                clientPubkey: nip46ClientPubkey
            )
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
