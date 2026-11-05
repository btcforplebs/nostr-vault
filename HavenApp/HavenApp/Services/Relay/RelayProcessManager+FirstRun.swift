import Foundation

/// First run on the jobs engine (haven-go import_jobs.go, Logen 2026-11-05):
/// the relay starts normally with HAVEN_FIRST_RUN=1 and keeps serving, and
/// the `setup` job brings in their own notes, follows and current lists.
/// No import mode (`StartRelayC(1)`), no stopped vault.
/// Contract: PLANS/NV_FIRST_RUN_ENTRY_PLAN_2026_11_05.md, "Calling order".
extension RelayProcessManager {
    /// Starts (or restarts, so the seeds and owner are this run's) the relay
    /// for first run, then asks it for setup. `alsoFrom`: relays setup also
    /// reads (their own servers, the other vault's link), not saved.
    func startFirstRun(config: HavenConfig, alsoFrom: [String] = []) {
        firstRunAlsoFrom = alsoFrom
        logStore.append(LogEntry(timestamp: Date(), level: "INFO", message: "First run: starting the vault for setup (\(alsoFrom.count) extra relays)"))
        if isRunning || state == .booting {
            stopRelay { [weak self] in self?.startRelay(config: config) }
        } else {
            startRelay(config: config)
        }
        ImportJobsService.shared.runSetup(relayManager: self)
    }

    /// Setup let them in (or they left first run): later starts are normal.
    /// The relay keeps running; a cut setup resumes on the next start anyway.
    func endFirstRun() {
        firstRunAlsoFrom = nil
        ImportJobsService.shared.endFirstRun()
    }

    /// Cancel on first run's "Bringing in your notes".
    func cancelFirstRunSetup() {
        ImportJobsService.shared.cancel(ImportJobs.setup)
    }
}
