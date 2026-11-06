import Foundation
@preconcurrency import Dispatch
import Combine
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

/// One import request: what `importNotes` was asked for, carried through a
/// hold, a stop or a retry unchanged.
struct ImportRequest {
    let config: HavenConfig
    /// Relays read for this import only (setup's own servers, the other vault).
    let alsoFrom: [String]
    let listHistory: Bool
    /// The other vault's link address, for "Copy from my other vault".
    let otherVault: String?
    /// Refused starts already retried (ImportStartGate).
    var retries = 0

    /// The env key haven-go reads for `otherVault` (import_result.go).
    static let otherVaultEnv = "IMPORT_OTHER_VAULT_RELAY"
}

extension RelayProcessManager {
    /// An import, restore or backup owns the databases, or an import is
    /// between a refused start and its retry.
    var isVaultBusy: Bool { busyJob != nil || isImporting }

    /// Cancel: the Go side ends the import, its end handler reports
    /// "cancelled" and starts the relay again. A request still held or
    /// between retries simply stands down.
    func cancelImport() {
        importRequestGeneration += 1
        queuedImport = nil
        if state == .importing {
            importStatusMessage = "Cancelling import…"
            DispatchQueue.global().async { StopRelayC() }
            return
        }
        if isImporting { endImport(with: .cancelledBeforeStart) }
    }

    /// The import overlay's dismiss: a running import is cancelled; an ended
    /// one just leaves the screen.
    func dismissImport() {
        if state == .importing || isImporting {
            cancelImport()
        }
    }

    /// `alsoFrom`: relays read for this import only, on top of
    /// `config.importSeedRelays`; not saved (setup's own-servers read).
    /// `listHistory`: "Look up and back up my lists" was on (the switch's
    /// default; haven-go list_history_scan.go). `otherVault`: the paired
    /// device's address for "Copy from my other vault" (also in `alsoFrom`).
    /// -> false when refused: a copy (extra relays) can't join a running
    /// import, which would drop its relays.
    @discardableResult
    func importNotes(config: HavenConfig, alsoFrom: [String] = [], listHistory: Bool = false,
                     otherVault: String? = nil) -> Bool {
        logStore.append(LogEntry(timestamp: Date(), level: "DEBUG", message: "importNotes called. Current State: \(state), isRunning: \(isRunning)"))
        if isImporting && !alsoFrom.isEmpty {
            logStore.append(LogEntry(timestamp: Date(), level: "WARN", message: "Import with extra relays refused: an import is already running"))
            return false
        }
        importRequestGeneration += 1
        if !isImporting {
            importRequestedAt = Date()
            importEngineStarted = false
            importStartFailed = false
            importCompleted = false
            importOutcome = nil
        }
        requestImport(ImportRequest(config: config, alsoFrom: alsoFrom, listHistory: listHistory, otherVault: otherVault),
                      generation: importRequestGeneration, waits: 0)
        return true
    }

    /// Runs the request on the lifecycle chain, behind any start, stop,
    /// restore or backup already queued, so it sees a settled vault
    /// (ImportStartGate). Booting or stopping holds it.
    func requestImport(_ request: ImportRequest, generation: Int, waits: Int) {
        enqueueLifecycle { [weak self] in
            self?.beginImport(request, generation: generation, waits: waits)
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

    private func beginImport(_ request: ImportRequest, generation: Int, waits: Int) {
        // A newer importNotes call (or Cancel) owns the import now.
        guard generation == importRequestGeneration else { return }
        let config = request.config

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
                self?.requestImport(request, generation: generation, waits: waits + 1)
            }
            return
        case .stopThenStart:
            logStore.append(LogEntry(timestamp: Date(), level: "INFO", message: "Stopping running relay to start import..."))
            queuedImport = request
            stopRelay()
            return
        case .start:
            break
        }

        busyJob = .importing
        restartAfterImportConfig = config
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
        
        RelayConfiguration.writeImportSeedRelays(config: config, under: relayDataDir, alsoFrom: request.alsoFrom)
        if let data = try? encoder.encode(config.activeBlastrRelays.isEmpty ? [] : config.activeBlastrRelays) { try? data.write(to: relayDataDir.appendingPathComponent(config.blastrRelaysFile)) }
        if let data = try? encoder.encode(config.dmRelays) { try? data.write(to: relayDataDir.appendingPathComponent("relays_dm.json")) }
        if let data = try? encoder.encode(config.vaultWhitelistNpubs) { try? data.write(to: relayDataDir.appendingPathComponent("whitelisted_npubs.json")) }
        if let data = try? encoder.encode(config.allBlockedNpubsAcrossAccounts) { try? data.write(to: relayDataDir.appendingPathComponent("blacklisted_npubs.json")) }
        
        let envURL = relayDataDir.appendingPathComponent(".env")
        let envContent = generateMinimalEnv(config: config)
        try? envContent.write(to: envURL, atomically: true, encoding: .utf8)

        var configEnv = generateEnvDictionary(config: config)
        // Always set: the Go side keeps the process environment between imports.
        configEnv[ListHistoryScan.optInEnv] = request.listHistory ? "1" : "0"
        // Only the account moving in: never the device's other accounts.
        let movingIn = config.activeAccountNpub.isEmpty ? config.ownerNpub : config.activeAccountNpub
        configEnv[ListHistoryScan.accountEnv] = request.listHistory ? (Bech32.decode(movingIn)?.hexString ?? "") : ""
        // The paired device read for "Copy from my other vault", so the
        // result line can say whether it was reached (haven-go import_result.go).
        configEnv[ImportRequest.otherVaultEnv] = request.otherVault ?? ""
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
                guard self.state == .importing, generation == self.importRequestGeneration else {
                    // Cancelled before the Go side was called.
                    if self.state == .importing { self.state = .idle }
                    self.endImport(with: .cancelledBeforeStart)
                    return
                }
                self.logStore.append(LogEntry(timestamp: Date(), level: "INFO", message: "C-Shared Import sequence started"))

                DispatchQueue.global().async {
                    // 1 = importing mode. Returns when the import cycle is
                    // over, whatever happened; Go keeps that cycle's
                    // IMPORT_RESULT line for us (no log-pipe timing guess).
                    StartRelayC(1)
                    var line = ""
                    if let c = GetImportResultC() {
                        line = String(cString: c)
                        free(c)
                    }
                    let result = ImportResult.parse(line) ?? .noResult
                    DispatchQueue.main.async {
                        self.importCycleEnded(result, request: request, generation: generation)
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

    /// One import cycle ended. A start the Go side refused because the last
    /// cycle hadn't let go is tried again; anything else ends the import with
    /// what Go reported, and the relay starts again in every case.
    private func importCycleEnded(_ result: ImportResult, request: ImportRequest, generation: Int) {
        logStore.append(LogEntry(timestamp: Date(), level: result.isComplete ? "INFO" : "WARN",
                                 message: "Import ended: \(result.status.rawValue) (\(result.reasons.joined(separator: ",")))"))
        if state == .importing { state = .idle }
        if busyJob == .importing { busyJob = nil }
        if result.isRetryableStart, ImportStartGate.shouldRetry(retries: request.retries),
           generation == importRequestGeneration {
            logStore.append(LogEntry(timestamp: Date(), level: "WARN", message: "Import start refused; retrying (\(request.retries + 1) of \(ImportStartGate.maxRefusedRetries))"))
            var next = request
            next.retries += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + ImportStartGate.refusedRetryDelay) { [weak self] in
                self?.requestImport(next, generation: generation, waits: 0)
            }
            return
        }
        endImport(with: result)
    }

    /// Records how the import ended, says so honestly, and starts the relay
    /// again. Only a complete import counts as done ("Last ran").
    private func endImport(with result: ImportResult) {
        if busyJob == .importing { busyJob = nil }
        listHistoryScanning = false
        isImporting = false
        importOutcome = result
        switch result.status {
        case .complete:
            importProgress = 1.0
            importCompleted = true
            // One Import media when the first Moving in finishes.
            MediaImportAfterMovingIn.movingInCompleted()
        case .failed:
            importStartFailed = true
        case .partial, .cancelled:
            break
        }
        importStatusMessage = result.summary
        logStore.append(LogEntry(timestamp: Date(), level: "INFO", message: "Import process ended: \(result.summary)"))

        // A refused start never leaves the vault paused: it starts again with
        // the config it last ran with, even if this request had none queued.
        if let restartConfig = restartAfterImportConfig ?? (result.isRetryableStart ? lastConfig : nil) {
            restartAfterImportConfig = nil
            logStore.append(LogEntry(timestamp: Date(), level: "INFO", message: result.isRetryableStart
                ? "Import refused (the last vault run was still shutting down); starting the vault again"
                : "Import ended, restarting relay..."))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.startRelay(config: restartConfig)
            }
        }
    }
}
