import Foundation

/// Relay environment configuration — no Combine, no SwiftUI.
/// Portable: same key-value config structure applies on Android
/// (loaded via Properties / BuildConfig instead of .env).
enum RelayConfiguration {

    /// Top-level subdirectories created under the relay data root.
    static let dataSubdirs = ["data", "blossom", "cache", "db"]

    /// Individual database subdirectories under db/.
    static let dbSubdirs = ["private", "chat", "outbox", "inbox", "blossom"]

    /// Create all required relay directories under the given root.
    static func ensureDirectories(under root: URL) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for sub in dataSubdirs {
            try? FileManager.default.createDirectory(
                at: root.appendingPathComponent(sub),
                withIntermediateDirectories: true
            )
        }
        for db in dbSubdirs {
            try? FileManager.default.createDirectory(
                at: root.appendingPathComponent("db/\(db)"),
                withIntermediateDirectories: true
            )
        }
    }

    /// Writes the import seed relay list the relay reads at start. This is the
    /// only writer of that file: the user's own list, exactly as configured.
    /// The Mac relay is deliberately not merged in here — the relay adds it
    /// itself from MAC_RELAY_URL (outbox as a seed relay, /inbox as an inbox
    /// relay). Writers that disagreed about including it used to make the Mac
    /// drop out after a settings save, and a merged list read back by
    /// ConfigService.loadRelayLists leaked the Mac into the user's own list.
    static func writeImportSeedRelays(config: HavenConfig, under root: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(config.importSeedRelays) {
            try? data.write(to: root.appendingPathComponent(config.importSeedRelaysFile))
        }
    }

    /// The Mac relay URL handed to the relay, or "" when there is none. iOS
    /// only: the Mac is the relay being pointed at, never a client of itself.
    /// Keeps a plain ws:// (or http://) Mac as ws:// — a Mac on the LAN often
    /// has no TLS, and the old sync service honoured that; anything else is wss://.
    static func macRelayURL(config: HavenConfig) -> String {
        #if os(iOS)
        let base = config.macRelayNormalizedBase
        guard !base.isEmpty else { return "" }
        let typed = config.macRelayURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let plain = typed.hasPrefix("ws://") || typed.hasPrefix("http://")
        return (plain ? "ws://" : "wss://") + base
        #else
        return ""
        #endif
    }

    /// Result of the relay's one-time full-history copy from the Mac relay and
    /// its missing-events check, as written by haven-go (macsync.go) to
    /// mac_sync_status.json. Every field is optional so a file from an older or
    /// newer relay still decodes.
    struct MacSyncStatus: Decodable {
        var macURL: String?
        var state: String?     // running | done | incomplete | failed
        var method: String?    // negentropy | paged
        var posts: Int?
        var mentions: Int?
        var missing: Int?      // -1: not measurable (paged fallback)
        var error: String?
        var startedAt: Int64?
        var updatedAt: Int64?  // heartbeat while running
        var finishedAt: Int64?

        enum CodingKeys: String, CodingKey {
            case macURL = "mac_url", state, method, posts, mentions, missing, error
            case startedAt = "started_at", updatedAt = "updated_at", finishedAt = "finished_at"
        }
    }

    static func macSyncStatus(under root: URL) -> MacSyncStatus? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("mac_sync_status.json")) else { return nil }
        return try? JSONDecoder().decode(MacSyncStatus.self, from: data)
    }

    /// The union of every account's notification preferences, as event kinds
    /// (see NotificationPolicy.notifyKinds). Read by the relay at start, so a
    /// preference change reaches its catch-up summary on the next relay start;
    /// individual notifications are filtered client-side and change immediately.
    static func notifyKinds(config: HavenConfig) -> [Int] {
        guard config.enablePushNotifications else { return [NotificationPolicy.silentKind] }
        // An account with no stored entry uses NotificationPreferences()'s
        // defaults everywhere else, so it has to count here too — otherwise a
        // user who never opened the notification settings has no entries at all
        // and this would report "notify for nothing".
        var accounts: [String] = [config.ownerNpub]
        accounts.append(contentsOf: config.whitelistedNpubs.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        })
        let prefs = Set(accounts.filter { !$0.isEmpty }).map {
            config.notificationPrefsPerAccount[$0] ?? NotificationPreferences()
        }
        return NotificationPolicy.notifyKinds(
            mentionsOrReplies: prefs.contains { $0.mentions || $0.replies },
            dms: prefs.contains { $0.dms },
            zaps: prefs.contains { $0.zaps },
            reactions: !config.zapsOnlyMode && prefs.contains { $0.reactions },
            reposts: prefs.contains { $0.reposts }
        )
    }

    /// Build the full environment dictionary from a HavenConfig.
    /// `relayDataDir` is passed explicitly so this function has no
    /// dependency on ConfigService.shared.
    static func generateEnvDictionary(config: HavenConfig, relayDataDir: URL) -> [String: String] {
        let cleanNpub = config.ownerNpub.trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { "abcdefghijklmnopqrstuvwxyz0123456789".contains($0.lowercased()) }

        #if os(iOS)
        let enableTLS = "1"
        let relayBindAddress = "127.0.0.1"
        #else
        let enableTLS = "0"
        let relayBindAddress = "0.0.0.0"
        #endif

        return [
            "OWNER_NPUB": cleanNpub,
            "RELAY_URL": config.relayURL,
            "RELAY_PORT": String(config.relayPort),
            "RELAY_BIND_ADDRESS": relayBindAddress,
            "DB_ENGINE": config.dbEngine,
            "LMDB_MAPSIZE": "0",
            "DATABASE_PATH": relayDataDir.appendingPathComponent("data").standardized.path + "/",
            "BLOSSOM_PATH": relayDataDir.appendingPathComponent(config.blossomPath).standardized.path + "/",
            "HAVEN_LOG_LEVEL": config.logLevel,
            "LOG_FORMAT": "$$host $$remote_addr - $$remote_user [$$time_local] \"$$request\" $$status $$body_bytes_sent \"$$http_referer\" \"$$http_user_agent\" \"$$upstream_addr\"",
            "TZ": "UTC",

            // Whitelisted Npubs
            "WHITELISTED_NPUBS_FILE": config.whitelistedNpubsFile,

            // Blacklisted Npubs
            "BLACKLISTED_NPUBS_FILE": config.blacklistedNpubsFile,

            // Private Relay
            "PRIVATE_RELAY_NAME": config.privateRelayName,
            "PRIVATE_RELAY_NPUB": config.ownerNpub,
            "PRIVATE_RELAY_DESCRIPTION": config.privateRelayDescription,
            "PRIVATE_RELAY_ICON": config.privateRelayIcon,
            "PRIVATE_RELAY_EVENT_IP_LIMITER_TOKENS_PER_INTERVAL": "50",
            "PRIVATE_RELAY_EVENT_IP_LIMITER_INTERVAL": "1",
            "PRIVATE_RELAY_EVENT_IP_LIMITER_MAX_TOKENS": "100",
            "PRIVATE_RELAY_ALLOW_EMPTY_FILTERS": "true",
            "PRIVATE_RELAY_ALLOW_COMPLEX_FILTERS": "true",
            "PRIVATE_RELAY_CONNECTION_RATE_LIMITER_TOKENS_PER_INTERVAL": "3",
            "PRIVATE_RELAY_CONNECTION_RATE_LIMITER_INTERVAL": "5",
            "PRIVATE_RELAY_CONNECTION_RATE_LIMITER_MAX_TOKENS": "9",

            // Chat Relay
            "CHAT_RELAY_NAME": config.chatRelayName,
            "CHAT_RELAY_NPUB": config.ownerNpub,
            "CHAT_RELAY_DESCRIPTION": config.chatRelayDescription,
            "CHAT_RELAY_ICON": config.chatRelayIcon,
            "CHAT_RELAY_WOT_DEPTH": String(config.chatRelayWotDepth),
            "CHAT_RELAY_WOT_REFRESH_INTERVAL_HOURS": String(config.chatRelayWotRefreshHours),
            "WOT_REFRESH_INTERVAL": config.wotRefreshInterval,
            "WOT_DEPTH": String(config.chatRelayWotDepth),
            "WOT_MINIMUM_FOLLOWERS": String(config.chatRelayMinFollowers),
            "CHAT_RELAY_MINIMUM_FOLLOWERS": String(config.chatRelayMinFollowers),
            "CHAT_RELAY_EVENT_IP_LIMITER_TOKENS_PER_INTERVAL": "50",
            "CHAT_RELAY_EVENT_IP_LIMITER_INTERVAL": "1",
            "CHAT_RELAY_EVENT_IP_LIMITER_MAX_TOKENS": "100",
            "CHAT_RELAY_ALLOW_EMPTY_FILTERS": "true",
            "CHAT_RELAY_ALLOW_COMPLEX_FILTERS": "false",
            "CHAT_RELAY_CONNECTION_RATE_LIMITER_TOKENS_PER_INTERVAL": "3",
            "CHAT_RELAY_CONNECTION_RATE_LIMITER_INTERVAL": "3",
            "CHAT_RELAY_CONNECTION_RATE_LIMITER_MAX_TOKENS": "9",

            // Outbox Relay
            "OUTBOX_RELAY_NAME": config.outboxRelayName,
            "OUTBOX_RELAY_NPUB": config.ownerNpub,
            "OUTBOX_RELAY_DESCRIPTION": config.outboxRelayDescription,
            "OUTBOX_RELAY_ICON": config.outboxRelayIcon,
            "OUTBOX_MAX_EVENTS_PER_MINUTE": String(config.outboxMaxEventsPerMinute),
            "OUTBOX_MAX_CONNECTIONS_PER_MINUTE": String(config.outboxMaxConnectionsPerMinute),
            "OUTBOX_RELAY_EVENT_IP_LIMITER_TOKENS_PER_INTERVAL": "10",
            "OUTBOX_RELAY_EVENT_IP_LIMITER_INTERVAL": "60",
            "OUTBOX_RELAY_EVENT_IP_LIMITER_MAX_TOKENS": "100",
            "OUTBOX_RELAY_ALLOW_EMPTY_FILTERS": "true",
            "OUTBOX_RELAY_ALLOW_COMPLEX_FILTERS": "false",
            "OUTBOX_RELAY_CONNECTION_RATE_LIMITER_TOKENS_PER_INTERVAL": "3",
            "OUTBOX_RELAY_CONNECTION_RATE_LIMITER_INTERVAL": "1",
            "OUTBOX_RELAY_CONNECTION_RATE_LIMITER_MAX_TOKENS": "9",

            // Inbox Relay
            "INBOX_RELAY_NAME": config.inboxRelayName,
            "INBOX_RELAY_NPUB": config.ownerNpub,
            "INBOX_RELAY_DESCRIPTION": config.inboxRelayDescription,
            "INBOX_RELAY_ICON": config.inboxRelayIcon,
            "INBOX_PULL_INTERVAL_SECONDS": String(config.inboxPullIntervalSeconds),
            "NOTIFY_KINDS": notifyKinds(config: config).map(String.init).joined(separator: ","),
            "INBOX_RELAY_EVENT_IP_LIMITER_TOKENS_PER_INTERVAL": "10",
            "INBOX_RELAY_EVENT_IP_LIMITER_INTERVAL": "1",
            "INBOX_RELAY_EVENT_IP_LIMITER_MAX_TOKENS": "20",
            "INBOX_RELAY_ALLOW_EMPTY_FILTERS": "true",
            "INBOX_RELAY_ALLOW_COMPLEX_FILTERS": "false",
            "INBOX_RELAY_CONNECTION_RATE_LIMITER_TOKENS_PER_INTERVAL": "3",
            "INBOX_RELAY_CONNECTION_RATE_LIMITER_INTERVAL": "1",
            "INBOX_RELAY_CONNECTION_RATE_LIMITER_MAX_TOKENS": "9",

            // Import
            "IMPORT_START_DATE": config.importStartDate,
            "IMPORT_SEED_RELAYS_FILE": config.importSeedRelaysFile,
            "IMPORT_QUERY_INTERVAL_SECONDS": "600",
            "IMPORT_OWNER_NOTES_FETCH_TIMEOUT_SECONDS": "300",
            "IMPORT_TAGGED_NOTES_FETCH_TIMEOUT_SECONDS": "600",

            // DM Relays
            "DM_RELAYS_FILE": "relays_dm.json",

            // Mac relay: synced like any other relay, plus a one-time full-history copy
            "MAC_RELAY_URL": macRelayURL(config: config),

            // Backup
            "BACKUP_PROVIDER": config.backupProvider,
            "BACKUP_INTERVAL_HOURS": String(config.backupIntervalHours),
            "S3_ACCESS_KEY_ID": config.s3AccessKeyId,
            "S3_SECRET_KEY": config.s3SecretKey,
            "S3_ENDPOINT": config.s3Endpoint,
            "S3_REGION": config.s3Region,
            "S3_BUCKET_NAME": config.s3BucketName,

            // Blastr
            "BLASTR_RELAYS_FILE": config.blastrRelaysFile,

            // WoT
            "WOT_FETCH_TIMEOUT_SECONDS": "60",

            // TLS
            "HAVEN_ENABLE_TLS": enableTLS,
        ]
    }

    /// Format an environment dictionary as a .env file string.
    static func formatEnvFile(from envDict: [String: String]) -> String {
        var content = ""
        for (key, value) in envDict.sorted(by: { $0.key < $1.key }) {
            if value.contains(" ") || value.contains("\"") {
                let escapedValue = value.replacingOccurrences(of: "\"", with: "\\\"")
                content += "\(key)=\"\(escapedValue)\"\n"
            } else if value.isEmpty {
                content += "\(key)=\"\"\n"
            } else {
                content += "\(key)=\(value)\n"
            }
        }
        return content
    }
}
