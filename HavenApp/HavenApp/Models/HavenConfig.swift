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
