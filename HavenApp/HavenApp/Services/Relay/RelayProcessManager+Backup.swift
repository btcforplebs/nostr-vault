import Foundation
@preconcurrency import Dispatch
import Combine
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

extension RelayProcessManager {
    func generateMinimalEnv(config: HavenConfig) -> String {
        let relayDataDir = ConfigService.shared.relayDataDir
        let envDict = RelayConfiguration.generateEnvDictionary(config: config, relayDataDir: relayDataDir)
        return RelayConfiguration.formatEnvFile(from: envDict)
    }
    
    func generateEnvDictionary(config: HavenConfig) -> [String: String] {
        RelayConfiguration.generateEnvDictionary(config: config, relayDataDir: ConfigService.shared.relayDataDir)
    }

    // MARK: - Backup / Restore helpers

    /// Sets environment variables and writes config files so Go's loadConfig() works.
    private func prepareEnvForBackup(config: HavenConfig) {
        let relayDataDir = ConfigService.shared.relayDataDir

        // Ensure all DB directories exist before Go tries to open them
        RelayConfiguration.ensureDirectories(under: relayDataDir)

        // Write config files that Go reads from the working directory
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted

        RelayConfiguration.writeImportSeedRelays(config: config, under: relayDataDir)
        if let data = try? encoder.encode(config.dmRelays) {
            try? data.write(to: relayDataDir.appendingPathComponent("relays_dm.json"))
        }
        if let data = try? encoder.encode(config.vaultWhitelistNpubs) {
            try? data.write(to: relayDataDir.appendingPathComponent(config.whitelistedNpubsFile))
        }
        if let data = try? encoder.encode(config.allBlockedNpubsAcrossAccounts) {
            try? data.write(to: relayDataDir.appendingPathComponent(config.blacklistedNpubsFile))
        }

        let envURL = relayDataDir.appendingPathComponent(".env")
        let envContent = generateMinimalEnv(config: config)
        try? envContent.write(to: envURL, atomically: true, encoding: .utf8)

        let configEnv = generateEnvDictionary(config: config)
        for (key, value) in configEnv {
            setenv(key, value, 1)
        }

        FileManager.default.changeCurrentDirectoryPath(relayDataDir.path)
        captureOutput(in: relayDataDir)
    }

    /// Waits while the Go side's last stopped relay cycle is still shutting
    /// down (`RelayDrainingC`): StopRelayC returns after 2 s and hands
    /// stragglers to a reaper, and until they finish Go refuses every backup,
    /// restore and start. A second Import in one session met exactly that
    /// ("restore refused: the last relay cycle is still shutting down") and
    /// left the vault stopped. Same wait and bound as Android
    /// RelayDrainState. -> whether it finished.
    func waitForRelayDrain(maxWait: TimeInterval = RelayDrainWait.maxWait) async -> Bool {
        await RelayDrainWait.wait(maxWait: maxWait, isDraining: { RelayDrainingC() == 1 },
                                  sleep: { try? await Task.sleep(nanoseconds: $0) })
    }

    func runBackupExport(config: HavenConfig, outputPath: String, completion: @escaping @Sendable (Bool) -> Void) {
        enqueueLifecycle { [weak self] in
            guard let self else { return }
            // One busy flag: a running import owns the databases.
            guard !self.isVaultBusy else {
                self.addLog("Backup not made: the vault is busy (\(self.busyJob?.rawValue ?? "")); try again when it ends", level: "ERROR")
                completion(false)
                return
            }
            self.busyJob = .backingUp
            defer { if self.busyJob == .backingUp { self.busyJob = nil } }
            let wasRunning = self.isRunning
            if wasRunning { await self.performStop() }
            guard await self.waitForRelayDrain() else {
                self.addLog("Backup not made: the last relay run is still shutting down", level: "ERROR")
                completion(false)
                if wasRunning { await self.performStart(config: config, isRetry: true) }
                return
            }
            // Relay is confirmed down; any leftover LOCK is stale.
            self.performClearDatabaseLocks(at: ConfigService.shared.relayDataDir)
            self.prepareEnvForBackup(config: config)

            let success: Bool = await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    guard let cPath = strdup(outputPath) else {
                        continuation.resume(returning: false)
                        return
                    }
                    let result = BackupDatabaseC(cPath)
                    free(cPath)
                    continuation.resume(returning: result == 0)
                }
            }
            completion(success)
            if wasRunning {
                await self.performStart(config: config, isRetry: true)
            }
        }
    }

    /// The one restore (setup and Settings): refuses a backup with no event signed by the owner
    /// (code 2), so someone else's backup is never merged in. `completion`
    /// gets RestoreOwnBackupC's code: 0 ok, 1 failed, 2 not the owner's.
    func runOwnBackupRestore(config: HavenConfig, inputPath: String, completion: @escaping @Sendable (Int32) -> Void) {
        runRestore(config: config, inputPath: inputPath, restore: { RestoreOwnBackupC($0) }, completion: completion)
    }

    private func runRestore(config: HavenConfig, inputPath: String,
                            restore: @escaping @Sendable (UnsafeMutablePointer<CChar>) -> Int32,
                            completion: @escaping @Sendable (Int32) -> Void) {
        enqueueLifecycle { [weak self] in
            guard let self else { return }
            guard !self.isVaultBusy else {
                self.addLog("Restore not started: the vault is busy (\(self.busyJob?.rawValue ?? "")); try again when it ends", level: "ERROR")
                completion(1)
                return
            }
            self.busyJob = .restoring
            defer { if self.busyJob == .restoring { self.busyJob = nil } }
            let wasRunning = self.isRunning
            if wasRunning { await self.performStop() }
            guard await self.waitForRelayDrain() else {
                self.addLog("Restore not started: the last relay run is still shutting down", level: "ERROR")
                completion(1)
                if wasRunning { await self.performStart(config: config, isRetry: true) }
                return
            }
            self.performClearDatabaseLocks(at: ConfigService.shared.relayDataDir)
            self.prepareEnvForBackup(config: config)

            let code: Int32 = await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    guard let cPath = strdup(inputPath) else {
                        continuation.resume(returning: 1)
                        return
                    }
                    let result = restore(cPath)
                    free(cPath)
                    continuation.resume(returning: result)
                }
            }
            completion(code)
            if wasRunning {
                // Brief settle after a restore before reopening the DBs
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await self.performStart(config: config, isRetry: true)
            }
        }
    }
}
