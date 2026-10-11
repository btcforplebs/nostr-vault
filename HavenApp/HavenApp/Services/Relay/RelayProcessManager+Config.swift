import Foundation
@preconcurrency import Dispatch
import Combine
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

extension RelayProcessManager {
    /// Whether the running relay would start differently from `config`.
    /// Only what the relay reads at start counts (see LaunchInputs), so
    /// theme, feed relays and other app-side settings never restart it.
    func needsRestart(for config: HavenConfig) -> Bool {
        guard isRunning, !isImporting, let running = lastConfig else { return false }
        let dir = ConfigService.shared.relayDataDir
        return RelayConfiguration.launchInputs(config: config, relayDataDir: dir)
            != RelayConfiguration.launchInputs(config: running, relayDataDir: dir)
    }

    /// Called after Settings saves. Restarts the relay in place when a
    /// relay-facing setting changed and does nothing otherwise. Saves
    /// coalesce: a restart waits for `applyQuietPeriod` without new saves and
    /// for `applyMinimumGap` after the previous restart, then applies only the
    /// latest config. Shares `inFlightRestart` so a Blossom recovery restart
    /// waits on this one instead of cycling the relay a second time.
    func applySavedConfig(_ config: HavenConfig) {
        pendingAppliedConfig = config
        lastApplyRequest = Date()
        guard applyConfigTask == nil else { return }
        applyConfigTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while self.pendingAppliedConfig != nil {
                // Wait until saves have gone quiet and the relay has had its
                // minimum rest since the last settings restart.
                while true {
                    let now = Date()
                    let quietLeft = Self.applyQuietPeriod - now.timeIntervalSince(self.lastApplyRequest)
                    let gapLeft = self.lastRestartFinished.map { Self.applyMinimumGap - now.timeIntervalSince($0) } ?? 0
                    let wait = max(quietLeft, gapLeft)
                    if wait <= 0 { break }
                    do {
                        try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    } catch {
                        // Cancelled: stop without restarting.
                        self.isApplyingConfig = false
                        self.applyConfigTask = nil
                        return
                    }
                }
                if let other = self.inFlightRestart { _ = await other.value }
                guard let next = self.pendingAppliedConfig else { break }
                self.pendingAppliedConfig = nil

                // An import stops the relay and restarts it from
                // pendingImportConfig when it ends; hand it the newer config
                // so the save is applied then rather than dropped.
                if self.isImporting {
                    if self.pendingImportConfig != nil {
                        self.pendingImportConfig = next
                        self.logStore.append(LogEntry(timestamp: Date(), level: "INFO", message: "Relay settings changed during import; they apply when the import ends"))
                    }
                    continue
                }
                guard self.needsRestart(for: next) else { continue }
                self.isApplyingConfig = true
                self.logStore.append(LogEntry(timestamp: Date(), level: "INFO", message: "Relay settings changed; restarting relay to apply them"))
                let restart = Task { @MainActor () -> Bool in
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        self.stopRelay { continuation.resume() }
                    }
                    self.startRelay(config: next)
                    await self.lifecycleChain.value  // see gracefulRestart
                    return await self.ensureRelayServing(timeout: 30.0)
                }
                self.inFlightRestart = restart
                _ = await restart.value
                self.inFlightRestart = nil
                self.lastRestartFinished = Date()
            }
            self.isApplyingConfig = false
            self.applyConfigTask = nil
        }
    }
}
