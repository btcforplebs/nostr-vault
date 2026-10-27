import SwiftUI
import Foundation
import Combine
import Security
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
    @Published var config: HavenConfig {
        didSet {
            if config.blockedRelays != oldValue.blockedRelays { RelayBlocklist.set(config.blockedRelays) }
        }
    }
    @Published var isSwitchingAccount: Bool = false
    /// config.json existed but would not load. Until a copy of it is kept,
    /// save() writes nothing, so the key inside it is never overwritten.
    @Published private(set) var loadFailed = false
    /// Whether the config.json this session read or last wrote held a key.
    /// False after a failed load or a load from the backup, so a recovery
    /// save never deletes config.json.bak.
    private var savedHasKey = false
    /// The NIP-46 client keys the keychain holds; see HavenConfig+Secrets.
    private var nip46Sync = NIP46SecretSync()
    /// Accounts whose client key the keychain holds now, left out of config.json.
    private var nip46InKeychain: Set<String> = []
    /// Client keys config.json held as plaintext when it loaded. Once the
    /// keychain holds them they are scrubbed from the backup copies too.
    private var plaintextNIP46Secrets: [String] = []
    /// Client keys config.json held that lost to the paired keychain key at
    /// load (see attachNIP46ClientSecrets). Never paired, but still keys:
    /// scrubbed from the backup copies once config.json is written without them.
    private var droppedNIP46Secrets: [String] = []
    /// Explicit @Published hex pubkey for the active account. Computed properties
    /// on ObservableObject don't reliably trigger SwiftUI re-renders in all
    /// hosting contexts (e.g. macOS MenuBarExtra). This property is updated
    /// whenever the active account changes.
    @Published private(set) var activeAccountHexPubkey: String = ""

    /// Each switch of the active account, as its hex pubkey, delivered on the
    /// main queue once `config` already names the new account. Leaves out the
    /// current value and setup's first account (see `isAccountSwitch`).
    var activeAccountSwitches: AnyPublisher<String, Never> {
        $activeAccountHexPubkey
            .scan((previous: String?.none, current: String?.none)) { ($0.current, $1) }
            .compactMap { pair -> String? in
                guard let previous = pair.previous, let current = pair.current,
                      HavenConfig.isAccountSwitch(from: previous, to: current) else { return nil }
                return current
            }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
    
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
        
        // Load existing config or create default. A config.json that would
        // not load is never written over until a copy of it is kept (save()).
        switch ConfigFileStore(url: configURL).load(HavenConfig.self, hasKey: \.hasKeyMaterial) {
        case .loaded(let loaded, let fromBackup):
            config = loaded
            attachKeychainSecrets()
            loadedSuccessfully = true
            loadFailed = fromBackup && FileManager.default.fileExists(atPath: configURL.path)
            savedHasKey = !fromBackup && loaded.hasKeyMaterial
            if fromBackup {
                RelayProcessManager.shared.addLog("config.json would not load; restored from config.json.bak", level: "ERROR")
            }
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
        case .unreadable(let error):
            RelayProcessManager.shared.addLog("Error decoding configuration: \(error.localizedDescription)", level: "ERROR")
            config = HavenConfig.default
            loadFailed = true
        case .missing:
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
        config.dropDeadRelaysOnce()
        removeStarterPackPicksFromAccounts()
        
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
        RelayBlocklist.set(config.blockedRelays)
    }
    
    func reload() {
        if let data = try? Data(contentsOf: configURL) {
            do {
                let loaded = try JSONDecoder().decode(HavenConfig.self, from: data)
                self.config = loaded
                // Without this a reload drops the client keys from memory and
                // the next save deletes them from the keychain.
                attachKeychainSecrets()
                savedHasKey = loaded.hasKeyMaterial
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
                config.dropDeadRelaysOnce()

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
            // Older builds wrote the Mac relay into this file and read it back
            // as one of the user's own seed relays. The relay adds the Mac
            // itself now (MAC_RELAY_URL), so drop that leaked copy.
            let mac = config.macRelayWssURL
            config.importSeedRelays = mac.isEmpty ? list : list.filter { $0 != mac }
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

        let store = ConfigFileStore(url: configURL)
        if loadFailed {
            // Defaults (or a half-done setup) must not replace the unreadable
            // file. Once there is a real config to keep, copy the old file
            // aside first; if even that fails, keep refusing.
            guard config.hasCompletedSetup else { return }
            do {
                try store.preserveUnreadable()
                loadFailed = false
            } catch {
                RelayProcessManager.shared.addLog("Not saving config: could not keep a copy of the unreadable config.json (\(error.localizedDescription))", level: "ERROR")
                return
            }
        }

        nip46InKeychain = nip46Sync.sync(config.nip46ClientSecrets,
                                         store: { CredentialStore.store($0, account: $1) },
                                         delete: { CredentialStore.delete(account: $0) })

        do {
            let data = try JSONEncoder().encode(config.withoutNIP46ClientSecrets(inKeychain: nip46InKeychain))
            try store.write(data)
            store.forgetBackupIfKeyRemoved(hadKey: savedHasKey, hasKey: config.hasKeyMaterial,
                                           setupDone: config.hasCompletedSetup)
            savedHasKey = config.hasKeyMaterial
            scrubPlaintextNIP46Secrets(store)

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
        if let data = try? encoder.encode(config.withoutNIP46ClientSecrets(inKeychain: nip46InKeychain)) {
            try? ConfigFileStore(url: configURL).write(data) // Save main config again just in case
        }
        
        RelayConfiguration.writeImportSeedRelays(config: config, under: relayDataDir)
        
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

        // Save whitelisted npubs. Written even when empty: loadRelayLists reads
        // this file back over config.json, so skipping the write when the list
        // is emptied brings the last removed account back on the next launch.
        let npubsURL = relayDataDir.appendingPathComponent(config.whitelistedNpubsFile)
        if let data = try? encoder.encode(config.whitelistedNpubs) {
            try? data.write(to: npubsURL)
        }
        
        // Save blacklisted npubs. Written even when empty, for the same reason
        // as the whitelist: unblocking the last legacy entry must not come back
        // on the next launch and keep that person blocked on the relay.
        let blacklistedURL = relayDataDir.appendingPathComponent(config.blacklistedNpubsFile)
        if let data = try? encoder.encode(config.blacklistedNpubs) {
            try? data.write(to: blacklistedURL)
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
    
    /// Fills in the NIP-46 client keys config.json leaves out, from the
    /// keychain, and notes any the file still held as plaintext.
    private func attachKeychainSecrets() {
        // Added to, not replaced: a reload before the save that moves them
        // must not forget a scrub still owed.
        plaintextNIP46Secrets = Array(Set(plaintextNIP46Secrets).union(config.nip46ClientSecrets.values))
        var stored: [String: String] = [:]
        let dropped = config.attachNIP46ClientSecrets({ account in
            let value = CredentialStore.get(account: account)
            stored[account] = value
            return value
        }, pubkeyOf: Self.nip46ClientPubkey(ofSecret:))
        droppedNIP46Secrets = Array(Set(droppedNIP46Secrets).union(dropped))
        if !dropped.isEmpty {
            RelayProcessManager.shared.addLog("NIP-46: config.json held an app key the signer was not paired with; using the paired one from the keychain", level: "WARNING")
        }
        nip46Sync = NIP46SecretSync(synced: stored)
    }

    /// The hex pubkey of a NIP-46 client key, or nil if it is not one.
    static func nip46ClientPubkey(ofSecret hex: String) -> String? {
        guard !hex.isEmpty, let pk = withCStrings([hex], { p in GetPublicKeyC(p[0]) }) else { return nil }
        defer { free(pk) }
        let value = String(cString: pk)
        return value.isEmpty ? nil : value
    }

    /// Client keys that were plaintext in config.json come out of the backup
    /// copies once the keychain holds them and config.json has been written
    /// without them.
    private func scrubPlaintextNIP46Secrets(_ store: ConfigFileStore) {
        if !droppedNIP46Secrets.isEmpty {
            let live = Set(config.nip46ClientSecrets.values)
            let gone = droppedNIP46Secrets.filter { !live.contains($0) }
            store.scrub(gone)
            droppedNIP46Secrets.removeAll()
            plaintextNIP46Secrets.removeAll { gone.contains($0) }
        }
        guard !plaintextNIP46Secrets.isEmpty else { return }
        let held = Set(nip46InKeychain.compactMap { nip46Sync.synced[$0] })
        let done = plaintextNIP46Secrets.filter { held.contains($0) }
        guard !done.isEmpty else { return }
        store.scrub(done)
        plaintextNIP46Secrets.removeAll { held.contains($0) }
    }

    /// Takes a plaintext owner key out of config.json and every copy beside
    /// it: encrypts it into ownerNcryptsec (HavenConfig.encryptPlaintextOwnerKey),
    /// saves, and, once config.json on disk no longer holds it, scrubs it from
    /// the backup and the unreadable copies. A copy that still holds an older
    /// plaintext of the same key (setting a password clears ownerNsec in
    /// config.json only) is scrubbed too. Runs at launch on iOS and the Mac.
    func secureOwnerKeyAtRest() {
        var secrets: [String] = []
        if !config.ownerNsec.isEmpty {
            // Only a read that found no item means there is no password; any
            // other failure must not mint a new one over a password it hid.
            let stored = CredentialStore.lookUpOwnerPassword()
            guard stored.password != nil || stored.status == errSecItemNotFound else {
                RelayProcessManager.shared.addLog("Owner key left as it was: the keychain could not be read (\(stored.status))", level: "ERROR")
                return
            }
            var updated = config
            let outcome = updated.encryptPlaintextOwnerKey(
                storedPassword: stored.password,
                newPassword: Self.randomPassword,
                encrypt: { try NIP49Service.encrypt(nsec: $0, password: $1) },
                decrypt: { try NIP49Service.decrypt(ncryptsec: $0, password: $1) })
            switch outcome {
            case .encrypted(let newPassword):
                if let newPassword {
                    guard CredentialStore.storeOwnerPassword(newPassword),
                          CredentialStore.getOwnerPassword() == newPassword else {
                        RelayProcessManager.shared.addLog("Owner key left as it was: the keychain did not take its new password", level: "ERROR")
                        return
                    }
                }
            case .cleared:
                break
            case .nothingToDo:
                return
            case .keptUnverified, .failed:
                RelayProcessManager.shared.addLog("Plaintext owner key left in config.json (\(outcome))", level: "ERROR")
                return
            }
            secrets = [config.ownerNsec.trimmingCharacters(in: .whitespacesAndNewlines), config.ownerHexKey ?? ""]
            config = updated
            save()
        }

        // Scrub only on proof that config.json now holds the encrypted key and
        // not the plaintext: save() can return without writing (a config that
        // loaded from the backup), and then the backup is the only copy.
        let store = ConfigFileStore(url: configURL)
        guard !config.ownerNcryptsec.isEmpty,
              let written = try? String(contentsOf: configURL, encoding: .utf8),
              written.contains(config.ownerNcryptsec),
              !secrets.contains(where: { !$0.isEmpty && written.contains($0) }) else {
            if !secrets.isEmpty {
                RelayProcessManager.shared.addLog("config.json was not rewritten; its copies keep the owner key for now", level: "ERROR")
            }
            return
        }
        secrets += olderPlaintextOwnerKeys(in: store)
        if !store.scrub(secrets).isEmpty {
            RelayProcessManager.shared.addLog("Removed a plaintext owner key from config.json's copies", level: "INFO")
        }
    }

    /// Plaintext `ownerNsec` values in the copies beside config.json that the
    /// stored password shows are the key ownerNcryptsec holds now.
    private func olderPlaintextOwnerKeys(in store: ConfigFileStore) -> [String] {
        let olds = store.copyURLs.compactMap { file -> String? in
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let old = (json["ownerNsec"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !old.isEmpty else { return nil }
            return old
        }
        // The decrypt (scrypt) runs only when a copy holds a plaintext key.
        guard !olds.isEmpty,
              let password = CredentialStore.getOwnerPassword(),
              !config.ownerNcryptsec.isEmpty,
              let nsec = try? NIP49Service.decrypt(ncryptsec: config.ownerNcryptsec, password: password),
              let current = HavenConfig.hexKey(fromNsec: nsec) else { return [] }
        return olds.filter { HavenConfig.hexKey(fromNsec: $0) == current }
    }

    private static func randomPassword() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return UUID().uuidString + UUID().uuidString
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Perform a factory reset: delete data and config using FileManager
    func resetApp() {
        let fileManager = FileManager.default
        
        // 1. Delete relay data directory (contains DB, logs, .env)
        // Checks to ensure we aren't deleting root or home by accident
        if relayDataDir.path.count > 10 && fileManager.fileExists(atPath: relayDataDir.path) {
            try? fileManager.removeItem(at: relayDataDir)
        }
        
        // 2. Delete config.json and its backup in Application Support
        ConfigFileStore(url: configURL).removeAll()
        loadFailed = false
        savedHasKey = false
        nip46Sync = NIP46SecretSync()
        nip46InKeychain = []
        plaintextNIP46Secrets = []
        droppedNIP46Secrets = []

        // 3. Keychain passwords, notifications and widget data
        ResetLeftovers.clear()

        // 4. Reset in-memory config
        config = HavenConfig.default
        // The account went with it; services listening for a switch drop its state.
        refreshActiveAccountHex()
        // The relay's certificate went with its data folder; a new one is coming.
        LocalTLSTrust.forgetAll()
    }
    
    #if canImport(AppKit)
    /// Quits the Mac app after a factory reset. iOS has no counterpart: an
    /// app may not quit itself there, and with the config cleared the root
    /// view already shows the setup wizard.
    static func quitApp() {
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }
    #endif
    
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
        // The previous account's signer session stays connected in the
        // background (switching back is then instant); only stop treating it
        // as the active signer.
        if hasBunkerConfig(forNpub: previousNpub) && NIP46Service.shared.connectionState != .disconnected {
            NIP46Service.shared.detachForAccountSwitch()
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
        // The owner's relay AUTH signs through the owner's own bunker session.
        NIP46Service.shared.connectOwnerInBackgroundIfNeeded()

        save()

        // Each account has its own block list. Tell the screens now, so they
        // drop the old account's blocks without waiting for a feed `.id` reset.
        NotificationCenter.default.post(name: NSNotification.Name("BlockedAccountsUpdated"), object: nil)

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
    
    /// Undoes what the old Discover Accounts step did: it saved the people
    /// picked there as extra accounts instead of following them. Removes those
    /// starter-pack npubs from the account list unless this device holds a key
    /// or signer for one, in which case the user added it on purpose.
    private func removeStarterPackPicksFromAccounts() {
        let kept = ContactManager.accountsWithoutStarterPackPicks(config.whitelistedNpubs) { npub in
            hasCredential(forNpub: npub) || hasBunkerConfig(forNpub: npub)
        }
        guard kept.count != config.whitelistedNpubs.count else { return }
        let removed = Set(config.whitelistedNpubs).subtracting(kept)
        config.whitelistedNpubs = kept
        if removed.contains(config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)) {
            config.activeAccountNpub = ""
        }
        // Not RelayProcessManager.addLog: this runs inside ConfigService.init.
        print("ConfigService: removed \(removed.count) starter-pack account(s) that setup added by mistake")
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
        // Paired again (new client key or signer): close the old live session,
        // or switching to this account would reuse it instead of the new link.
        if let old = config.accountBunkerConfigs[npub],
           old.clientPubkey != bunkerConfig.clientPubkey || old.signerPubkey != bunkerConfig.signerPubkey {
            NIP46Service.dropSession(signerKey: NIP46Service.signerKey(bunkerURI: old.bunkerURI, signerPubkey: old.signerPubkey))
            // The active account's session is gone: stop calling it connected,
            // so the connect that follows actually runs.
            let activeNpub = config.activeAccountNpub.isEmpty ? config.ownerNpub : config.activeAccountNpub
            if npub == activeNpub { NIP46Service.shared.detachForAccountSwitch() }
        }
        config.accountBunkerConfigs[npub] = bunkerConfig
        // Sync to global fields if this is the active account and signing mode is nip46
        let activeNpub = config.activeAccountNpub.isEmpty ? config.ownerNpub : config.activeAccountNpub
        if npub == activeNpub && config.activeSigningMode() == "nip46" {
            syncGlobalNIP46Fields(fromNpub: npub)
        }
        save()
    }

    func hasBunkerConfig(forNpub npub: String) -> Bool {
        guard let cfg = config.accountBunkerConfigs[npub] else { return false }
        return !cfg.bunkerURI.isEmpty || !cfg.signerPubkey.isEmpty
    }

    func removeBunkerConfig(forNpub npub: String) {
        if let old = config.accountBunkerConfigs[npub] {
            NIP46Service.dropSession(signerKey: NIP46Service.signerKey(bunkerURI: old.bunkerURI, signerPubkey: old.signerPubkey))
            let activeNpub = config.activeAccountNpub.isEmpty ? config.ownerNpub : config.activeAccountNpub
            if npub == activeNpub { NIP46Service.shared.detachForAccountSwitch() }
        }
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
        return blockedHexPubkeys(forAccount: active.isEmpty ? config.ownerNpub : active)
    }

    /// The hex pubkeys one account has blocked.
    func blockedHexPubkeys(forAccount targetNpub: String) -> Set<String> {
        let blockedNpubs = config.blockedNpubsPerAccount[targetNpub] ?? (targetNpub == config.ownerNpub ? config.blacklistedNpubs : [])

        var hexKeys = Set<String>()
        for npub in blockedNpubs {
            let clean = npub.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.isEmpty { continue }
            if let decoded = Bech32.decode(clean) {
                hexKeys.insert(decoded.hexString)
            }
        }
        // Private blocks from the list's encrypted part. Never stored in
        // blockedNpubsPerAccount, which is published in the clear.
        return hexKeys.union(MuteListStore.shared.privatePubkeys(forAccount: targetNpub))
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

            // Add this one person to the published mute list
            NostrService.shared.publishMuteListChange(for: targetNpub, add: [npub], localBlocks: current)
        }
    }

    func unblockProfile(_ npub: String) {
        let active = config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetNpub = active.isEmpty ? config.ownerNpub : active

        // Same fallback as blockedHexPubkeys(forAccount:): an owner whose
        // blocks only live in the legacy blacklist must still be able to
        // unblock them, or the dashboard counts people the page can't remove.
        var current = config.blockedNpubsPerAccount[targetNpub]
            ?? (targetNpub == config.ownerNpub ? config.blacklistedNpubs : [])
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

            // Take this one person off the published mute list
            NostrService.shared.publishMuteListChange(for: targetNpub, remove: [npub], localBlocks: current)
        } else if let hex = Bech32.decode(npub.trimmingCharacters(in: .whitespacesAndNewlines))?.hexString,
                  MuteListStore.shared.privatePubkeys(forAccount: targetNpub).contains(hex.lowercased()) {
            // Blocked only in the list's encrypted part: nothing to change
            // here, the published list drops them and the store reopens it.
            NostrService.shared.publishMuteListChange(for: targetNpub, remove: [npub], localBlocks: current)
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

}

