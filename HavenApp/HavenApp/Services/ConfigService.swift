import SwiftUI
import Foundation
#if canImport(ServiceManagement)
import ServiceManagement
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Manages Haven configuration persistence
@MainActor
class ConfigService: ObservableObject {
    static let shared = ConfigService()
    @Published var config: HavenConfig
    @Published var isSwitchingAccount: Bool = false
    /// Explicit @Published hex pubkey for the active account. Computed properties
    /// on ObservableObject don't reliably trigger SwiftUI re-renders in all
    /// hosting contexts (e.g. macOS MenuBarExtra). This property is updated
    /// whenever the active account changes.
    @Published private(set) var activeAccountHexPubkey: String = ""
    
    // Config stored in App Support (standard macOS location for app preferences/state)
    private let configURL: URL
    // Relay data stored in separate directory to avoid conflicts with source code
    let relayDataDir: URL
    
    init() {
        // Store config in Application Support
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            fatalError("Application Support directory unavailable")
        }
        let havenAppSupport = appSupport.appendingPathComponent("Haven", isDirectory: true)
        
        // Create config directory if needed
        try? FileManager.default.createDirectory(at: havenAppSupport, withIntermediateDirectories: true)
        
        configURL = havenAppSupport.appendingPathComponent("config.json")
        
        // Create databases directory in Application Support (Sandboxed)
        relayDataDir = havenAppSupport.appendingPathComponent("haven_database", isDirectory: true)
        
        var loadedSuccessfully = false
        
        // Load existing config or create default
        if let data = try? Data(contentsOf: configURL) {
            do {
                let loaded = try JSONDecoder().decode(HavenConfig.self, from: data)
                config = loaded
                loadedSuccessfully = true
                #if DEBUG
                print("ConfigService: Successfully loaded configuration from disk")
                #endif

                // Ensure defaults are applied for empty arrays
                if config.importSeedRelays.isEmpty {
                    config.importSeedRelays = HavenConfig.default.importSeedRelays
                }
                if config.blastrRelays.isEmpty {
                    config.blastrRelays = HavenConfig.default.blastrRelays
                }
                if config.blossomMirrors.isEmpty {
                    config.blossomMirrors = HavenConfig.default.blossomMirrors
                    #if DEBUG
                    print("ConfigService: Applied default Blossom mirrors: \(config.blossomMirrors)")
                    #endif
                } else {
                    #if DEBUG
                    print("ConfigService: Loaded \(config.blossomMirrors.count) Blossom mirrors: \(config.blossomMirrors)")
                    #endif
                }
            } catch {
                RelayProcessManager.shared.addLog("Error decoding configuration: \(error.localizedDescription)", level: "ERROR")
                config = HavenConfig.default
            }
        } else {
            #if DEBUG
            print("ConfigService: No config.json found at \(configURL.path), using defaults")
            #endif
            config = HavenConfig.default
        }
        
        // Setup Recovery: If hasCompletedSetup is false but .env exists, then setup was actually done
        var recovered = false
        let envURL = relayDataDir.appendingPathComponent(".env")
        if !config.hasCompletedSetup && FileManager.default.fileExists(atPath: envURL.path) {
            #if DEBUG
            print("ConfigService: .env detected but hasCompletedSetup is false. Auto-recovering settings.")
            #endif
            recoverFromEnv()
            recovered = true
        }
        
        loadRelayLists()
        
        // Ensure ownerNpub is sanitized (remove invisible junk characters like non-breaking spaces)
        config.ownerNpub = config.ownerNpub.trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { "abcdefghijklmnopqrstuvwxyz0123456789".contains($0.lowercased()) }
        
        // Only save if we loaded successfully, recovered, or if it's a fresh install (no .env)
        // This prevents overwriting a "broken" config.json with empty defaults on every startup
        if loadedSuccessfully || recovered || !FileManager.default.fileExists(atPath: envURL.path) {
            save()
        }

        // Sync relay info to MediaCacheService for thread-safe access
        MediaCacheService.shared.updateLocalHost(config.sanitizedRelayURL)
        MediaCacheService.shared.updateBlossomDirectory(relayDataDir.appendingPathComponent(config.blossomPath))

        // Seed the @Published hex pubkey from the loaded config
        refreshActiveAccountHex()
    }
    
    func reload() {
        if let data = try? Data(contentsOf: configURL) {
            do {
                let loaded = try JSONDecoder().decode(HavenConfig.self, from: data)
                self.config = loaded
                #if DEBUG
                print("ConfigService: Successfully reloaded configuration from disk")
                #endif

                // Ensure defaults are applied for empty arrays
                if config.importSeedRelays.isEmpty {
                    config.importSeedRelays = HavenConfig.default.importSeedRelays
                }
                if config.blastrRelays.isEmpty {
                    config.blastrRelays = HavenConfig.default.blastrRelays
                }
                if config.blossomMirrors.isEmpty {
                    config.blossomMirrors = HavenConfig.default.blossomMirrors
                    #if DEBUG
                    print("ConfigService: Applied default Blossom mirrors on reload: \(config.blossomMirrors)")
                    #endif
                } else {
                    #if DEBUG
                    print("ConfigService: Reloaded \(config.blossomMirrors.count) Blossom mirrors: \(config.blossomMirrors)")
                    #endif
                }

                // Reload lists
                loadRelayLists()

                // Sync relay info
                MediaCacheService.shared.updateLocalHost(config.sanitizedRelayURL)
                MediaCacheService.shared.updateBlossomDirectory(self.relayDataDir.appendingPathComponent(loaded.blossomPath))

                refreshActiveAccountHex()
            } catch {
                RelayProcessManager.shared.addLog("Error reloading configuration: \(error.localizedDescription)", level: "ERROR")
            }
        }
    }
    
    private func loadRelayLists() {
        // Use separate data dir
        let importURL = relayDataDir.appendingPathComponent(config.importSeedRelaysFile)
        if let data = try? Data(contentsOf: importURL),
           let list = try? JSONDecoder().decode([String].self, from: data),
           !list.isEmpty {
            config.importSeedRelays = list
        }
        // If file doesn't exist or is empty, keep the defaults from HavenConfig

        let blastrURL = relayDataDir.appendingPathComponent(config.blastrRelaysFile)
        if let data = try? Data(contentsOf: blastrURL),
           let list = try? JSONDecoder().decode([String].self, from: data),
           !list.isEmpty {
            config.blastrRelays = list
        }
        // If file doesn't exist or is empty, keep the defaults from HavenConfig

        // Load whitelisted npubs
        let npubsURL = relayDataDir.appendingPathComponent(config.whitelistedNpubsFile)
        if let data = try? Data(contentsOf: npubsURL),
           let list = try? JSONDecoder().decode([String].self, from: data) {
            config.whitelistedNpubs = list
        }
        
        // Load blacklisted npubs
        let blacklistedURL = relayDataDir.appendingPathComponent(config.blacklistedNpubsFile)
        if let data = try? Data(contentsOf: blacklistedURL),
           let list = try? JSONDecoder().decode([String].self, from: data) {
            config.blacklistedNpubs = list
        }
    }
    
    func save() {
        // Ensure ownerNpub is sanitized (remove invisible junk characters like non-breaking spaces)
        config.ownerNpub = config.ownerNpub.trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { "abcdefghijklmnopqrstuvwxyz0123456789".contains($0.lowercased()) }

        do {
            let data = try JSONEncoder().encode(config)
            try data.write(to: configURL)

            #if DEBUG
            print("ConfigService: Saved config with \(config.blossomMirrors.count) mirrors: \(config.blossomMirrors)")
            #endif

            saveRelayLists()
            
            // Update launch at login if changed
            updateLaunchAtLogin()
        } catch {
            RelayProcessManager.shared.addLog("Failed to save config: \(error.localizedDescription)", level: "ERROR")
        }
    }
    
    private func saveRelayLists() {
        // Sanitize relayURL: strip schemes and trailing slashes, but preserve the value
        var trimmedURL = config.relayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let schemes = ["wss://", "ws://", "https://", "http://"]
        for scheme in schemes {
            if trimmedURL.lowercased().hasPrefix(scheme) {
                trimmedURL = String(trimmedURL.dropFirst(scheme.count))
            }
        }
        while trimmedURL.hasSuffix("/") {
            trimmedURL = String(trimmedURL.dropLast())
        }
        config.relayURL = trimmedURL

        // Sync relay info to MediaCacheService
        MediaCacheService.shared.updateLocalHost(config.sanitizedRelayURL)
        MediaCacheService.shared.updateBlossomDirectory(relayDataDir.appendingPathComponent(config.blossomPath))

        // Ensure data dir exists
        try? FileManager.default.createDirectory(at: relayDataDir, withIntermediateDirectories: true)
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(config) {
            try? data.write(to: configURL) // Save main config again just in case
        }
        
        if !config.importSeedRelays.isEmpty {
            let importURL = relayDataDir.appendingPathComponent(config.importSeedRelaysFile)
            if let data = try? encoder.encode(config.importSeedRelays) {
                try? data.write(to: importURL)
            }
        } else {
             // If empty, write empty array to clear previous contents
             let importURL = relayDataDir.appendingPathComponent(config.importSeedRelaysFile)
             if let data = try? encoder.encode([String]()) {
                 try? data.write(to: importURL)
             }
        }
        
        writeStarterPackSeeds(encoder: encoder)

        if !config.blastrRelays.isEmpty {
            let blastrURL = relayDataDir.appendingPathComponent(config.blastrRelaysFile)
            if let data = try? encoder.encode(config.blastrRelays) {
                try? data.write(to: blastrURL)
            }
        } else {
             let blastrURL = relayDataDir.appendingPathComponent(config.blastrRelaysFile)
             if let data = try? encoder.encode([String]()) {
                 try? data.write(to: blastrURL)
             }
        }

        // Save whitelisted npubs
        if !config.whitelistedNpubs.isEmpty {
            let npubsURL = relayDataDir.appendingPathComponent(config.whitelistedNpubsFile)
            if let data = try? encoder.encode(config.whitelistedNpubs) {
                try? data.write(to: npubsURL)
            }
        }
        
        // Save blacklisted npubs
        if !config.blacklistedNpubs.isEmpty {
            let blacklistedURL = relayDataDir.appendingPathComponent(config.blacklistedNpubsFile)
            if let data = try? encoder.encode(config.blacklistedNpubs) {
                try? data.write(to: blacklistedURL)
            }
        }
    }
    
    private func updateLaunchAtLogin() {
        #if canImport(ServiceManagement)
        if #available(macOS 13.0, *) {
            do {
                if config.launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                // Expected to fail in development without proper code signing
            }
        }
        #endif
    }
    /// Create the required files for Haven to run (.env, relay JSON files)
    func createRequiredFiles() {
        // Create relay data directory if needed
        try? FileManager.default.createDirectory(at: relayDataDir, withIntermediateDirectories: true)
        
        // Create .env file - handled by RelayProcessManager on first run/setup
        let envContent = RelayConfiguration.formatEnvFile(from: RelayConfiguration.generateEnvDictionary(config: config, relayDataDir: relayDataDir))
        let envURL = relayDataDir.appendingPathComponent(".env")
        try? envContent.write(to: envURL, atomically: true, encoding: .utf8)
        
        // Create relays_import.json
        let importRelays = """
        [
            "wss://relay.primal.net",
            "wss://nos.lol",
            "wss://nostr.mom",
            "wss://relay.btcforplebs.com",
            "wss://nostr-pub.wellorder.net"
        ]
        """
        let importURL = relayDataDir.appendingPathComponent("relays_import.json")
        try? importRelays.write(to: importURL, atomically: true, encoding: .utf8)
        
        // Create relays_blastr.json
        let blastrRelays = """
        [
            "wss://relay.primal.net",
            "wss://nos.lol",
            "wss://nostr.mom",
            "wss://relay.btcforplebs.com",
            "wss://nostr-pub.wellorder.net"
        ]
        """
        let blastrURL = relayDataDir.appendingPathComponent("relays_blastr.json")
        try? blastrRelays.write(to: blastrURL, atomically: true, encoding: .utf8)
        
        // Create blossom directory
        let blossomDir = relayDataDir.appendingPathComponent("blossom")
        try? FileManager.default.createDirectory(at: blossomDir, withIntermediateDirectories: true)
        
        #if DEBUG
        print("Created Haven config files at: \(relayDataDir.path)")
        #endif
    }
    
    /// Perform a factory reset: delete data and config using FileManager
    func resetApp() {
        let fileManager = FileManager.default
        
        // 1. Delete relay data directory (contains DB, logs, .env)
        // Checks to ensure we aren't deleting root or home by accident
        if relayDataDir.path.count > 10 && fileManager.fileExists(atPath: relayDataDir.path) {
            try? fileManager.removeItem(at: relayDataDir)
        }
        
        // 2. Delete config.json in Application Support
        if fileManager.fileExists(atPath: configURL.path) {
            try? fileManager.removeItem(at: configURL)
        }
        
        // 3. Reset in-memory config
        config = HavenConfig.default
    }
    
    /// Programmatically quit the application
    static func quitApp() {
        #if canImport(AppKit)
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
        #else
        DispatchQueue.main.async {
            // Suspend to home screen instead of exit(0) — Apple rejects apps that
            // programmatically terminate. The config is already cleared by resetApp(),
            // so the next launch will start fresh.
            UIControl().sendAction(#selector(URLSessionTask.suspend), to: UIApplication.shared, for: nil)
        }
        #endif
    }
    
    /// Reconstructs critical configuration from the existing .env file
    private func recoverFromEnv() {
        let envURL = relayDataDir.appendingPathComponent(".env")
        guard let content = try? String(contentsOf: envURL, encoding: .utf8) else { return }
        
        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLine.isEmpty && !trimmedLine.hasPrefix("#") && !trimmedLine.hasPrefix("//") else { continue }
            
            let parts = trimmedLine.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard parts.count == 2 else { continue }
            
            let key = parts[0]
            var value = parts[1]
            
            // Remove quotes if present, handling cases where there might be spaces inside/outside quotes
            if value.hasPrefix("\"") {
                value = String(value.dropFirst())
                if value.hasSuffix("\"") {
                    value = String(value.dropLast())
                }
            } else if value.hasPrefix("'") {
                value = String(value.dropFirst())
                if value.hasSuffix("'") {
                    value = String(value.dropLast())
                }
            }
            
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            
            switch key {
            case "OWNER_NPUB": 
                // Sanitize recovered npub immediately
                config.ownerNpub = value.filter { "abcdefghijklmnopqrstuvwxyz0123456789".contains($0.lowercased()) }
            case "RELAY_URL": config.relayURL = value
            case "RELAY_PORT": config.relayPort = Int(value) ?? config.relayPort
            case "DB_ENGINE": config.dbEngine = value
            case "PRIVATE_RELAY_NAME": config.privateRelayName = value
            case "PRIVATE_RELAY_DESCRIPTION": config.privateRelayDescription = value
            case "PRIVATE_RELAY_ICON": config.privateRelayIcon = value
            case "CHAT_RELAY_NAME": config.chatRelayName = value
            case "CHAT_RELAY_DESCRIPTION": config.chatRelayDescription = value
            case "CHAT_RELAY_ICON": config.chatRelayIcon = value
            case "OUTBOX_RELAY_NAME": config.outboxRelayName = value
            case "OUTBOX_RELAY_DESCRIPTION": config.outboxRelayDescription = value
            case "OUTBOX_RELAY_ICON": config.outboxRelayIcon = value
            case "INBOX_RELAY_NAME": config.inboxRelayName = value
            case "INBOX_RELAY_DESCRIPTION": config.inboxRelayDescription = value
            case "INBOX_RELAY_ICON": config.inboxRelayIcon = value
            // Clamped like the JSON decode path: sub-5-min values are legacy
            // saves of the old 60s default (the sync treadmill).
            case "INBOX_PULL_INTERVAL_SECONDS": config.inboxPullIntervalSeconds = max(Int(value) ?? config.inboxPullIntervalSeconds, 300)
            case "WHITELISTED_NPUBS_FILE": config.whitelistedNpubsFile = value
            case "BLACKLISTED_NPUBS_FILE": config.blacklistedNpubsFile = value
            default: break
            }
        }
        
        config.hasCompletedSetup = true
        #if DEBUG
        print("ConfigService: Successfully recovered critical settings from .env")
        #endif
    }
    
    /// Recomputes `activeAccountHexPubkey` from the current config.
    /// Called after any change to `activeAccountNpub` or `ownerNpub`.
    func refreshActiveAccountHex() {
        let active = config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        if !active.isEmpty, let decoded = Bech32.decode(active) {
            activeAccountHexPubkey = decoded.hexString
            return
        }
        // Fall back to owner
        let ownerNpub = config.ownerNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        if let decoded = Bech32.decode(ownerNpub) {
            activeAccountHexPubkey = decoded.hexString
            return
        }
        activeAccountHexPubkey = ""
    }

    /// Returns all accounts (owner + whitelisted) as npub strings, deduped
    var allAccountNpubs: [String] {
        var result: [String] = [config.ownerNpub]
        for npub in config.whitelistedNpubs {
            let trimmed = npub.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && trimmed != config.ownerNpub {
                result.append(trimmed)
            }
        }
        return result
    }

    /// Switches the active browsing account. Pass nil or ownerNpub to reset to owner.
    /// Handles NIP-46 connection switching: disconnects the previous signer (if any)
    /// and connects to the new account's signer (if configured).
    func switchActiveAccount(to npub: String?) {
        let target = npub?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let newValue = (target == config.ownerNpub) ? "" : target

        // No-op if already on the target account
        guard newValue != config.activeAccountNpub else { return }

        // Disconnect previous NIP-46 signer if active
        let previousNpub = config.activeAccountNpub.isEmpty ? config.ownerNpub : config.activeAccountNpub
        // Also stop a connect still in flight — otherwise it lands after the
        // switch and the new account's posts go to the old account's signer.
        if hasBunkerConfig(forNpub: previousNpub) && NIP46Service.shared.connectionState != .disconnected {
            NIP46Service.shared.disconnect()
        }

        isSwitchingAccount = true
        config.activeAccountNpub = newValue
        refreshActiveAccountHex()

        // Connect to new account's NIP-46 signer if the active signing mode is nip46
        let resolvedNpub = newValue.isEmpty ? config.ownerNpub : newValue
        let mode = config.activeSigningMode()
        if mode == "nip46" && hasBunkerConfig(forNpub: resolvedNpub) {
            syncGlobalNIP46Fields(fromNpub: resolvedNpub)
            NIP46Service.shared.connectFromConfig()
        } else {
            config.signingMode = mode
        }

        save()

        // Services process synchronously via Combine before the next run-loop cycle.
        // Clear the flag once SwiftUI has had one cycle to recreate views with .id().
        DispatchQueue.main.async { [weak self] in
            self?.isSwitchingAccount = false
        }
    }
    
    // MARK: - Per-Account Credential Management
    
    /// Encrypts and stores an nsec for a whitelisted account.
    /// The password is saved to the Keychain namespaced by npub.
    func setCredential(nsec: String, password: String, forNpub npub: String) throws {
        let ncryptsec = try NIP49Service.encrypt(nsec: nsec, password: password)
        config.accountCredentials[npub] = ncryptsec
        CredentialStore.storePassword(password, forNpub: npub)
        save()
    }
    
    /// Returns the decrypted hex private key for a whitelisted account.
    /// Looks up the Keychain password automatically; returns nil if no credential is stored.
    func getCredentialHexKey(forNpub npub: String) throws -> String? {
        guard let ncryptsec = config.accountCredentials[npub], !ncryptsec.isEmpty else {
            return nil
        }
        guard let password = CredentialStore.getPassword(forNpub: npub) else {
            return nil
        }
        let nsec = try NIP49Service.decrypt(ncryptsec: ncryptsec, password: password)
        // Decode nsec → hex
        let clean = nsec.trimmingCharacters(in: .whitespacesAndNewlines)
        if let decoded = Bech32.decode(clean), decoded.hrp == "nsec" {
            return decoded.hexString
        }
        if clean.count == 64, clean.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil {
            return clean
        }
        return nil
    }
    
    /// Returns whether a signing credential is stored for the given npub.
    func hasCredential(forNpub npub: String) -> Bool {
        guard let stored = config.accountCredentials[npub] else { return false }
        return !stored.isEmpty
    }
    
    /// Removes the stored credential and Keychain password for a whitelisted account.
    func removeCredential(forNpub npub: String) {
        config.accountCredentials.removeValue(forKey: npub)
        CredentialStore.deletePassword(forNpub: npub)
        save()
    }

    // MARK: - Per-Account NIP-46 Bunker Configuration

    func setBunkerConfig(_ bunkerConfig: AccountBunkerConfig, forNpub npub: String) {
        config.accountBunkerConfigs[npub] = bunkerConfig
        // Sync to global fields if this is the active account and signing mode is nip46
        let activeNpub = config.activeAccountNpub.isEmpty ? config.ownerNpub : config.activeAccountNpub
        if npub == activeNpub && config.activeSigningMode() == "nip46" {
            syncGlobalNIP46Fields(fromNpub: npub)
        }
        save()
    }

    func getBunkerConfig(forNpub npub: String) -> AccountBunkerConfig? {
        config.accountBunkerConfigs[npub]
    }

    func hasBunkerConfig(forNpub npub: String) -> Bool {
        guard let cfg = config.accountBunkerConfigs[npub] else { return false }
        return !cfg.bunkerURI.isEmpty || !cfg.signerPubkey.isEmpty
    }

    func removeBunkerConfig(forNpub npub: String) {
        config.accountBunkerConfigs.removeValue(forKey: npub)
        // If no accounts use NIP-46 anymore, reset global signing mode
        if config.accountBunkerConfigs.isEmpty {
            config.signingMode = "local"
            config.nip46BunkerURI = ""
            config.nip46SignerPubkey = ""
            config.nip46RelayURL = ""
            config.nip46Secret = ""
        }
        save()
    }

    /// Sets the user's preferred signing mode for a given account.
    /// Handles NIP-46 connect/disconnect if this is the active account.
    func setSigningMode(_ mode: String, forNpub npub: String) {
        config.accountSigningModes[npub] = mode

        // If this is the currently active account, apply immediately
        let activeNpub = config.activeAccountNpub.isEmpty ? config.ownerNpub : config.activeAccountNpub
        if npub == activeNpub {
            if mode == "nip46" && hasBunkerConfig(forNpub: npub) {
                syncGlobalNIP46Fields(fromNpub: npub)
                NIP46Service.shared.connectFromConfig()
            } else if mode == "local" {
                if NIP46Service.shared.isConnected {
                    NIP46Service.shared.disconnect()
                }
                config.signingMode = "local"
            }
        }
        save()
    }

    /// Syncs the global NIP-46 fields from a per-account bunker config so NIP46Service can connect.
    func syncGlobalNIP46Fields(fromNpub npub: String) {
        guard let cfg = config.accountBunkerConfigs[npub] else { return }
        config.signingMode = "nip46"
        config.nip46BunkerURI = cfg.bunkerURI
        config.nip46SignerPubkey = cfg.signerPubkey
        config.nip46RelayURL = cfg.relayURL
        config.nip46Secret = cfg.secret
        config.nip46ClientSecretKey = cfg.clientSecretKey
        config.nip46ClientPubkey = cfg.clientPubkey
        save()
    }

    /// Returns a Set of hex pubkeys derived from the whitelisted npubs
    var whitelistedHexPubkeys: Set<String> {
        var hexKeys = Set<String>()
        for npub in config.whitelistedNpubs {
            let clean = npub.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.isEmpty { continue }
            
            // Decodes bech32 and returns (hrp, data) tuple.
            // We need to convert data to hex string if possible.
            // Assuming Bech32 helper has a .hexString property on the return tuple or similar.
            // Based on NostrService usage: if let hex = Bech32.decode(npub)?.hexString
            if let decoded = Bech32.decode(clean) {
                hexKeys.insert(decoded.hexString)
            }
        }
        return hexKeys
    }

    /// Returns a Set of hex pubkeys derived from the blacklisted npubs
    var blacklistedHexPubkeys: Set<String> {
        var hexKeys = Set<String>()
        for npub in config.blacklistedNpubs {
            let clean = npub.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.isEmpty { continue }
            if let decoded = Bech32.decode(clean) {
                hexKeys.insert(decoded.hexString)
            }
        }
        return hexKeys
    }

    /// Returns the active browsing account's blocked hex pubkeys.
    /// Falls back to owner if active browsing account is empty.
    var activeAccountBlockedHexPubkeys: Set<String> {
        let active = config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetNpub = active.isEmpty ? config.ownerNpub : active
        let blockedNpubs = config.blockedNpubsPerAccount[targetNpub] ?? (targetNpub == config.ownerNpub ? config.blacklistedNpubs : [])
        
        var hexKeys = Set<String>()
        for npub in blockedNpubs {
            let clean = npub.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.isEmpty { continue }
            if let decoded = Bech32.decode(clean) {
                hexKeys.insert(decoded.hexString)
            }
        }
        return hexKeys
    }

    func blockProfile(_ npub: String) {
        let active = config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetNpub = active.isEmpty ? config.ownerNpub : active

        var current = config.blockedNpubsPerAccount[targetNpub] ?? []
        if !current.contains(npub) {
            current.append(npub)
            config.blockedNpubsPerAccount[targetNpub] = current

            // Sync owner to blacklistedNpubs for Go backend compatibility
            if targetNpub == config.ownerNpub {
                config.blacklistedNpubs = current
            }
            save()
            syncBlacklistToRelay()

            // Post notification for instant UI refresh
            NotificationCenter.default.post(name: NSNotification.Name("BlockedAccountsUpdated"), object: nil)

            // Publish updated mute list back to Nostr
            NostrService.shared.publishMuteList(for: targetNpub, blockedNpubs: current)
        }
    }

    func unblockProfile(_ npub: String) {
        let active = config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetNpub = active.isEmpty ? config.ownerNpub : active

        var current = config.blockedNpubsPerAccount[targetNpub] ?? []
        if let index = current.firstIndex(of: npub) {
            current.remove(at: index)
            config.blockedNpubsPerAccount[targetNpub] = current

            // Sync owner to blacklistedNpubs for Go backend compatibility
            if targetNpub == config.ownerNpub {
                config.blacklistedNpubs = current
            }
            save()
            syncBlacklistToRelay()

            // Post notification for instant UI refresh
            NotificationCenter.default.post(name: NSNotification.Name("BlockedAccountsUpdated"), object: nil)

            // Publish updated mute list back to Nostr
            NostrService.shared.publishMuteList(for: targetNpub, blockedNpubs: current)
        }
    }

    /// Pushes the combined (all-accounts) blocked list to the running relay
    /// immediately. Without this, BLACKLISTED_NPUBS_FILE is only ever read once
    /// at relay startup — blocking someone mid-session previously had no effect
    /// at the relay level until the next app launch, so the relay kept
    /// importing and notifying about their activity even though the client's
    /// own feed/vault filters correctly hid it everywhere (the red dot fires,
    /// but nothing shows up in any filter — that mismatch is the bug this
    /// closes). Also fixes secondary/non-owner accounts never reaching the
    /// relay's blacklist at all, since the relay-level list is global, not
    /// per-account, and previously only the owner's blocks were synced to it.
    private func syncBlacklistToRelay() {
        guard let data = try? JSONEncoder().encode(config.allBlockedNpubsAcrossAccounts),
              let json = String(data: data, encoding: .utf8),
              let cJSON = strdup(json) else { return }
        UpdateBlacklistC(cJSON)
        free(cJSON)
    }

    // MARK: - Throttle (Slow Down)

    /// Returns the active browsing account's throttled hex pubkeys and their max visible post limits.
    var activeAccountThrottledHexPubkeys: [String: Int] {
        let active = config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetNpub = active.isEmpty ? config.ownerNpub : active
        let throttled = config.throttledAccountsPerAccount[targetNpub] ?? [:]

        var hexMap: [String: Int] = [:]
        for (npub, limit) in throttled {
            let clean = npub.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.isEmpty { continue }
            if let decoded = Bech32.decode(clean) {
                hexMap[decoded.hexString] = limit
            }
        }
        return hexMap
    }

    func throttleProfile(_ npub: String, maxPosts: Int) {
        let active = config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetNpub = active.isEmpty ? config.ownerNpub : active

        var current = config.throttledAccountsPerAccount[targetNpub] ?? [:]
        current[npub] = maxPosts
        config.throttledAccountsPerAccount[targetNpub] = current
        save()

        NotificationCenter.default.post(name: NSNotification.Name("BlockedAccountsUpdated"), object: nil)
    }

    func unthrottleProfile(_ npub: String) {
        let active = config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetNpub = active.isEmpty ? config.ownerNpub : active

        var current = config.throttledAccountsPerAccount[targetNpub] ?? [:]
        current.removeValue(forKey: npub)
        config.throttledAccountsPerAccount[targetNpub] = current
        save()

        NotificationCenter.default.post(name: NSNotification.Name("BlockedAccountsUpdated"), object: nil)
    }

    /// Whether a local URL can be rewritten to an external share link.
    /// Returns true for URLs that are already external, or local URLs when
    /// macRelayHttpsURL or an active Blossom mirror is configured.
    func hasExternalShareURL(for url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        let isLocal = host == "127.0.0.1" || host == "localhost" || host == "0.0.0.0"
        guard isLocal else { return true }
        if !config.macRelayHttpsURL.isEmpty { return true }
        if !config.activeBlossomMirrors.isEmpty { return true }
        return false
    }

    /// Returns a shareable URL for a media item, rewriting local relay hosts
    /// (127.0.0.1/localhost) to the configured Mac relay's https URL when available,
    /// falling back to the first active Blossom mirror if no Mac relay URL is set.
    /// External URLs (e.g. existing mirror URLs) are returned unchanged.
    func externalShareURL(for url: URL) -> URL {
        let host = url.host?.lowercased() ?? ""
        let isLocal = host == "127.0.0.1" || host == "localhost" || host == "0.0.0.0"
        guard isLocal else { return url }

        let macHTTPS = config.macRelayHttpsURL
        if !macHTTPS.isEmpty, var components = URLComponents(string: macHTTPS) {
            // Preserve the path (typically just the blossom hash) and any query string.
            let path = url.path.isEmpty ? "/" : url.path
            components.path = (components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path) + path
            components.query = url.query
            if let result = components.url { return result }
        }

        // Fallback: use the first active Blossom mirror for shareable links
        if let mirror = config.activeBlossomMirrors.first,
           var components = URLComponents(string: mirror) {
            let path = url.path.isEmpty ? "/" : url.path
            components.path = (components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path) + path
            components.query = url.query
            if let result = components.url { return result }
        }

        return url
    }


    /// Hands the bundled starter packs to the Go relay as a flat list of npubs.
    ///
    /// The relay seeds its Web of Trust from these when the owner follows
    /// nobody — otherwise a new account's trust graph contains one pubkey,
    /// itself, and every feed built on it shows either nothing or the open
    /// firehose. The relay carries its own copy as a fallback for running
    /// headless, but `starter_packs.json` in the app bundle is the source of
    /// truth and this write is what keeps the two from drifting: edit the
    /// bundled file and both the Initial Follows step and the trust graph
    /// follow.
    ///
    /// Writing nothing is better than writing an empty list — the relay treats
    /// an empty override as unusable and keeps its fallback, but leaving a
    /// stale file behind would be worse.
    private func writeStarterPackSeeds(encoder: JSONEncoder) {
        guard let packs = StarterPacksData.load() else { return }
        var seen = Set<String>()
        var npubs: [String] = []
        for pack in packs.packs {
            for account in pack.accounts where !account.npub.isEmpty {
                if seen.insert(account.npub).inserted {
                    npubs.append(account.npub)
                }
            }
        }
        guard !npubs.isEmpty else { return }
        let url = relayDataDir.appendingPathComponent("starter_pack.json")
        if let data = try? encoder.encode(npubs) {
            try? data.write(to: url)
        }
    }

}

