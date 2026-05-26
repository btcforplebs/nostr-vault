import Foundation

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
    var disableMediaCache: Bool = false
    var allowNetworkAccess: Bool = false // Bind to 0.0.0.0 instead of 127.0.0.1 (for Tailscale, etc.)
    var ownerNcryptsec: String = "" // NIP-49 encrypted private key
    var ownerNsec: String = "" // Deprecated: kept for migration purposes only
    var showReplies: Bool = true // Added to toggle visibility of replies in feed
    var themeColor: String = "orange"
    var autoLoadNewPosts: Bool = false
    var showReposts: Bool = true
    
    // Mac Relay Sync (iOS only)
    var macRelayURL: String = "" // wss:// URL to a remote Mac Haven relay to sync missed notes
    
    // NWC (Nostr Wallet Connect)
    var nwcURI: String = ""
    var defaultZapAmount: Int = 1000 // In millisats (default 1 sat)

    // Bitcoin Taproot wallet (derived from Nostr keypair via BIP-341)
    var showBitcoinWallet: Bool = false

    // Push Notifications (optional Mac Mini server)
    var pushServerURL: String = "" // e.g., http://192.168.1.100:8000 or Tailscale IP
    var enableRemotePushServer: Bool = false
    
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
    var inboxPullIntervalSeconds: Int = 60
    
    // Import
    var importStartDate: String = "2023-01-01"
    var importSeedRelaysFile: String = "relays_import.json"
    var importSeedRelays: [String] = [
        "wss://relay.damus.io",
        "wss://relay.primal.net",
        "wss://relay.snort.social",
        "wss://relay.nos.social"
    ]
    var importOwnerNotesFetchTimeoutSeconds: Int = 60
    var importTaggedNotesFetchTimeoutSeconds: Int = 120

    // Blossom Mirrors
    var blossomMirrors: [String] = []
    var autoMirrorMedia: Bool = false

    // Blastr
    var blastrRelaysFile: String = "relays_blastr.json"
    var blastrRelays: [String] = [
        "wss://relay.damus.io",
        "wss://relay.primal.net",
        "wss://nos.lol",
        "wss://nostr.wine"
    ]
    
    // Feed Reading
    var feedRelays: [String] = [
        "wss://relay.damus.io",
        "wss://relay.primal.net",
        "wss://nos.lol"
    ]

    // NIP-17: DM Relays (kind 10050)
    var dmRelays: [String] = [
        "wss://relay.damus.io",
        "wss://relay.primal.net",
        "wss://nos.lol"
    ]

    // Whitelisted Npubs (multi-npub support)
    var whitelistedNpubs: [String] = []
    var whitelistedNpubsFile: String = "whitelisted_npubs.json"
    
    // Active account for UI browsing (empty = use ownerNpub)
    var activeAccountNpub: String = ""
    
    // Per-account encrypted private keys: [npub: ncryptsec]
    // The owner key is stored separately (ownerNcryptsec). This dict is only for whitelisted accounts.
    var accountCredentials: [String: String] = [:]
    
    // Blacklisted Npubs
    var blacklistedNpubs: [String] = []
    var blacklistedNpubsFile: String = "blacklisted_npubs.json"

    // Per-account blocked list (dictionary of npub: [blocked npubs])
    var blockedNpubsPerAccount: [String: [String]] = [:]
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
        case launchAtLogin, autoStartRelay, hasCompletedSetup, hasSeenWelcome, hasAcceptedToS, disableMediaCache, allowNetworkAccess, ownerNcryptsec, ownerNsec, showReplies, nwcURI, defaultZapAmount, themeColor, autoLoadNewPosts, showReposts, showBitcoinWallet
        case pushServerURL, enableRemotePushServer
        case macRelayURL
        case privateRelayName, privateRelayDescription, privateRelayIcon
        case chatRelayName, chatRelayDescription, chatRelayIcon, chatRelayWotDepth, chatRelayWotRefreshHours, wotRefreshInterval, chatRelayMinFollowers
        case outboxRelayName, outboxRelayDescription, outboxRelayIcon, outboxMaxEventsPerMinute, outboxMaxConnectionsPerMinute
        case inboxRelayName, inboxRelayDescription, inboxRelayIcon, inboxPullIntervalSeconds
        case importStartDate, importSeedRelaysFile, importSeedRelays, importOwnerNotesFetchTimeoutSeconds, importTaggedNotesFetchTimeoutSeconds
        case blossomMirrors, autoMirrorMedia
        case blastrRelaysFile, blastrRelays
        case feedRelays
        case whitelistedNpubs, whitelistedNpubsFile
        case blacklistedNpubs, blacklistedNpubsFile
        case blockedNpubsPerAccount
        case blockedNpubsLastSyncTimestamp
        case activeAccountNpub
        case accountCredentials
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
        disableMediaCache = try container.decodeIfPresent(Bool.self, forKey: .disableMediaCache) ?? defaults.disableMediaCache
        allowNetworkAccess = try container.decodeIfPresent(Bool.self, forKey: .allowNetworkAccess) ?? defaults.allowNetworkAccess
        ownerNcryptsec = try container.decodeIfPresent(String.self, forKey: .ownerNcryptsec) ?? defaults.ownerNcryptsec
        ownerNsec = try container.decodeIfPresent(String.self, forKey: .ownerNsec) ?? defaults.ownerNsec
        showReplies = try container.decodeIfPresent(Bool.self, forKey: .showReplies) ?? defaults.showReplies
        nwcURI = try container.decodeIfPresent(String.self, forKey: .nwcURI) ?? defaults.nwcURI
        macRelayURL = try container.decodeIfPresent(String.self, forKey: .macRelayURL) ?? defaults.macRelayURL
        defaultZapAmount = try container.decodeIfPresent(Int.self, forKey: .defaultZapAmount) ?? defaults.defaultZapAmount
        themeColor = try container.decodeIfPresent(String.self, forKey: .themeColor) ?? defaults.themeColor
        autoLoadNewPosts = try container.decodeIfPresent(Bool.self, forKey: .autoLoadNewPosts) ?? defaults.autoLoadNewPosts
        showReposts = try container.decodeIfPresent(Bool.self, forKey: .showReposts) ?? defaults.showReposts
        showBitcoinWallet = try container.decodeIfPresent(Bool.self, forKey: .showBitcoinWallet) ?? defaults.showBitcoinWallet

        pushServerURL = try container.decodeIfPresent(String.self, forKey: .pushServerURL) ?? defaults.pushServerURL
        enableRemotePushServer = try container.decodeIfPresent(Bool.self, forKey: .enableRemotePushServer) ?? defaults.enableRemotePushServer
        
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
        inboxPullIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .inboxPullIntervalSeconds) ?? defaults.inboxPullIntervalSeconds
        
        importStartDate = try container.decodeIfPresent(String.self, forKey: .importStartDate) ?? defaults.importStartDate
        importSeedRelaysFile = try container.decodeIfPresent(String.self, forKey: .importSeedRelaysFile) ?? defaults.importSeedRelaysFile
        importSeedRelays = try container.decodeIfPresent([String].self, forKey: .importSeedRelays) ?? defaults.importSeedRelays
        importOwnerNotesFetchTimeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .importOwnerNotesFetchTimeoutSeconds) ?? defaults.importOwnerNotesFetchTimeoutSeconds
        importTaggedNotesFetchTimeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .importTaggedNotesFetchTimeoutSeconds) ?? defaults.importTaggedNotesFetchTimeoutSeconds

        blossomMirrors = try container.decodeIfPresent([String].self, forKey: .blossomMirrors) ?? defaults.blossomMirrors
        autoMirrorMedia = try container.decodeIfPresent(Bool.self, forKey: .autoMirrorMedia) ?? defaults.autoMirrorMedia

        blastrRelaysFile = try container.decodeIfPresent(String.self, forKey: .blastrRelaysFile) ?? defaults.blastrRelaysFile
        blastrRelays = try container.decodeIfPresent([String].self, forKey: .blastrRelays) ?? defaults.blastrRelays
        
        feedRelays = try container.decodeIfPresent([String].self, forKey: .feedRelays) ?? defaults.feedRelays
        
        whitelistedNpubs = try container.decodeIfPresent([String].self, forKey: .whitelistedNpubs) ?? defaults.whitelistedNpubs
        whitelistedNpubsFile = try container.decodeIfPresent(String.self, forKey: .whitelistedNpubsFile) ?? defaults.whitelistedNpubsFile
        
        blacklistedNpubs = try container.decodeIfPresent([String].self, forKey: .blacklistedNpubs) ?? defaults.blacklistedNpubs
        blacklistedNpubsFile = try container.decodeIfPresent(String.self, forKey: .blacklistedNpubsFile) ?? defaults.blacklistedNpubsFile
        
        blockedNpubsPerAccount = try container.decodeIfPresent([String: [String]].self, forKey: .blockedNpubsPerAccount) ?? defaults.blockedNpubsPerAccount
        blockedNpubsLastSyncTimestamp = try container.decodeIfPresent([String: Int64].self, forKey: .blockedNpubsLastSyncTimestamp) ?? defaults.blockedNpubsLastSyncTimestamp
        
        activeAccountNpub = try container.decodeIfPresent(String.self, forKey: .activeAccountNpub) ?? defaults.activeAccountNpub
        accountCredentials = try container.decodeIfPresent([String: String].self, forKey: .accountCredentials) ?? defaults.accountCredentials

        backupProvider = try container.decodeIfPresent(String.self, forKey: .backupProvider) ?? defaults.backupProvider
        backupIntervalHours = try container.decodeIfPresent(Int.self, forKey: .backupIntervalHours) ?? defaults.backupIntervalHours

        s3AccessKeyId = try container.decodeIfPresent(String.self, forKey: .s3AccessKeyId) ?? defaults.s3AccessKeyId
        s3SecretKey = try container.decodeIfPresent(String.self, forKey: .s3SecretKey) ?? defaults.s3SecretKey
        s3Endpoint = try container.decodeIfPresent(String.self, forKey: .s3Endpoint) ?? defaults.s3Endpoint
        s3Region = try container.decodeIfPresent(String.self, forKey: .s3Region) ?? defaults.s3Region
        s3BucketName = try container.decodeIfPresent(String.self, forKey: .s3BucketName) ?? defaults.s3BucketName
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

    /// Active Blossom mirrors, including the automatically applied Mac relay Blossom server if configured.
    var activeBlossomMirrors: [String] {
        var mirrors = blossomMirrors
        let macHttps = macRelayHttpsURL
        if !macHttps.isEmpty {
            if !mirrors.contains(macHttps) {
                mirrors.insert(macHttps, at: 0)
            }
        }
        return mirrors
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
            // Use wss:// (secure WebSocket) for local HTTPS relay server on iOS
            return "wss://127.0.0.1:\(relayPort)"
            #endif
        } else {
            return "wss://\(sanitizedRelayURL)"
        }
    }

    /// Returns the appropriate Web/Blossom URL (https:// for both local and remote)
    var webURL: String {
        if isLocal {
            #if os(macOS)
            return "http://127.0.0.1:\(relayPort)"
            #else
            // Use https:// for local relay server (self-signed cert)
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
