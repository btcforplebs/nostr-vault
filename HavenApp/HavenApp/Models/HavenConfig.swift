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
    var disableMediaCache: Bool = false
    
    // Private Relay
    var privateRelayName: String = "Haven Private"
    var privateRelayDescription: String = "My private Haven relay"
    var privateRelayIcon: String = ""
    
    // Chat Relay
    var chatRelayName: String = "Haven Chat"
    var chatRelayDescription: String = "Private chat relay"
    var chatRelayIcon: String = ""
    var chatRelayWotDepth: Int = 3
    var chatRelayWotRefreshHours: Int = 24
    var chatRelayMinFollowers: Int = 3
    
    // Outbox Relay (Public)
    var outboxRelayName: String = "Haven Public"
    var outboxRelayDescription: String = "Public outbox relay"
    var outboxRelayIcon: String = ""
    var outboxMaxEventsPerMinute: Int = 100
    var outboxMaxConnectionsPerMinute: Int = 5
    
    // Inbox Relay
    var inboxRelayName: String = "Haven Inbox"
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
    
    // Blastr
    var blastrRelaysFile: String = "relays_blastr.json"
    var blastrRelays: [String] = [
        "wss://relay.damus.io",
        "wss://relay.primal.net",
        "wss://nos.lol",
        "wss://nostr.wine"
    ]
    
    // Backup
    var backupProvider: String = "none" // none, s3, aws, gcp
    var backupIntervalHours: Int = 24
    
    // S3
    var s3AccessKeyId: String = ""
    var s3SecretKey: String = ""
    var s3Endpoint: String = ""
    var s3Region: String = ""
    var s3BucketName: String = ""
    
    // AWS
    var awsAccessKeyId: String = ""
    var awsSecretAccessKey: String = ""
    var awsRegion: String = ""
    var awsBucket: String = ""
    
    // GCP
    var gcpBucketName: String = ""
    var gcpCredentialsPath: String = ""
    
    static let `default` = HavenConfig()
    
    // MARK: - Decodable implementation to handle migrations
    
    enum CodingKeys: String, CodingKey {
        case ownerNpub, relayURL, relayPort, dbEngine, blossomPath, logLevel
        case launchAtLogin, autoStartRelay, hasCompletedSetup, hasSeenWelcome, disableMediaCache
        case privateRelayName, privateRelayDescription, privateRelayIcon
        case chatRelayName, chatRelayDescription, chatRelayIcon, chatRelayWotDepth, chatRelayWotRefreshHours, chatRelayMinFollowers
        case outboxRelayName, outboxRelayDescription, outboxRelayIcon, outboxMaxEventsPerMinute, outboxMaxConnectionsPerMinute
        case inboxRelayName, inboxRelayDescription, inboxRelayIcon, inboxPullIntervalSeconds
        case importStartDate, importSeedRelaysFile, importSeedRelays, importOwnerNotesFetchTimeoutSeconds, importTaggedNotesFetchTimeoutSeconds
        case blastrRelaysFile, blastrRelays
        case backupProvider, backupIntervalHours
        case s3AccessKeyId, s3SecretKey, s3Endpoint, s3Region, s3BucketName
        case awsAccessKeyId, awsSecretAccessKey, awsRegion, awsBucket
        case gcpBucketName, gcpCredentialsPath
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
        disableMediaCache = try container.decodeIfPresent(Bool.self, forKey: .disableMediaCache) ?? defaults.disableMediaCache
        
        privateRelayName = try container.decodeIfPresent(String.self, forKey: .privateRelayName) ?? defaults.privateRelayName
        privateRelayDescription = try container.decodeIfPresent(String.self, forKey: .privateRelayDescription) ?? defaults.privateRelayDescription
        privateRelayIcon = try container.decodeIfPresent(String.self, forKey: .privateRelayIcon) ?? defaults.privateRelayIcon
        
        chatRelayName = try container.decodeIfPresent(String.self, forKey: .chatRelayName) ?? defaults.chatRelayName
        chatRelayDescription = try container.decodeIfPresent(String.self, forKey: .chatRelayDescription) ?? defaults.chatRelayDescription
        chatRelayIcon = try container.decodeIfPresent(String.self, forKey: .chatRelayIcon) ?? defaults.chatRelayIcon
        chatRelayWotDepth = try container.decodeIfPresent(Int.self, forKey: .chatRelayWotDepth) ?? defaults.chatRelayWotDepth
        chatRelayWotRefreshHours = try container.decodeIfPresent(Int.self, forKey: .chatRelayWotRefreshHours) ?? defaults.chatRelayWotRefreshHours
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
        
        blastrRelaysFile = try container.decodeIfPresent(String.self, forKey: .blastrRelaysFile) ?? defaults.blastrRelaysFile
        blastrRelays = try container.decodeIfPresent([String].self, forKey: .blastrRelays) ?? defaults.blastrRelays
        
        backupProvider = try container.decodeIfPresent(String.self, forKey: .backupProvider) ?? defaults.backupProvider
        backupIntervalHours = try container.decodeIfPresent(Int.self, forKey: .backupIntervalHours) ?? defaults.backupIntervalHours
        
        s3AccessKeyId = try container.decodeIfPresent(String.self, forKey: .s3AccessKeyId) ?? defaults.s3AccessKeyId
        s3SecretKey = try container.decodeIfPresent(String.self, forKey: .s3SecretKey) ?? defaults.s3SecretKey
        s3Endpoint = try container.decodeIfPresent(String.self, forKey: .s3Endpoint) ?? defaults.s3Endpoint
        s3Region = try container.decodeIfPresent(String.self, forKey: .s3Region) ?? defaults.s3Region
        s3BucketName = try container.decodeIfPresent(String.self, forKey: .s3BucketName) ?? defaults.s3BucketName
        
        awsAccessKeyId = try container.decodeIfPresent(String.self, forKey: .awsAccessKeyId) ?? defaults.awsAccessKeyId
        awsSecretAccessKey = try container.decodeIfPresent(String.self, forKey: .awsSecretAccessKey) ?? defaults.awsSecretAccessKey
        awsRegion = try container.decodeIfPresent(String.self, forKey: .awsRegion) ?? defaults.awsRegion
        awsBucket = try container.decodeIfPresent(String.self, forKey: .awsBucket) ?? defaults.awsBucket
        
        gcpBucketName = try container.decodeIfPresent(String.self, forKey: .gcpBucketName) ?? defaults.gcpBucketName
        gcpCredentialsPath = try container.decodeIfPresent(String.self, forKey: .gcpCredentialsPath) ?? defaults.gcpCredentialsPath
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
            // Force 127.0.0.1 for local connections
            return "ws://127.0.0.1:\(relayPort)"
        } else {
            return "wss://\(sanitizedRelayURL)"
        }
    }
    
    /// Returns the appropriate Web/Blossom URL (http:// for local, https:// for remote)
    var webURL: String {
        if isLocal {
            // Force 127.0.0.1 for local connections
            return "http://127.0.0.1:\(relayPort)"
        } else {
            return "https://\(sanitizedRelayURL)"
        }
    }
}
