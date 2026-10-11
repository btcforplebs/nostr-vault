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
    
    func importNotes(config: HavenConfig) {
        logStore.append(LogEntry(timestamp: Date(), level: "DEBUG", message: "importNotes called. Current State: \(state), isRunning: \(isRunning)"))
        
        // Strict guard: Must be idle and NOT running
        guard state == .idle && !isRunning else {
            if (state == .running || state == .booting) && isRunning {
                logStore.append(LogEntry(timestamp: Date(), level: "INFO", message: "Stopping running relay to start import..."))
                self.pendingImportConfig = config
                stopRelay()
            } else {
                logStore.append(LogEntry(timestamp: Date(), level: "WARN", message: "Cannot start import: current state is \(state) (running: \(isRunning))"))
            }
            return
        }
        
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
        
        RelayConfiguration.writeImportSeedRelays(config: config, under: relayDataDir)
        if let data = try? encoder.encode(config.activeBlastrRelays.isEmpty ? [] : config.activeBlastrRelays) { try? data.write(to: relayDataDir.appendingPathComponent(config.blastrRelaysFile)) }
        if let data = try? encoder.encode(config.dmRelays) { try? data.write(to: relayDataDir.appendingPathComponent("relays_dm.json")) }
        if let data = try? encoder.encode(config.whitelistedNpubs) { try? data.write(to: relayDataDir.appendingPathComponent("whitelisted_npubs.json")) }
        if let data = try? encoder.encode(config.allBlockedNpubsAcrossAccounts) { try? data.write(to: relayDataDir.appendingPathComponent("blacklisted_npubs.json")) }
        
        let envURL = relayDataDir.appendingPathComponent(".env")
        let envContent = generateMinimalEnv(config: config)
        try? envContent.write(to: envURL, atomically: true, encoding: .utf8)

        let configEnv = generateEnvDictionary(config: config)
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
                     
                     // When StartRelayC(1) returns, the import is fully complete!
                     DispatchQueue.main.async {
                         self.importCompletedSuccessfully()
                     }
                 }
             }
        }
    }
    
    private func importCompletedSuccessfully() {
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
