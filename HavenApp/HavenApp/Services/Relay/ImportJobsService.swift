import Foundation
import Combine

/// The relay's import jobs (haven-go import_jobs.go): the list for the
/// Vault's "Still to bring in" card, Run / Cancel, and first run's setup job.
/// Re-reads the list on every `IMPORT_JOB` log line (RelayLogParser) and
/// every few seconds while a job runs, since imported notes reach the store
/// without a live broadcast.
@MainActor
final class ImportJobsService: ObservableObject {
    static let shared = ImportJobsService()

    @Published private(set) var list: ImportJobs.List?
    /// Setup's stage while first run is waiting on it.
    @Published private(set) var setupStage: ImportJobs.SetupStage = .starting
    /// The last Run that didn't start, in plain words.
    @Published var runRefusal: String?

    /// Setup was asked for and the wait for it is on.
    private var setupGeneration = 0
    private var pollTask: Task<Void, Never>?

    var runningJob: String? {
        guard let r = list?.running, !r.isEmpty else { return nil }
        return r
    }

    // MARK: Reading

    func refresh() {
        Task.detached {
            var json = ""
            if let c = ImportJobsC() {
                json = String(cString: c)
                free(c)
            }
            let parsed = ImportJobs.parse(json)
            await MainActor.run { self.apply(parsed) }
        }
    }

    private func apply(_ parsed: ImportJobs.List?) {
        guard let parsed else { return }
        if parsed != list { list = parsed }
        if setupGeneration > 0, let setup = parsed.job(ImportJobs.setup) {
            // A fresh Run's job still reads its last status until the engine
            // marks it running: only the IMPORT_JOB line or `running` moves
            // a first run on.
            if parsed.running == ImportJobs.setup || setup.status == "running" {
                setupStage = .running
            } else if setupStage == .running {
                setupStage = ImportJobs.setupStage(status: setup.status, reason: setup.reason)
            }
        }
        if runningJob != nil { startPolling() }
    }

    /// `IMPORT_JOB` lines from the relay log.
    func handle(_ lines: [ImportJobs.Line]) {
        for line in lines where line.name == ImportJobs.setup && setupGeneration > 0 {
            setupStage = ImportJobs.setupStage(status: line.status, reason: nil)
        }
        refresh()
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self else { return }
                self.refresh()
                if self.runningJob == nil && self.setupStage != .running { break }
            }
            self?.pollTask = nil
        }
    }

    // MARK: Run / Cancel

    @discardableResult
    func run(_ name: String) -> ImportJobs.RunResult {
        let code = name.withCString { RunImportJobC(UnsafeMutablePointer(mutating: $0)) }
        let result = ImportJobs.RunResult(rawValue: code) ?? .unknownJob
        switch result {
        case .started: runRefusal = nil
        case .busy: runRefusal = "Another item is bringing things in. Try again when it's done."
        case .relayNotRunning: runRefusal = "Start your vault first."
        case .unknownJob: runRefusal = "This version of the vault doesn't know that item."
        }
        refresh()
        startPolling()
        return result
    }

    func cancel(_ name: String) {
        _ = name.withCString { CancelImportJobC(UnsafeMutablePointer(mutating: $0)) }
        refresh()
    }

    // MARK: First run

    /// Asks the running relay for setup and follows it. Waits for the relay
    /// to come up (first run starts it) and retries while it isn't serving.
    func runSetup(relayManager: RelayProcessManager) {
        setupGeneration += 1
        let generation = setupGeneration
        setupStage = .starting
        Task { [weak self] in
            let deadline = Date().addingTimeInterval(Self.setupStartTimeout)
            while Date() < deadline {
                guard let self, generation == self.setupGeneration else { return }
                // The start was queued on the lifecycle chain: let it run.
                await relayManager.lifecycleChain.value
                if await relayManager.ensureRelayReady(timeout: 5) {
                    switch self.run(ImportJobs.setup) {
                    case .started:
                        self.setupStage = .running
                        return
                    case .busy:
                        // setup resumed by itself on this start, or a Vault
                        // item is running: wait for it, then ask again.
                        self.refresh()
                        if self.list?.running == ImportJobs.setup {
                            self.setupStage = .running
                            return
                        }
                    case .unknownJob:
                        self.setupStage = .couldNotFinish(reason: "unknown_job")
                        return
                    case .relayNotRunning:
                        break
                    }
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard let self, generation == self.setupGeneration else { return }
            self.runRefusal = nil
            self.setupStage = .couldNotFinish(reason: "could_not_start")
        }
    }

    /// First run is over (the user is in, or went another way).
    func endFirstRun() {
        setupGeneration = 0
        setupStage = .starting
    }

    /// Nothing took setup this long after it was asked for: Try again.
    static let setupStartTimeout: TimeInterval = 60
}
