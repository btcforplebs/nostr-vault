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
    
    // Config stored in App Support (standard macOS location for app preferences/state)
    private let configURL: URL
    // Relay data stored in separate directory to avoid conflicts with source code
    let relayDataDir: URL
    
    init() {
        // Store config in Application Support
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
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
                #if DEBUG
                print("ConfigService: Error decoding configuration: \(error)")
                #endif
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
            } catch {
                #if DEBUG
                print("ConfigService: Error reloading configuration: \(error)")
                #endif
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
            #if DEBUG
            print("Failed to save config: \(error)")
            #endif
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
        let envContent = RelayProcessManager.shared.generateMinimalEnv(config: config)
        let envURL = relayDataDir.appendingPathComponent(".env")
        try? envContent.write(to: envURL, atomically: true, encoding: .utf8)
        
        // Create relays_import.json
        let importRelays = """
        [
            "wss://relay.damus.io",
            "wss://relay.primal.net",
            "wss://nos.lol",
            "wss://nostr.wine"
        ]
        """
        let importURL = relayDataDir.appendingPathComponent("relays_import.json")
        try? importRelays.write(to: importURL, atomically: true, encoding: .utf8)
        
        // Create relays_blastr.json
        let blastrRelays = """
        [
            "wss://relay.damus.io",
            "wss://relay.primal.net",
            "wss://nos.lol",
            "wss://nostr.wine"
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
            exit(0)
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
            case "INBOX_PULL_INTERVAL_SECONDS": config.inboxPullIntervalSeconds = Int(value) ?? config.inboxPullIntervalSeconds
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
    
    /// Returns the hex pubkey for the currently active browsing account.
    /// Falls back to the owner pubkey if no active account is set.
    var activeAccountHexPubkey: String {
        let active = config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        if !active.isEmpty, let decoded = Bech32.decode(active) {
            return decoded.hexString
        }
        // Fall back to owner
        let ownerNpub = config.ownerNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        if let decoded = Bech32.decode(ownerNpub) {
            return decoded.hexString
        }
        return ""
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
    func switchActiveAccount(to npub: String?) {
        let target = npub?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if target == config.ownerNpub {
            config.activeAccountNpub = ""
        } else {
            config.activeAccountNpub = target
        }
        save()
    }
    
    // MARK: - Per-Account Credential Management
    
    /// Encrypts and stores an nsec for a whitelisted account.
    /// The password is saved to the Keychain namespaced by npub.
    func setCredential(nsec: String, password: String, forNpub npub: String) throws {
        let ncryptsec = try NIP49Service.encrypt(nsec: nsec, password: password)
        config.accountCredentials[npub] = ncryptsec
        NIP49Service.storePasswordInKeychain(password, forNpub: npub)
        save()
    }
    
    /// Returns the decrypted hex private key for a whitelisted account.
    /// Looks up the Keychain password automatically; returns nil if no credential is stored.
    func getCredentialHexKey(forNpub npub: String) throws -> String? {
        guard let ncryptsec = config.accountCredentials[npub], !ncryptsec.isEmpty else {
            return nil
        }
        guard let password = NIP49Service.getPasswordFromKeychain(forNpub: npub) else {
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
        NIP49Service.deletePasswordFromKeychain(forNpub: npub)
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
            
            // Post notification for instant UI refresh
            NotificationCenter.default.post(name: NSNotification.Name("BlockedAccountsUpdated"), object: nil)
            
            // Publish updated mute list back to Nostr
            NostrService.shared.publishMuteList(for: targetNpub, blockedNpubs: current)
        }
    }

    /// Returns a shareable URL for a media item, rewriting local relay hosts
    /// (127.0.0.1/localhost) to the configured Mac relay's https URL when available.
    /// External URLs (e.g. existing mirror URLs) are returned unchanged.
    func externalShareURL(for url: URL) -> URL {
        let host = url.host?.lowercased() ?? ""
        let isLocal = host == "127.0.0.1" || host == "localhost" || host == "0.0.0.0"
        guard isLocal else { return url }

        let macHTTPS = config.macRelayHttpsURL
        guard !macHTTPS.isEmpty, var components = URLComponents(string: macHTTPS) else {
            return url
        }
        // Preserve the path (typically just the blossom hash) and any query string.
        let path = url.path.isEmpty ? "/" : url.path
        components.path = (components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path) + path
        components.query = url.query
        return components.url ?? url
    }

}

