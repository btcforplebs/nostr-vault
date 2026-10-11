import Foundation
@preconcurrency import Dispatch
import Combine
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

extension RelayProcessManager {
    /// Enqueue a lifecycle operation behind all previously enqueued ones.
    /// Serialization guarantees a start can never overlap an in-flight stop.
    func enqueueLifecycle(_ op: @escaping @MainActor () async -> Void) {
        let prev = lifecycleChain
        lifecycleChain = Task { @MainActor in
            await prev.value
            await op()
        }
    }

    func startRelay(config: HavenConfig, isRetry: Bool = false) {
        enqueueLifecycle { [weak self] in
            await self?.performStart(config: config, isRetry: isRetry)
        }
    }

    /// The actual start sequence. Must only run on the lifecycle chain.
    func performStart(config: HavenConfig, isRetry: Bool) async {
        // Strict guard: Must be idle, not running, and not in the middle of a shutdown
        guard state == .idle && !isRunning && !isShuttingDown else {
            logStore.append(LogEntry(timestamp: Date(), level: "WARN", message: "Cannot start relay: current state is \(state) (running: \(isRunning), shuttingDown: \(isShuttingDown))"))
            return
        }

        // Immediately claim the state so no second call can slip through.
        self.state = .booting
        #if os(iOS)
        observeForegroundOnce()
        #endif
        self.lastConfig = config
        self.isReadyForConnections = false
        self.readyForConnectionsTask?.cancel()

        // Only reset retry flag if this is a fresh start request, not an auto-retry
        if !isRetry {
            self.retryAttempted = false
            self.showProcessKillAlert = false
        }
        self.needsLockFix = false

        // Start log throttler
        startLogThrottler()

        let relayDataDir = ConfigService.shared.relayDataDir

        // 1. Ensure directories exist (I/O)
        RelayConfiguration.ensureDirectories(under: relayDataDir)

        // 2. Clear stale database locks — only on the first start after
        // process launch (see hasClearedLocksThisLaunch). Explicit recovery
        // paths (Fix Locks button, force clean & restart) clear them
        // unconditionally after a confirmed stop.
        if !hasClearedLocksThisLaunch {
            hasClearedLocksThisLaunch = true
            performClearDatabaseLocks(at: relayDataDir)
        }

        // 3. Copy templates directory — always refresh so new/updated
        //    templates (e.g. feed.html) are deployed on app update.
        let destURL = relayDataDir.appendingPathComponent("templates")
        if let templatesPath = Bundle.main.path(forResource: "templates", ofType: "") {
            if FileManager.default.fileExists(atPath: destURL.path) {
                try? FileManager.default.removeItem(at: destURL)
            }
            try? FileManager.default.copyItem(at: URL(fileURLWithPath: templatesPath), to: destURL)
            logStore.append(LogEntry(timestamp: Date(), level: "INFO", message: "Copied templates to \(destURL.path)"))
        } else {
            logStore.append(LogEntry(timestamp: Date(), level: "WARN", message: "Templates folder not found in Bundle"))
        }

        continueStartRelay(config: config, relayDataDir: relayDataDir)
    }

    /// Public method to add logs from other services
    nonisolated func addLog(_ message: String, level: String = "INFO") {
        let entry = LogEntry(timestamp: Date(), level: level, message: message)
        Task { @MainActor in
            self.logStore.append(entry)
        }
    }

    private func continueStartRelay(config: HavenConfig, relayDataDir: URL) {
        // Write/Update essential relay files (relays list, blastr relays)
        // We stop writing .env to disk and use environment variables instead
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        // Written from the same inputs applySavedConfig compares, so a setting
        // the relay reads here can never be missed by the auto-restart.
        let inputs = RelayConfiguration.launchInputs(config: config, relayDataDir: relayDataDir)

        RelayConfiguration.writeImportSeedRelays(config: config, under: relayDataDir)
        
        let blastrRelaysURL = relayDataDir.appendingPathComponent(config.blastrRelaysFile)
        if let data = try? encoder.encode(inputs.blastrRelays) {
            try? data.write(to: blastrRelaysURL)
        }

        let dmRelaysURL = relayDataDir.appendingPathComponent("relays_dm.json")
        if let data = try? encoder.encode(inputs.dmRelays) {
            try? data.write(to: dmRelaysURL)
        }

        // Write whitelisted_npubs.json (Required by new binary)
        let whitelistURL = relayDataDir.appendingPathComponent("whitelisted_npubs.json")
        if let data = try? encoder.encode(inputs.whitelistedNpubs) {
            try? data.write(to: whitelistURL)
        }
        
        // Write blacklisted_npubs.json
        let blacklistURL = relayDataDir.appendingPathComponent("blacklisted_npubs.json")
        if let data = try? encoder.encode(config.allBlockedNpubsAcrossAccounts) {
            try? data.write(to: blacklistURL)
        }
        
        logStore.append(LogEntry(timestamp: Date(), level: "INFO", message: "Config: \(config.activeImportSeedRelays.count) import relays, \(config.activeBlastrRelays.count) blastr relays, \(config.whitelistedNpubs.count) whitelisted npubs"))

        // Reset conflict state
        self.isPortConflict = false

        let envURL = relayDataDir.appendingPathComponent(".env")
        let envContent = generateMinimalEnv(config: config)
        try? envContent.write(to: envURL, atomically: true, encoding: .utf8)
        
        logStore.append(LogEntry(timestamp: Date(), level: "INFO", message: "Wrote .env to \(envURL.path)"))
        logStore.append(LogEntry(timestamp: Date(), level: "INFO", message: "Working Directory: \(relayDataDir.path)"))
        
        // Prepare environment for C-Shared lib execution
        for (key, value) in inputs.env {
            setenv(key, value, 1)
            if let cKey = strdup(key), let cValue = strdup(value) {
                SetHavenEnvC(cKey, cValue)
                free(cKey)
                free(cValue)
            }
        }

        // Change working directory so Go creates files in relayDataDir
        FileManager.default.changeCurrentDirectoryPath(relayDataDir.path)

        // Redirect stdout/stderr to capture Go logs
        captureOutput(in: relayDataDir)

        logStore.append(LogEntry(timestamp: Date(), level: "INFO", message: "Captured output natively"))

        self.state = .booting
        isRunning = true
        isBooting = true
        inboxSubscribed = false
        bootStatusMessage = "Starting system..."
        startBootWatchdog()
        beginRelayActivity()

        // Launch the C-Shared relay on a background thread
        DispatchQueue.global().async { [weak self] in
            // 0 = false (not in import mode)
            StartRelayC(0)
            
            // StartRelayC returns instantly because http.ListenAndServe runs in a goroutine
            DispatchQueue.main.async {
                self?.logStore.append(LogEntry(timestamp: Date(), level: "INFO", message: "Relay C-Shared process started"))
            }
        }
        
        isLocked = false
        startDate = Date()
        
    }
    
    func clearDatabaseLocks(completion: (@Sendable () -> Void)? = nil) {
        let relayDataDir = ConfigService.shared.relayDataDir
        Task {
            self.performClearDatabaseLocks(at: relayDataDir)
            await MainActor.run {
                self.isLocked = false
                self.logStore.append(LogEntry(timestamp: Date(), level: "INFO", message: "Database locks cleared."))
                completion?()
            }
        }
    }
    
    nonisolated func performClearDatabaseLocks(at relayDataDir: URL) {
        // Run synchronously to ensure locks are gone before we proceed with any new process
        let dbDir = relayDataDir.appendingPathComponent("data")
        
        // All known DB names (including blossom)
        let allDBs = ["chat", "inbox", "outbox", "private", "wot", "blossom"]
        let dbRoot = relayDataDir.appendingPathComponent("db")
        for name in allDBs {
            // Check data/NAME/LOCK
            removeLockFile(at: dbDir.appendingPathComponent(name).appendingPathComponent("LOCK"))
            // Check db/NAME/LOCK
            removeLockFile(at: dbRoot.appendingPathComponent(name).appendingPathComponent("LOCK"))
        }

        // Also check relayDataDir/blossom/LOCK (legacy path)
        removeLockFile(at: relayDataDir.appendingPathComponent("blossom").appendingPathComponent("LOCK"))
    }
    
    private nonisolated func removeLockFile(at url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
                // We minimize MainActor hops here by not logging DEBUG info for every lock check
            } catch {
            }
        }
    }
}
