import Foundation
@preconcurrency import Dispatch
import Combine
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

extension RelayProcessManager {
    /// Gracefully restart the relay by stopping and restarting it.
    /// Used for automatic recovery when blossom uploads to the local relay fail.
    /// Concurrent callers coalesce onto one in-flight restart, and a cooldown
    /// prevents restart storms — rapid stop/start cycling of the embedded Go
    /// relay is what used to corrupt BadgerDB and crash the app.
    func gracefulRestart() async -> Bool {
        if let inflight = inFlightRestart {
            return await inflight.value
        }
        if let last = lastRestartFinished, Date().timeIntervalSince(last) < Self.restartCooldown {
            logStore.append(LogEntry(timestamp: Date(), level: "WARN", message: "Automatic restart suppressed (cooldown) — waiting for relay readiness instead"))
            return await ensureRelayServing(timeout: 10.0)
        }
        #if os(macOS)
        if SleepWakeMonitor.shared.isInWakeGracePeriod {
            logStore.append(LogEntry(timestamp: Date(), level: "INFO", message: "Automatic restart skipped — system just woke from sleep; waiting for relay instead"))
            return await ensureRelayServing(timeout: 15.0)
        }
        #endif
        guard let config = lastConfig else {
            logStore.append(LogEntry(timestamp: Date(), level: "WARN", message: "Cannot restart: no saved config"))
            return false
        }

        logStore.append(LogEntry(timestamp: Date(), level: "INFO", message: "Graceful restart for blossom recovery..."))

        let restart = Task { @MainActor () -> Bool in
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.stopRelay {
                    continuation.resume()
                }
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self.startRelay(config: config, isRetry: true)
            // startRelay only queues the start. Until it has run, state is
            // still .idle and ensureRelayReady returns false at once, which
            // is how a post failed at :33 with the relay up at :34.
            await self.lifecycleChain.value
            return await self.ensureRelayServing(timeout: 30.0)
        }
        inFlightRestart = restart
        let result = await restart.value
        inFlightRestart = nil
        lastRestartFinished = Date()
        return result
    }

    func stopRelay(completion: (() -> Void)? = nil) {
        enqueueLifecycle { [weak self] in
            await self?.performStop()
            completion?()
        }
    }

    /// The actual stop sequence. Must only run on the lifecycle chain.
    /// Waits for StopRelayC to truly return — the old 5-second timeout that
    /// "force-reset" state and fired the completion early let callers start
    /// a new relay cycle while the Go side was still tearing down the old
    /// one, corrupting BadgerDB. Go-side shutdown is bounded (~5s worst
    /// case: 2s server shutdown + 2s goroutine drain + DB close), so
    /// waiting honestly cannot hang.
    func performStop() async {
        // Must check if running, booting, or importing
        guard self.isRunning || self.isBooting || self.isImporting else {
            self.state = .idle
            isRunning = false
            #if os(macOS)
            NetworkSyncService.shared.stop()
            #endif
            return
        }

        self.state = .stopping
        self.isShuttingDown = true
        self.isReadyForConnections = false
        self.readyForConnectionsTask?.cancel()
        stopLogThrottler()
        cancelBootWatchdog()
        isBooting = false
        isWotSyncing = false
        inboxSubscribed = false

        logStore.append(LogEntry(timestamp: Date(), level: "INFO", message: "Stopping C-Shared relay natively..."))

        // Watchdog: log-only. Never resets state or proceeds while the Go
        // side is still shutting down.
        let watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            guard let self, self.state == .stopping else { return }
            self.logStore.append(LogEntry(timestamp: Date(), level: "ERROR", message: "Relay stop exceeded 25s — still waiting for Go shutdown to finish. Quit and relaunch the app if this persists."))
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                // Tell the Go side to shut down the server, cancel the
                // context, drain background goroutines, and close the DBs.
                StopRelayC()
                // Brief settle so the OS fully releases DB file locks
                Thread.sleep(forTimeInterval: 0.5)
                continuation.resume()
            }
        }
        watchdog.cancel()

        logStore.append(LogEntry(timestamp: Date(), level: "INFO", message: "C-Shared relay natively stopped."))
        restoreOutput()
        endRelayActivity()
        state = .idle
        isRunning = false
        isWotSyncing = false
        inboxSubscribed = false
        // Cleared so the dashboard's uptime readout does not keep counting
        // against a run that has already ended.
        startDate = nil
        isShuttingDown = false
        #if os(macOS)
        NetworkSyncService.shared.stop()
        #endif

        // If we were stopping to start an import, trigger it now
        if let importConfig = pendingImportConfig {
            pendingImportConfig = nil
            importNotes(config: importConfig)
        }
    }
    
    /// Aggressively stop the relay, clear all database locks, reset state, and restart.
    /// This replaces the old "pkill -9 haven" manual step. Runs on the
    /// lifecycle chain: the LOCK files are deleted only after performStop
    /// has confirmed the in-process relay is fully down, so the clear can
    /// never hit a live BadgerDB instance.
    func forceCleanAndRestart() {
        logStore.append(LogEntry(timestamp: Date(), level: "INFO", message: "Force clean & restart initiated..."))
        let relayDataDir = ConfigService.shared.relayDataDir

        enqueueLifecycle { [weak self] in
            guard let self else { return }
            await self.performStop()
            self.performClearDatabaseLocks(at: relayDataDir)
            self.isLocked = false
            self.needsLockFix = false
            self.showProcessKillAlert = false

            self.logStore.append(LogEntry(timestamp: Date(), level: "INFO", message: "Cleanup complete. Restarting relay..."))

            if let config = self.lastConfig {
                await self.performStart(config: config, isRetry: true)
            }
        }
    }
}
