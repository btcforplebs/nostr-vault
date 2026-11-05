import Foundation
@preconcurrency import Dispatch
import Combine
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

extension RelayProcessManager {
    func cancelImport() {
        if self.isImporting || self.isRunning {
             DispatchQueue.global().async {
                 StopRelayC()
             }
        }
        isImporting = false
        DispatchQueue.main.async {
            self.isImporting = false
            self.listHistoryScanning = false
            self.importProgress = 0.0
            self.importStatusMessage = "Import cancelled"
            self.pendingImportConfig = nil
        }
    }
    
    func dismissImport() {
        if self.isImporting || self.isRunning {
             DispatchQueue.global().async {
                 StopRelayC()
             }
        }
        DispatchQueue.main.async {
            self.isImporting = false
            // If we were waiting to restart, do it now
            if let config = self.pendingImportConfig {
                self.pendingImportConfig = nil
                self.startRelay(config: config)
            }
        }
    }
    
    
    /// Kills any existing haven processes and clears database locks before import
    // Note: Replaced by forceCleanLocks() but kept as stub if needed for future refactoring, 
    // or we can remove it. For now, we will use forceCleanLocks() instead.
    // The usages below will be updated.
    
    /// `alsoFrom`: relays read for this import only, on top of
    /// `config.importSeedRelays`; not saved (setup's own-servers read).
    /// `listHistory`: "Look up and back up my lists" was on (the switch's
    /// default; haven-go list_history_scan.go).
    func importNotes(config: HavenConfig, alsoFrom: [String] = [], listHistory: Bool = false) {
        logStore.append(LogEntry(timestamp: Date(), level: "DEBUG", message: "importNotes called. Current State: \(state), isRunning: \(isRunning)"))
        importRequestGeneration += 1
        if !isImporting {
            importRequestedAt = Date()
            importEngineStarted = false
            importStartFailed = false
        }
        requestImport(config: config, alsoFrom: alsoFrom, listHistory: listHistory,
                      generation: importRequestGeneration, waits: 0, retries: 0)
    }

    /// Runs the request on the lifecycle chain, behind any start or stop
    /// already queued, so it sees a settled vault (ImportStartGate). Booting
    /// or stopping holds it; it used to be dropped there with a WARN.
    func requestImport(config: HavenConfig, alsoFrom: [String], listHistory: Bool,
                       generation: Int, waits: Int, retries: Int) {
        enqueueLifecycle { [weak self] in
            self?.beginImport(config: config, alsoFrom: alsoFrom, listHistory: listHistory,
                              generation: generation, waits: waits, retries: retries)
        }
    }

    private var gateVault: ImportStartGate.Vault {
        switch state {
        case .idle: return .idle
        case .booting: return .booting
        case .running: return .running
        case .stopping: return .stopping
        case .importing: return .importing
        }
    }

    private func beginImport(config: HavenConfig, alsoFrom: [String], listHistory: Bool,
                             generation: Int, waits: Int, retries: Int) {
        // A newer importNotes call owns the import now.
        guard generation == importRequestGeneration else { return }

        switch ImportStartGate.action(vault: gateVault, isRunning: isRunning, isShuttingDown: isShuttingDown) {
        case .alreadyImporting:
            logStore.append(LogEntry(timestamp: Date(), level: "INFO", message: "Import already running; this request joins it"))
            return
        case .wait:
            guard waits < ImportStartGate.maxWaits else {
                logStore.append(LogEntry(timestamp: Date(), level: "WARN", message: "Import gave up waiting: vault stayed \(state) (running: \(isRunning))"))
                importStartFailed = true
                importStatusMessage = ImportStartGate.couldNotStart
                return
            }
            if waits == 0 {
                logStore.append(LogEntry(timestamp: Date(), level: "INFO", message: "Import held: vault is \(state) (running: \(isRunning))"))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + ImportStartGate.waitInterval) { [weak self] in
                self?.requestImport(config: config, alsoFrom: alsoFrom, listHistory: listHistory,
                                    generation: generation, waits: waits + 1, retries: retries)
            }
            return
        case .stopThenStart:
            logStore.append(LogEntry(timestamp: Date(), level: "INFO", message: "Stopping running relay to start import..."))
            self.pendingImportConfig = config
            self.pendingImportAlsoFrom = alsoFrom
            self.pendingImportListHistory = listHistory
            self.pendingImportRetries = retries
            stopRelay()
            return
        case .start:
            break
        }

        importRefusal = nil
        self.pendingImportConfig = config
        self.state = .importing
        isRunning = false
        isBooting = false
        isImporting = true
        #if os(macOS)
        NetworkSyncService.shared.stop()
        #endif
        // Reset the log-based event counter so import counts don't
        // carry over and corrupt the post-import stats refresh.
        eventsStored = 0
        newActivityModes = []

        let relayDataDir = ConfigService.shared.relayDataDir
        RelayConfiguration.ensureDirectories(under: relayDataDir)
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        
        RelayConfiguration.writeImportSeedRelays(config: config, under: relayDataDir, alsoFrom: alsoFrom)
        if let data = try? encoder.encode(config.activeBlastrRelays.isEmpty ? [] : config.activeBlastrRelays) { try? data.write(to: relayDataDir.appendingPathComponent(config.blastrRelaysFile)) }
        if let data = try? encoder.encode(config.dmRelays) { try? data.write(to: relayDataDir.appendingPathComponent("relays_dm.json")) }
        if let data = try? encoder.encode(config.whitelistedNpubs) { try? data.write(to: relayDataDir.appendingPathComponent("whitelisted_npubs.json")) }
        if let data = try? encoder.encode(config.allBlockedNpubsAcrossAccounts) { try? data.write(to: relayDataDir.appendingPathComponent("blacklisted_npubs.json")) }
        
        let envURL = relayDataDir.appendingPathComponent(".env")
        let envContent = generateMinimalEnv(config: config)
        try? envContent.write(to: envURL, atomically: true, encoding: .utf8)

        var configEnv = generateEnvDictionary(config: config)
        // Always set: the Go side keeps the process environment between imports.
        configEnv[ListHistoryScan.optInEnv] = listHistory ? "1" : "0"
        // Only the account moving in: never the device's other accounts.
        let movingIn = config.activeAccountNpub.isEmpty ? config.ownerNpub : config.activeAccountNpub
        configEnv[ListHistoryScan.accountEnv] = listHistory ? (Bech32.decode(movingIn)?.hexString ?? "") : ""
        listHistoryScanning = false
        listHistoryNote = nil
        for (key, value) in configEnv {
            setenv(key, value, 1)
            if let cKey = strdup(key), let cValue = strdup(value) {
                SetHavenEnvC(cKey, cValue)
                free(cKey)
                free(cValue)
            }
        }

        FileManager.default.changeCurrentDirectoryPath(relayDataDir.path)
        captureOutput(in: relayDataDir)

        DispatchQueue.main.async {
            self.importProgress = 0.0
            self.importStatusMessage = "Starting import for \(config.ownerNpub.prefix(12))..."
        }
        
        clearDatabaseLocks { [weak self] in
             Task { @MainActor in
                 guard let self = self else { return }
                 if self.state != .importing { return }
                 
                 self.logStore.append(LogEntry(timestamp: Date(), level: "INFO", message: "C-Shared Import sequence started"))
                 
                 DispatchQueue.global().async {
                     // 1 = true (importing mode)
                     StartRelayC(1)
                     
                     // StartRelayC(1) returns when the import is over, or at
                     // once when the Go side refused it. The refusal line
                     // comes through the log pipe; give it a moment to land.
                     DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                         self.importCycleEnded(config: config, alsoFrom: alsoFrom, listHistory: listHistory,
                                               generation: generation, retries: retries)
                     }
                 }
             }
        }
    }
    
    /// Moving in's Skip: stop the list history scan, keep what it found; the
    /// import carries on.
    func skipListHistoryScan() {
        listHistoryScanning = false
        DispatchQueue.global().async { _ = SkipListHistoryScanC() }
    }

    /// A refused start is retried (ImportStartGate); anything else ends the
    /// import as before.
    private func importCycleEnded(config: HavenConfig, alsoFrom: [String], listHistory: Bool,
                                  generation: Int, retries: Int) {
        guard !importEngineStarted, let refusal = importRefusal else {
            importCompletedSuccessfully()
            return
        }
        importRefusal = nil
        state = .idle
        if ImportStartGate.shouldRetry(refusal, retries: retries), generation == importRequestGeneration {
            logStore.append(LogEntry(timestamp: Date(), level: "WARN", message: "Import start refused; retrying (\(retries + 1) of \(ImportStartGate.maxRefusedRetries))"))
            DispatchQueue.main.asyncAfter(deadline: .now() + ImportStartGate.refusedRetryDelay) { [weak self] in
                self?.requestImport(config: config, alsoFrom: alsoFrom, listHistory: listHistory,
                                    generation: generation, waits: 0, retries: retries + 1)
            }
            return
        }
        logStore.append(LogEntry(timestamp: Date(), level: "WARN", message: "Import did not start; the relay comes back without it"))
        listHistoryScanning = false
        isImporting = false
        importStartFailed = true
        importStatusMessage = ImportStartGate.couldNotStart
        if let restartConfig = pendingImportConfig {
            pendingImportConfig = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.startRelay(config: restartConfig)
            }
        }
    }

    private func importCompletedSuccessfully() {
        self.listHistoryScanning = false
        self.isImporting = false
        self.importProgress = 1.0
        self.importStatusMessage = "Import Complete!"
        self.importCompleted = true
        self.state = .idle

        self.logStore.append(LogEntry(timestamp: Date(), level: "INFO", message: "Import process terminated successfully."))

        if let restartConfig = self.pendingImportConfig {
            self.pendingImportConfig = nil
            self.logStore.append(LogEntry(timestamp: Date(), level: "INFO", message: "Import successful, restarting relay..."))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.startRelay(config: restartConfig)
            }
        }
    }
}
