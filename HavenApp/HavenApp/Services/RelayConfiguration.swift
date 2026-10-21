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
        return macRelayURL(config: config, mesh: macMeshRelay)
        #else
        return ""
        #endif
    }

    /// A Mac relay typed as a mesh npub, dialed through FIPS: `url` is the
    /// local `ws://127.0.0.1:<port>/<token>` that reaches it. Set before the
    /// relay starts (RelayProcessManager), nil when there is none or the dial
    /// failed. Never log `url`: the token keeps other apps on the phone out.
    struct MacMeshRelay: Equatable {
        let npub: String
        let url: String
    }

    static var macMeshRelay: MacMeshRelay?

    /// macRelayURL(config:) without the platform check. A mesh npub gives the
    /// dialed address for that same npub, or "" until it has been dialed.
    static func macRelayURL(config: HavenConfig, mesh: MacMeshRelay?) -> String {
        if let npub = config.macRelayMeshNpub {
            guard let mesh, mesh.npub == npub else { return "" }
            return mesh.url
        }
        let base = config.macRelayNormalizedBase
        guard !base.isEmpty else { return "" }
        let typed = config.macRelayURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let plain = typed.hasPrefix("ws://") || typed.hasPrefix("http://")
        return (plain ? "ws://" : "wss://") + base
    }

    /// A copy refreshes its heartbeat every 20 s (macsync.go); one silent for
    /// 90 s died with its relay and is retried on the next start.
    static let macSyncStaleAfter: TimeInterval = 90

    /// The Mac copy is running now, not a "running" left by a relay that died.
    static func macSyncIsLive(_ status: MacSyncStatus?, now: Date) -> Bool {
        guard let status, status.state == "running",
              let beat = status.updatedAt ?? status.startedAt else { return false }
        return now.timeIntervalSince1970 - TimeInterval(beat) <= macSyncStaleAfter
    }

    /// The FIPS engine must stay up in the background: the Mac is reached
    /// over the mesh and its copy is still running.
    static func macSyncNeedsMesh(mesh: MacMeshRelay?, status: MacSyncStatus?, now: Date) -> Bool {
        guard let mesh else { return false }
        return macSyncIsLive(status, now: now) && status?.macURL.map(macRelayBaseForStatus) == macRelayBaseForStatus(mesh.url)
    }

    /// haven-go records the Mac URL with trailing slashes trimmed (macRelayBase).
    private static func macRelayBaseForStatus(_ url: String) -> String {
        var url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while url.hasSuffix("/") { url.removeLast() }
        return url
    }

    /// The status file is for this Mac address (haven-go trims trailing slashes).
    static func macSyncStatus(_ status: MacSyncStatus?, isFor macURL: String) -> Bool {
        guard let recorded = status?.macURL, !macURL.isEmpty else { return false }
        return macRelayBaseForStatus(recorded) == macRelayBaseForStatus(macURL)
    }

    /// What the Mac sync card says once a copy has ended: "Done" with what was
    /// copied, or the reason it stopped. `checked` is the formatted finish time.
    static func macSyncSummary(_ status: MacSyncStatus, checked: String?) -> (headline: String, detail: String) {
        let posts = status.posts ?? 0, mentions = status.mentions ?? 0
        let missing = status.missing ?? 0
        let reason = (status.error ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [String] = []
        parts.append(posts + mentions == 0
            ? "Nothing new to copy: this phone already had it."
            : "Copied \(posts.formatted()) posts and \(mentions.formatted()) mentions.")
        let headline: String
        switch status.state {
        case "done":
            headline = missing < 0 ? "Done (this Mac can't be checked)" : "Done · nothing missing"
        case "incomplete" where reason.isEmpty && missing > 0:
            // Finished cleanly, but a few events the phone won't store remain.
            headline = "Done · \(missing.formatted()) couldn't be copied"
            parts.append("It tries those again once a day.")
        case "incomplete":
            headline = missing > 0 ? "Stopped · \(missing.formatted()) still missing" : "Copy didn't finish"
            if !reason.isEmpty { parts.append("Reason: \(reason).") }
            parts.append("It tries again next time the app starts.")
        case "failed":
            headline = "Couldn't copy from your Mac"
            parts = ["Reason: \(reason.isEmpty ? "none was recorded" : reason).", "It tries again next time the app starts."]
        default:
            headline = status.state ?? "Unknown"
        }
        if missing < 0 {
            parts.append("Your Mac's relay is too old to compare lists, so it was copied page by page.")
        }
        if let checked { parts.append("Checked \(checked).") }
        return (headline, parts.joined(separator: " "))
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
        // With phone notifications off, DMs are still marked: the in-app banner
        // shows them while the app is open (see NotificationPolicy.allowsWithPushOff).
        guard config.enablePushNotifications else {
            return NotificationPolicy.notifyKinds(
                mentionsOrReplies: false,
                dms: prefs.contains { $0.dms },
                zaps: false,
                reactions: false,
                reposts: false
            )
        }
        return NotificationPolicy.notifyKinds(
            mentionsOrReplies: prefs.contains { $0.mentions || $0.replies },
            dms: prefs.contains { $0.dms },
            zaps: prefs.contains { $0.zaps },
            reactions: !config.zapsOnlyMode && prefs.contains { $0.reactions },
            reposts: prefs.contains { $0.reposts }
        )
    }

    /// Everything the relay reads when it starts: its environment plus the
    /// list files written beside it. Two configs with equal inputs run an
    /// identical relay, so this is what decides whether a saved settings
    /// change needs a restart. The blocklist is deliberately absent: it
    /// reaches a running relay live through UpdateBlacklistC.
    struct LaunchInputs: Equatable {
        let env: [String: String]
        let importSeedRelays: [String]
        let blastrRelays: [String]
        let dmRelays: [String]
        let whitelistedNpubs: [String]
    }

    static func launchInputs(config: HavenConfig, relayDataDir: URL) -> LaunchInputs {
        LaunchInputs(
            env: generateEnvDictionary(config: config, relayDataDir: relayDataDir),
            importSeedRelays: config.importSeedRelays,
            blastrRelays: blastrRelays(config: config, mesh: {
                #if os(iOS)
                return macMeshRelay
                #else
                return nil
                #endif
            }()),
            dmRelays: config.dmRelays,
            whitelistedNpubs: config.whitelistedNpubs
        )
    }

    /// A mesh dial's local address (`ws://127.0.0.1:<port>/<hex token>`,
    /// see MacMeshRelay). It lives for one app session: the next dial gets a
    /// new port and token, so a saved copy is a dead relay.
    static func isMeshAddress(_ relay: String) -> Bool {
        guard let url = URL(string: relay.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "ws", url.host == "127.0.0.1", url.port != nil else { return false }
        let parts = url.path.split(separator: "/")
        guard parts.count == 1, let token = parts.first, token.count >= 16 else { return false }
        return token.allSatisfy { $0.isHexDigit }
    }

    /// `relays` without saved mesh addresses. relays_blastr.json carries this
    /// session's Mac address for the relay, and ConfigService read it back as
    /// one of the owner's own broadcast relays: one more dead entry per launch
    /// (eight on the 12 mini by 2026-10-21), and every post said no relay had
    /// confirmed it.
    static func droppingMeshAddresses(_ relays: [String]) -> [String] {
        relays.filter { !isMeshAddress($0) }
    }

    /// The broadcast list the relay writes to: a Mac on the mesh goes first,
    /// as a Mac with a URL does (HavenConfig.activeBlastrRelays), so the
    /// phone's notes reach it.
    static func blastrRelays(config: HavenConfig, mesh: MacMeshRelay?) -> [String] {
        var relays = droppingMeshAddresses(config.activeBlastrRelays)
        if let npub = config.macRelayMeshNpub, let mesh, mesh.npub == npub, !relays.contains(mesh.url) {
            relays.insert(mesh.url, at: 0)
        }
        return relays
    }

    /// The Go relay's soft memory limit on a phone, from its RAM: a quarter,
    /// between 256 MiB and 3 GiB. Go's flat 256 MiB phone default
    /// (haven-go config.go) is a limit a populated vault's live heap reaches,
    /// and then the collector runs back to back: on Logen's iPhone 18 Pro
    /// (2026-10-21, build 39) 69% of all CPU samples were Go GC mark workers
    /// with almost no other Go work, ~420% CPU, thermal state Serious.
    static func phoneGoMemLimitMB(physicalMemory: UInt64) -> Int {
        let quarter = Int(physicalMemory / 4 / (1 << 20))
        return min(max(quarter, 256), 3072)
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
        // Haven's mesh door: mesh visitors (iPhone kiosk, the Mac's
        // strangers) go here, never to the relay port. It listens only
        // while the host has SetMeshServingC(1).
        let meshPlainPort = String(config.meshPlainPort)

        var env: [String: String] = [
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
            "HAVEN_MESH_PLAIN_PORT": meshPlainPort,
        ]
        #if os(iOS)
        env["GO_MEM_LIMIT_MB"] = String(phoneGoMemLimitMB(physicalMemory: ProcessInfo.processInfo.physicalMemory))
        #endif
        return env
    }

    /// Relays the app sends an event it just posted to, alongside handing it
    /// to this device's relay.
    ///
    /// The local relay blasts what it stores, but only once, from a background
    /// goroutine with nothing queued: if iOS suspends the app before that
    /// finishes, the event never leaves the vault. On 2026-10-04 two replies
    /// reached the vault and the replied-to author's inbox and nothing else,
    /// so they never showed on another device's feed. Replaceable events
    /// (profiles, relay lists) never trigger that blast at all. So every event
    /// goes out from the app as well; relays drop the duplicate by id.
    ///
    /// A kind 10050 also goes to the DM relays it names, where senders look
    /// for it.
    static func directBroadcastRelays(kind: Int, tags: [[String]], blastrRelays: [String]) -> [String] {
        var relays = blastrRelays.isEmpty ? fallbackBroadcastRelays : blastrRelays
        if kind == 10050 {
            for tag in tags where tag.count >= 2 && tag[0] == "relay" && !relays.contains(tag[1]) {
                relays.append(tag[1])
            }
        }
        return relays
    }

    /// The NIP-65 relay list for a new account whose relay is this device.
    ///
    /// The device's own relay can't be reached from outside, so it is not
    /// advertised; the public relays every event is broadcast to are, which is
    /// where other clients will actually find this account's notes. No marker,
    /// so each is both read and write. Loopback and non-wss entries are left out.
    static func newAccountRelayListTags(broadcastRelays: [String]) -> [[String]] {
        var seen = Set<String>()
        var tags: [[String]] = []
        for relay in broadcastRelays {
            let url = relay.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsed = URL(string: url), parsed.scheme == "wss",
                  let host = parsed.host?.lowercased(),
                  host != "localhost", host != "127.0.0.1", host != "0.0.0.0", host != "::1",
                  seen.insert(url).inserted else { continue }
            tags.append(["r", url])
        }
        return tags
    }

    /// Where events go when no blastr relays are configured.
    static let fallbackBroadcastRelays = HavenConfig.fallbackWriteRelays

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

/// Turns the per-relay `OK` replies for one broadcast into a single answer:
/// accepted as soon as one relay takes the event, refused only once every
/// relay has answered without taking it (a refusal, a timeout, or no
/// connection). Used to show "Posted" only when the post really landed.
struct BroadcastTally {
    enum Outcome: Equatable { case accepted, refused }

    let relayCount: Int
    private var answered: Set<String> = []
    private(set) var outcome: Outcome?

    init(relayCount: Int) {
        self.relayCount = relayCount
        if relayCount == 0 { outcome = .refused }
    }

    /// Records one relay's answer and returns the outcome the first time it
    /// is decided, `nil` otherwise. Later answers never change it.
    mutating func record(relay: String, success: Bool, message: String) -> Outcome? {
        guard outcome == nil, answered.insert(relay).inserted else { return nil }
        // NIP-01: a relay that already holds the event may say so with
        // ok=false. The event is there, which is what the user cares about.
        if success || message.lowercased().hasPrefix("duplicate:") {
            outcome = .accepted
            return .accepted
        }
        if answered.count >= relayCount {
            outcome = .refused
            return .refused
        }
        return nil
    }
}
