import Foundation
@preconcurrency import Dispatch
import Combine
import UniformTypeIdentifiers

// Broad MIME types that allow more specific refinements from relay metadata
private let mimeSubsetRules: [String: Set<String>] = [
    "application/zip": [
        "application/vnd.android.package-archive",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "application/java-archive",
    ],
    "video/mp4": [
        "audio/mp4", "audio/x-m4a", "audio/aac",
    ],
    "application/octet-stream": [], // empty set = allow anything
]

@MainActor
class RelayProcessManager: ObservableObject {
    static let shared = RelayProcessManager()
    enum RelayState {
        case idle
        case booting
        case running
        case stopping
        case importing
    }
    
    @Published var state: RelayState = .idle
    @Published var isRunning = false
    @Published var isBooting = false
    @Published var isWotSyncing = false
    @Published var isImporting = false
    @Published var importCompleted = false
    @Published var isLocked = false
    @Published var isPortConflict = false
    @Published var bootStatusMessage: String = ""
    @Published var importStatusMessage: String = ""
    @Published var importProgress: Double = 0.0
    
    /// Feed connections should wait until relay is fully ready.
    /// Set `true` 3 seconds after relay reaches `.running` state.
    @Published var isReadyForConnections = false
    private var readyForConnectionsTask: Task<Void, Never>?

    // Critical recovery alert
    @Published var showProcessKillAlert = false
    
    /// Logs are in a separate observable so only LogsView redraws on log changes.
    let logStore = LogStore()

    // Metrics
    @Published var memoryUsage: Double = 0
    @Published var cpuUsage: Double = 0
    @Published var activeConnections: Int = 0
    @Published var eventsStored: Int = 0
    /// Red dot: true only when events from OTHERS arrive in your inbox/chat relay.
    @Published var hasNewRelayActivity: Bool = false

    private var outputPipe: Pipe?
    private var stderrPipe: Pipe?
    private var savedStdout: Int32 = -1
    private var savedStderr: Int32 = -1
    private var logBuffer = Data() // Buffer for incomplete log lines
    
    // Track if we are in the middle of a shutdown to prevent recursive restarts
    private var isShuttingDown: Bool = false
    
    // Background log processing
    private let logProcessingQueue = DispatchQueue(label: "com.haven.relay.logs", qos: .utility)
    
    private var pendingImportConfig: HavenConfig?
    @Published var startDate: Date?
    
    // Auto-fix locks
    @Published var lastConfig: HavenConfig?
    private var retryAttempted = false
    private var needsLockFix = false

    // Boot watchdog: triggers force restart offer if boot takes too long
    private var bootWatchdogTimer: DispatchSourceTimer?
    private static let bootWatchdogTimeout: TimeInterval = 90

    // MARK: - Lifecycle serialization

    /// All start/stop/restart/backup operations run strictly one-at-a-time,
    /// in enqueue order. Overlapping a start with a still-running stop used
    /// to race the Go side's lifecycle globals and corrupt BadgerDB.
    private var lifecycleChain: Task<Void, Never> = Task {}

    /// Coalescing/cooldown for automatic recovery restarts (Blossom upload
    /// failures). Each restart cycles the embedded Go relay and BadgerDB;
    /// concurrent or rapid-fire restarts are what used to crash the app.
    private var inFlightRestart: Task<Bool, Never>?
    private var lastRestartFinished: Date?
    private static let restartCooldown: TimeInterval = 60

    /// BadgerDB LOCK files are only known-stale on the first start after
    /// process launch. Later in the app's lifetime a LOCK file can belong
    /// to a live in-process Badger instance; deleting it would let two
    /// instances open the same directory and silently corrupt it.
    private var hasClearedLocksThisLaunch = false

    /// App Nap suppression token, held while the relay is running so macOS
    /// doesn't throttle the embedded Go runtime's timers and sockets.
    private var relayActivityToken: NSObjectProtocol?

    private func beginRelayActivity() {
        guard relayActivityToken == nil else { return }
        relayActivityToken = ProcessInfo.processInfo.beginActivity(
            options: [.background, .suddenTerminationDisabled],
            reason: "Haven relay serving connections")
    }

    private func endRelayActivity() {
        if let token = relayActivityToken {
            ProcessInfo.processInfo.endActivity(token)
            relayActivityToken = nil
        }
    }

    // (Log throttling moved to LogStore)

    /// Whether the UI is actively visible (popover open / window focused).
    /// When false, background log processing skips LogEntry creation and
    /// non-critical @Published updates to reduce CPU and SwiftUI churn.
    nonisolated(unsafe) private(set) var isUIActive = true

    /// Call when the menu-bar popover closes or app resigns active.
    func enterBackground() {
        guard isUIActive else { return }
        isUIActive = false
        logStore.stopThrottler()
        // Hand back whatever the last sync/import round left on the Go heap.
        // Off the main thread on purpose: FreeOSMemory runs a full GC (tens to
        // hundreds of ms), and blocking cgo calls on the main thread are what
        // the 0x8BADF00D watchdog kills look like.
        DispatchQueue.global(qos: .utility).async {
            TrimMemoryC()
        }
        #if DEBUG
        print("RelayProcessManager: entering background mode")
        #endif
    }

    /// Call when the menu-bar popover opens or app becomes active.
    func enterForeground() {
        guard !isUIActive else { return }
        isUIActive = true
        logStore.startThrottler()
        #if DEBUG
        print("RelayProcessManager: entering foreground mode")
        #endif
    }
    
    typealias LogEntry = RelayLogParser.LogEntry
    
    func markRelayViewed() {
        hasNewRelayActivity = false
    }

    /// Enqueue a lifecycle operation behind all previously enqueued ones.
    /// Serialization guarantees a start can never overlap an in-flight stop.
    private func enqueueLifecycle(_ op: @escaping @MainActor () async -> Void) {
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
    private func performStart(config: HavenConfig, isRetry: Bool) async {
        // Strict guard: Must be idle, not running, and not in the middle of a shutdown
        guard state == .idle && !isRunning && !isShuttingDown else {
            logStore.append(LogEntry(timestamp: Date(), level: "WARN", message: "Cannot start relay: current state is \(state) (running: \(isRunning), shuttingDown: \(isShuttingDown))"))
            return
        }

        // Immediately claim the state so no second call can slip through.
        self.state = .booting
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
        
        RelayConfiguration.writeImportSeedRelays(config: config, under: relayDataDir)
        
        let blastrRelaysURL = relayDataDir.appendingPathComponent(config.blastrRelaysFile)
        if let data = try? encoder.encode(config.activeBlastrRelays) {
            try? data.write(to: blastrRelaysURL)
        }

        let dmRelaysURL = relayDataDir.appendingPathComponent("relays_dm.json")
        if let data = try? encoder.encode(config.dmRelays) {
            try? data.write(to: dmRelaysURL)
        }

        // Write whitelisted_npubs.json (Required by new binary)
        let whitelistURL = relayDataDir.appendingPathComponent("whitelisted_npubs.json")
        if let data = try? encoder.encode(config.whitelistedNpubs) {
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
        let configEnv = generateEnvDictionary(config: config)
        for (key, value) in configEnv {
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
    
    private nonisolated func performClearDatabaseLocks(at relayDataDir: URL) {
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
    
    /// Waits for the relay to be ready (running, not booting).
    /// Returns true if ready, false on timeout or if relay is idle/stopping.
    func ensureRelayReady(timeout: TimeInterval = 15.0) async -> Bool {
        if isRunning && !isBooting { return true }
        if state == .idle || state == .stopping { return false }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isRunning && !isBooting { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return isRunning && !isBooting
    }

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
            return await ensureRelayReady(timeout: 10.0)
        }
        #if os(macOS)
        if SleepWakeMonitor.shared.isInWakeGracePeriod {
            logStore.append(LogEntry(timestamp: Date(), level: "INFO", message: "Automatic restart skipped — system just woke from sleep; waiting for relay instead"))
            return await ensureRelayReady(timeout: 15.0)
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
            return await self.ensureRelayReady(timeout: 30.0)
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
    private func performStop() async {
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
    

    // MARK: - Boot Watchdog

    private func startBootWatchdog() {
        cancelBootWatchdog()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.bootWatchdogTimeout)
        timer.setEventHandler { [weak self] in
            guard let self = self, self.isBooting else { return }
            self.logStore.append(LogEntry(timestamp: Date(), level: "WARN", message: "Boot watchdog triggered after \(Int(Self.bootWatchdogTimeout))s — offering force restart"))
            self.showProcessKillAlert = true
        }
        timer.resume()
        bootWatchdogTimer = timer
    }

    private func cancelBootWatchdog() {
        bootWatchdogTimer?.cancel()
        bootWatchdogTimer = nil
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
        hasNewRelayActivity = false

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
    
    /// Persistent file handle for relay.log — opened once, reused for the
    /// lifetime of the pipe to avoid file-descriptor churn.
    private var logFileHandle: FileHandle?

    /// Redirection mechanism for capturing stdout and stderr from C-Shared bindings
    private func captureOutput(in directory: URL) {
        if outputPipe == nil {
            let pipe = Pipe()
            outputPipe = pipe

            // Save original FDs so they can be restored when the relay stops
            savedStdout = dup(STDOUT_FILENO)
            savedStderr = dup(STDERR_FILENO)

            // Redirect STDOUT to main pipe; give STDERR its own pipe so
            // heavy logging on both channels can't fill a single buffer
            // and deadlock Go goroutines.
            dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)

            let errPipe = Pipe()
            stderrPipe = errPipe
            dup2(errPipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)

            // Drain stderr into the same log file / processing path
            errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                self?.logProcessingQueue.async {
                    // Merge stderr data into the main pipe's handler by writing
                    // it to the log file directly; the main pipe handles parsing.
                    try? pipe.fileHandleForWriting.write(contentsOf: data)
                }
            }

            // Open a persistent file handle for the log file. Rotate first
            // when large — the log is append-only and a menu-bar app can run
            // for months between launches.
            let logFileURL = directory.appendingPathComponent("relay.log")
            let maxLogSize = 5 * 1024 * 1024
            if let size = (try? FileManager.default.attributesOfItem(atPath: logFileURL.path))?[.size] as? Int,
               size > maxLogSize {
                let rotatedURL = directory.appendingPathComponent("relay.log.1")
                try? FileManager.default.removeItem(at: rotatedURL)
                try? FileManager.default.moveItem(at: logFileURL, to: rotatedURL)
            }
            if !FileManager.default.fileExists(atPath: logFileURL.path) {
                FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
            }
            logFileHandle = try? FileHandle(forWritingTo: logFileURL)
            logFileHandle?.seekToEndOfFile()

            // Safety cap: if the buffer grows beyond 512 KB (e.g. the main
            // thread can't keep up), drop data to prevent unbounded memory
            // growth and pipe backpressure that can deadlock Go goroutines.
            let maxBufferSize = 512 * 1024

            // Capture file handle outside the Sendable closure to avoid
            // referencing @MainActor-isolated property from background queue.
            let fileHandle = logFileHandle

            // Use NSLock-protected buffer to avoid data races — the
            // readabilityHandler can fire on an arbitrary thread and the
            // logProcessingQueue serialises processing, but Swift's closure
            // capture of a mutable local var is not concurrency-safe.
            let bufferLock = NSLock()
            var localBuffer = Data()

            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }

                // Process output on a serial background queue to keep MainActor free
                self?.logProcessingQueue.async {
                    // Write to persistent log file
                    fileHandle?.write(data)

                    bufferLock.lock()
                    defer { bufferLock.unlock() }
                    localBuffer.append(data)

                    // Safety valve: drop oldest data if buffer grows too large
                    if localBuffer.count > maxBufferSize {
                        let dropTarget = localBuffer.count - maxBufferSize / 2
                        if let nl = localBuffer[dropTarget...].firstIndex(of: 0x0A) {
                            localBuffer = localBuffer.subdata(in: localBuffer.index(after: nl)..<localBuffer.endIndex)
                        } else {
                            localBuffer.removeAll()
                        }
                    }

                    // Find the last newline character
                    guard let range = localBuffer.range(of: Data([0x0A]), options: .backwards) else {
                        return
                    }

                    // Extract all complete lines
                    let validData = localBuffer.subdata(in: 0..<range.upperBound)

                    // Keep the remainder in the buffer
                    localBuffer = localBuffer.subdata(in: range.upperBound..<localBuffer.endIndex)

                    if let output = String(data: validData, encoding: .utf8) {
                        self?.processOutputInBackground(output)
                    }
                }
            }
        }
    }

    /// Restores stdout/stderr to their original file descriptors and tears down the pipe.
    private func restoreOutput() {
        if savedStdout >= 0 {
            dup2(savedStdout, STDOUT_FILENO)
            close(savedStdout)
            savedStdout = -1
        }
        if savedStderr >= 0 {
            dup2(savedStderr, STDERR_FILENO)
            close(savedStderr)
            savedStderr = -1
        }
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe = nil
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        logFileHandle = nil
    }

    func generateMinimalEnv(config: HavenConfig) -> String {
        let relayDataDir = ConfigService.shared.relayDataDir
        let envDict = RelayConfiguration.generateEnvDictionary(config: config, relayDataDir: relayDataDir)
        return RelayConfiguration.formatEnvFile(from: envDict)
    }
    
    private typealias BatchedStateUpdate = RelayLogParser.BatchedStateUpdate

    private nonisolated func processOutputInBackground(_ output: String) {
        let lines = output.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard !lines.isEmpty else { return }

        var batch = BatchedStateUpdate()
        for line in lines {
            RelayLogParser.collectStateChanges(from: line, into: &batch)
        }

        // When the UI is hidden (popover closed), skip LogEntry creation
        // and non-critical @Published updates to save CPU and memory.
        let active = self.isUIActive
        if active {
            var newEntries: [LogEntry] = []
            newEntries.reserveCapacity(lines.count)
            for line in lines {
                newEntries.append(LogEntry.parse(line))
            }
            Task { @MainActor in
                self.logStore.enqueue(newEntries)
                self.applyBatchedUpdate(batch)
            }
        } else {
            // Only dispatch for critical state changes (errors, boot/import completion,
            // or local notification markers which must fire even when UI is hidden).
            let hasCritical = batch.isLocked || batch.isPortConflict
                || batch.stopBooting || batch.stopImporting
                || batch.eventsStoredDelta != 0
                || !batch.notifyMarkers.isEmpty
            if hasCritical {
                Task { @MainActor in
                    self.applyBatchedUpdate(batch)
                }
            }
        }
    }


    /// Apply all accumulated state changes in a single MainActor pass.
    private func applyBatchedUpdate(_ batch: BatchedStateUpdate) {
        // Import state
        if isImporting {
            if let dateStr = batch.progressDateStr {
                calculateProgress(currentDateStr: dateStr)
            }
            if batch.progressBump {
                importProgress = min(importProgress + 0.03, 0.85)
            }
            if let progress = batch.importProgress {
                importProgress = progress
            }
            if let status = batch.importStatusMessage {
                importStatusMessage = status
            }
            if batch.stopImporting {
                isImporting = false
                importCompleted = true
            }
        }

        // Boot state
        if isBooting || isWotSyncing {
            if let status = batch.bootStatusMessage {
                bootStatusMessage = status
            }
            if batch.stopBooting {
                isBooting = false
                state = .running  // Transition from .booting to .running
                bootStatusMessage = ""
                isWotSyncing = true  // Relay is up, WoT may still be syncing
                cancelBootWatchdog()
                #if os(macOS)
                NetworkSyncService.shared.start()
                #endif

                // Staggered startup: delay feed connections by 3s so relay stabilises first
                readyForConnectionsTask?.cancel()
                readyForConnectionsTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    guard !Task.isCancelled else { return }
                    isReadyForConnections = true
                }
            }
        }

        // WoT sync completion (outside isBooting guard since boot already ended)
        if batch.stopWotSyncing {
            isWotSyncing = false
            bootStatusMessage = ""
        }

        // Metrics
        if batch.eventsStoredDelta != 0 {
            eventsStored += batch.eventsStoredDelta
        }
        // Red dot reflects only inbound activity from OTHERS (events tagging you /
        // DMs) — never your own posts, blasts, or private/outbox writes.
        if batch.inboxActivityDelta > 0 {
            hasNewRelayActivity = true
        }
        if batch.connectionsDelta != 0 {
            activeConnections = max(0, activeConnections + batch.connectionsDelta)
        }

        // Error states
        if batch.isLocked {
            isLocked = true
            needsLockFix = true
        }
        if batch.isPortConflict {
            isPortConflict = true
        }

        // Local notifications — forward NOTIFY markers to LocalNotificationService.
        // Only compiled for iOS; macOS uses the push server path.
        #if os(iOS)
        for marker in batch.notifyMarkers {
            LocalNotificationService.shared.handle(marker)
        }
        #endif
    }

    private func startLogThrottler() {
        logStore.startThrottler()
    }

    private func stopLogThrottler() {
        logStore.stopThrottler()
    }


    
    private func calculateProgress(currentDateStr: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        if let currentDate = formatter.date(from: currentDateStr),
           let pending = pendingImportConfig,
           let start = formatter.date(from: pending.importStartDate) {
            let totalInterval = Date().timeIntervalSince(start)
            let currentInterval = currentDate.timeIntervalSince(start)
            if totalInterval > 0 {
                let completion = currentInterval / totalInterval
                let scaled = 0.1 + (completion * 0.8)
                importProgress = min(max(scaled, 0.1), 0.9)
            }
        }
    }
    
    private func generateEnvDictionary(config: HavenConfig) -> [String: String] {
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
        if let data = try? encoder.encode(config.whitelistedNpubs) {
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

    func runBackupExport(config: HavenConfig, outputPath: String, completion: @escaping @Sendable (Bool) -> Void) {
        enqueueLifecycle { [weak self] in
            guard let self else { return }
            let wasRunning = self.isRunning
            if wasRunning { await self.performStop() }
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

    func runBackupRestore(config: HavenConfig, inputPath: String, completion: @escaping @Sendable (Bool) -> Void) {
        enqueueLifecycle { [weak self] in
            guard let self else { return }
            let wasRunning = self.isRunning
            if wasRunning { await self.performStop() }
            self.performClearDatabaseLocks(at: ConfigService.shared.relayDataDir)
            self.prepareEnvForBackup(config: config)

            let success: Bool = await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    guard let cPath = strdup(inputPath) else {
                        continuation.resume(returning: false)
                        return
                    }
                    let result = RestoreDatabaseC(cPath)
                    free(cPath)
                    continuation.resume(returning: result == 0)
                }
            }
            completion(success)
            if wasRunning {
                // Brief settle after a restore before reopening the DBs
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await self.performStart(config: config, isRetry: true)
            }
        }
    }

    func runBackupToCloud(config: HavenConfig) {
        enqueueLifecycle { [weak self] in
            guard let self else { return }
            let wasRunning = self.isRunning
            if wasRunning { await self.performStop() }
            self.performClearDatabaseLocks(at: ConfigService.shared.relayDataDir)
            self.prepareEnvForBackup(config: config)

            let success: Bool = await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    continuation.resume(returning: BackupToCloudC() == 0)
                }
            }
            let msg = success ? "Cloud backup complete" : "Cloud backup failed"
            self.logStore.append(LogEntry(timestamp: Date(), level: success ? "INFO" : "ERROR", message: msg))
            if wasRunning {
                await self.performStart(config: config, isRetry: true)
            }
        }
    }

    func runRestoreFromCloud(config: HavenConfig) {
        enqueueLifecycle { [weak self] in
            guard let self else { return }
            let wasRunning = self.isRunning
            if wasRunning { await self.performStop() }
            self.performClearDatabaseLocks(at: ConfigService.shared.relayDataDir)
            self.prepareEnvForBackup(config: config)

            let success: Bool = await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    continuation.resume(returning: RestoreFromCloudC() == 0)
                }
            }
            let msg = success ? "Cloud restore complete" : "Cloud restore failed"
            self.logStore.append(LogEntry(timestamp: Date(), level: success ? "INFO" : "ERROR", message: msg))
            if wasRunning {
                await self.performStart(config: config, isRetry: true)
            }
        }
    }
    
    // MARK: - Blossom Backup
    
    func runBlossomBackup(config: HavenConfig, outputPath: String, completion: @escaping @Sendable (Bool) -> Void) {
        let blossomDir = ConfigService.shared.relayDataDir.appendingPathComponent(config.blossomPath)
        
        // Ensure blossom directory exists
        guard FileManager.default.fileExists(atPath: blossomDir.path) else {
            logStore.append(LogEntry(timestamp: Date(), level: "WARN", message: "Blossom directory not found: \(blossomDir.path)"))
            completion(false)
            return
        }
        
        logStore.append(LogEntry(timestamp: Date(), level: "INFO", message: "Starting Blossom backup..."))
        
        // Create a temporary file path
        let tempDir = FileManager.default.temporaryDirectory
        let tempZipURL = tempDir.appendingPathComponent("blossom_backup_\(UUID().uuidString).zip")
        
        // Launch Go ZipDirectoryC on background thread
        DispatchQueue.global().async { [weak self] in
            guard let cSrc = strdup(blossomDir.path), let cDst = strdup(tempZipURL.path) else {
                free(nil) // no-op, just balances the flow
                Task { @MainActor in
                    self?.logStore.append(LogEntry(timestamp: Date(), level: "ERROR", message: "Memory allocation failed for Blossom backup"))
                    completion(false)
                }
                return
            }
            let result = ZipDirectoryC(cSrc, cDst)
            free(cSrc)
            free(cDst)

            Task { @MainActor in
                if result == 0 {
                    do {
                        let destURL = URL(fileURLWithPath: outputPath)
                        if FileManager.default.fileExists(atPath: destURL.path) {
                            try FileManager.default.removeItem(at: destURL)
                        }
                        try FileManager.default.moveItem(at: tempZipURL, to: destURL)
                        self?.logStore.append(LogEntry(timestamp: Date(), level: "INFO", message: "Blossom backup saved to \(outputPath)"))
                        completion(true)
                    } catch {
                        self?.logStore.append(LogEntry(timestamp: Date(), level: "ERROR", message: "Failed to move backup to destination: \(error.localizedDescription)"))
                        try? FileManager.default.removeItem(at: tempZipURL)
                        completion(false)
                    }
                } else {
                    self?.logStore.append(LogEntry(timestamp: Date(), level: "ERROR", message: "Blossom backup failed in Go process"))
                    try? FileManager.default.removeItem(at: tempZipURL)
                    completion(false)
                }
            }
        }
    }

    func runBlossomImport(config: HavenConfig, inputPath: String, completion: @escaping @Sendable (Bool) -> Void) {
        let blossomDir = ConfigService.shared.relayDataDir.appendingPathComponent(config.blossomPath)
        
        // Ensure blossom directory exists
        try? FileManager.default.createDirectory(at: blossomDir, withIntermediateDirectories: true)
        
        logStore.append(LogEntry(timestamp: Date(), level: "INFO", message: "Starting Blossom import..."))
        
        // Copy to temp first to avoid sandbox issues with unzip subprocess
        let tempDir = FileManager.default.temporaryDirectory
        let tempZipURL = tempDir.appendingPathComponent("blossom_import_\(UUID().uuidString).zip")
        
        do {
            if FileManager.default.fileExists(atPath: tempZipURL.path) {
                try FileManager.default.removeItem(at: tempZipURL)
            }
            try FileManager.default.copyItem(atPath: inputPath, toPath: tempZipURL.path)
        } catch {
            logStore.append(LogEntry(timestamp: Date(), level: "ERROR", message: "Failed to copy import file to temp: \(error)"))
            completion(false)
            return
        }
        
        // Launch Go UnzipDirectoryC on background thread
        DispatchQueue.global().async { [weak self] in
            guard let cSrc = strdup(tempZipURL.path), let cDst = strdup(blossomDir.path) else {
                Task { @MainActor in
                    self?.logStore.append(LogEntry(timestamp: Date(), level: "ERROR", message: "Memory allocation failed for Blossom import"))
                    completion(false)
                }
                return
            }
            let result = UnzipDirectoryC(cSrc, cDst)
            free(cSrc)
            free(cDst)

            Task { @MainActor in
                try? FileManager.default.removeItem(at: tempZipURL)

                if result == 0 {
                    self?.logStore.append(LogEntry(timestamp: Date(), level: "INFO", message: "Blossom import complete."))
                    completion(true)
                } else {
                    self?.logStore.append(LogEntry(timestamp: Date(), level: "ERROR", message: "Blossom import failed in Go process"))
                    completion(false)
                }
            }
        }
    }
    
    // MARK: - Blossom Extensions Logic
    
    func runBlossomExportWithExtensions(config: HavenConfig, outputPath: String, completion: @escaping @Sendable (Bool) -> Void) {
        guard isRunning else {
            logStore.append(LogEntry(timestamp: Date(), level: "WARN", message: "Cannot export: relay must be running to detect file types."))
            completion(false)
            return
        }

        let blossomDir = ConfigService.shared.relayDataDir.appendingPathComponent(config.blossomPath)

        guard FileManager.default.fileExists(atPath: blossomDir.path) else {
            logStore.append(LogEntry(timestamp: Date(), level: "WARN", message: "Blossom directory not found: \(blossomDir.path)"))
            completion(false)
            return
        }
        
        logStore.append(LogEntry(timestamp: Date(), level: "INFO", message: "Starting Blossom export with extensions..."))
        
        // Create temp dir for staging files with extensions
        let tempDir = FileManager.default.temporaryDirectory
        let stagingDir = tempDir.appendingPathComponent("BlossomExport_\(UUID().uuidString)")
        let tempZipURL = tempDir.appendingPathComponent("blossom_export_temp_\(UUID().uuidString).zip")
        
        Task.detached {
            do {
                try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
                
                // Iterate files in blossomDir
                let fileURLs = try FileManager.default.contentsOfDirectory(at: blossomDir, includingPropertiesForKeys: nil)
                
                for fileURL in fileURLs {
                    // Ignore hidden files
                    if fileURL.lastPathComponent.hasPrefix(".") { continue }

                    let sha256 = fileURL.lastPathComponent
                    let proof = self.detectMimeFromBytes(for: fileURL)
                    
                    let claim: String?
                    // Only perform the network check if magic bytes are inconclusive
                    if proof == "application/octet-stream" {
                        claim = await self.fetchMimeFromRelay(config: config, sha256: sha256)
                    } else {
                        claim = nil
                    }
                    
                    let resolvedMime = self.resolveMime(claim: claim, proof: proof)
                    let ext = self.mimeToExtension(resolvedMime)

                    let newFilename = sha256 + (ext == "bin" ? "" : ".\(ext)")
                    let destURL = stagingDir.appendingPathComponent(newFilename)

                    try FileManager.default.copyItem(at: fileURL, to: destURL)
                }
                
                // Zip the staging directory content using Go ZipDirectoryC
                guard let cSrc = strdup(stagingDir.path), let cDst = strdup(tempZipURL.path) else {
                    await MainActor.run {
                        try? FileManager.default.removeItem(at: stagingDir)
                        self.logStore.append(LogEntry(timestamp: Date(), level: "ERROR", message: "Memory allocation failed for Blossom export"))
                        completion(false)
                    }
                    return
                }
                let result = ZipDirectoryC(cSrc, cDst)
                free(cSrc)
                free(cDst)
                
                await MainActor.run {
                    // Cleanup staging
                    try? FileManager.default.removeItem(at: stagingDir)
                    
                    if result == 0 {
                        // Move zip to final destination
                        do {
                            let destURL = URL(fileURLWithPath: outputPath)
                            if FileManager.default.fileExists(atPath: destURL.path) {
                                try FileManager.default.removeItem(at: destURL)
                            }
                            try FileManager.default.moveItem(at: tempZipURL, to: destURL)
                            self.logStore.append(LogEntry(timestamp: Date(), level: "INFO", message: "Blossom export saved to \(outputPath)"))
                            completion(true)
                        } catch {
                            self.logStore.append(LogEntry(timestamp: Date(), level: "ERROR", message: "Failed to move export to destination: \(error.localizedDescription)"))
                            try? FileManager.default.removeItem(at: tempZipURL)
                            completion(false)
                        }
                    } else {
                        self.logStore.append(LogEntry(timestamp: Date(), level: "ERROR", message: "Blossom export failed in Go process"))
                        try? FileManager.default.removeItem(at: tempZipURL)
                        completion(false)
                    }
                }
            } catch {
                await MainActor.run {
                    self.logStore.append(LogEntry(timestamp: Date(), level: "ERROR", message: "Failed to prepare Blossom export: \(error.localizedDescription)"))
                    try? FileManager.default.removeItem(at: stagingDir)
                    completion(false)
                }
            }
        }
    }
    
    func runBlossomImportStrippingExtensions(config: HavenConfig, inputPath: String, completion: @escaping @Sendable (Bool) -> Void) {
        let blossomDir = ConfigService.shared.relayDataDir.appendingPathComponent(config.blossomPath)
        
        // Ensure blossom directory exists
        try? FileManager.default.createDirectory(at: blossomDir, withIntermediateDirectories: true)
        
        logStore.append(LogEntry(timestamp: Date(), level: "INFO", message: "Starting Blossom import (stripping extensions)..."))
        
        // 1. Copy input zip to temp
        let tempDir = FileManager.default.temporaryDirectory
        let tempZipURL = tempDir.appendingPathComponent("blossom_import_source_\(UUID().uuidString).zip")
        let stagingDir = tempDir.appendingPathComponent("BlossomImport_\(UUID().uuidString)")
        
        do {
            if FileManager.default.fileExists(atPath: tempZipURL.path) {
                try FileManager.default.removeItem(at: tempZipURL)
            }
            try FileManager.default.copyItem(atPath: inputPath, toPath: tempZipURL.path)
            try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        } catch {
            logStore.append(LogEntry(timestamp: Date(), level: "ERROR", message: "Failed to setup temp dirs: \(error)"))
            completion(false)
            return
        }
        
        // 2. Unzip to staging using Go UnzipDirectoryC
        DispatchQueue.global().async { [weak self] in
            guard let cSrc = strdup(tempZipURL.path), let cDst = strdup(stagingDir.path) else {
                Task { @MainActor in
                    self?.logStore.append(LogEntry(timestamp: Date(), level: "ERROR", message: "Memory allocation failed for Blossom import"))
                    try? FileManager.default.removeItem(at: tempZipURL)
                    completion(false)
                }
                return
            }
            let result = UnzipDirectoryC(cSrc, cDst)
            free(cSrc)
            free(cDst)
            
            Task { @MainActor in
                // Cleanup zip copy
                try? FileManager.default.removeItem(at: tempZipURL)
                
                if result == 0 {
                    // 3. Process files in staging
                    do {
                        let fileURLs = try FileManager.default.contentsOfDirectory(at: stagingDir, includingPropertiesForKeys: nil)
                        var count = 0
                        
                        for fileURL in fileURLs {
                            if fileURL.hasDirectoryPath { continue }
                            if fileURL.lastPathComponent.hasPrefix(".") { continue }
                            if fileURL.lastPathComponent == "__MACOSX" { continue }
                            
                            // Strip extension
                            let filename = fileURL.deletingPathExtension().lastPathComponent
                            
                            // Validate SHA256 (64 hex chars)
                            if filename.count == 64 && filename.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil {
                                let destURL = blossomDir.appendingPathComponent(filename)
                                // Overwrite
                                if FileManager.default.fileExists(atPath: destURL.path) {
                                    try FileManager.default.removeItem(at: destURL)
                                }
                                try FileManager.default.moveItem(at: fileURL, to: destURL)
                                count += 1
                            } else {
                                self?.logStore.append(LogEntry(timestamp: Date(), level: "WARN", message: "Skipping invalid blossom file: \(fileURL.lastPathComponent)"))
                            }
                        }
                        
                        self?.logStore.append(LogEntry(timestamp: Date(), level: "INFO", message: "Blossom import complete. Imported \(count) files."))
                        try? FileManager.default.removeItem(at: stagingDir)
                        completion(true)
                        
                    } catch {
                         self?.logStore.append(LogEntry(timestamp: Date(), level: "ERROR", message: "Error processing imported files: \(error)"))
                         try? FileManager.default.removeItem(at: stagingDir)
                         completion(false)
                    }
                } else {
                    self?.logStore.append(LogEntry(timestamp: Date(), level: "ERROR", message: "Unzip failed in Go process"))
                    try? FileManager.default.removeItem(at: stagingDir)
                    completion(false)
                }
            }
        }
    }
    
    // Detect MIME type from file magic bytes (the "proof")
    nonisolated func detectMimeFromBytes(for url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "application/octet-stream" }
        defer { handle.closeFile() }
        let header = handle.readData(ofLength: 64)
        guard header.count >= 4 else { return "application/octet-stream" }
        let bytes = [UInt8](header)

        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
            return "image/jpeg"
        } else if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return "image/png"
        } else if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) {
            return "image/gif"
        } else if bytes.count >= 12,
                  bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46 {
            if bytes[8] == 0x57, bytes[9] == 0x45, bytes[10] == 0x42, bytes[11] == 0x50 {
                return "image/webp"
            } else if bytes[8] == 0x57, bytes[9] == 0x41, bytes[10] == 0x56, bytes[11] == 0x45 {
                return "audio/wav"
            }
        } else if bytes.count >= 12,
                  bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 {
            return classifyFtyp(bytes)
        } else if bytes.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) {
            return "video/webm"
        } else if bytes.starts(with: [0x25, 0x50, 0x44, 0x46]) {
            return "application/pdf"
        } else if bytes.starts(with: [0x49, 0x44, 0x33]) {
            return "audio/mpeg"
        } else if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] & 0xE0 == 0xE0 {
            return "audio/mpeg"
        } else if bytes.count >= 4,
                  bytes[0] == 0x49, bytes[1] == 0x49, bytes[2] == 0x2A, bytes[3] == 0x00 {
            return "image/tiff"
        } else if bytes.count >= 4,
                  bytes[0] == 0x4D, bytes[1] == 0x4D, bytes[2] == 0x00, bytes[3] == 0x2A {
            return "image/tiff"
        } else if bytes.starts(with: [0x42, 0x4D]) {
            return "image/bmp"
        } else if bytes.starts(with: [0x66, 0x4C, 0x61, 0x43]) {
            return "audio/flac"
        } else if bytes.starts(with: [0x4F, 0x67, 0x67, 0x53]) {
            return "audio/ogg"
        } else if bytes.starts(with: [0x50, 0x4B, 0x03, 0x04]) {
            return "application/zip"
        } else if bytes.starts(with: [0x1F, 0x8B]) {
            return "application/gzip"
        }
        return "application/octet-stream"
    }

    // Classify an ftyp box by scanning major brand + all compatible brands
    private nonisolated func classifyFtyp(_ bytes: [UInt8]) -> String {
        // ftyp box size is at bytes 0-3 (big-endian)
        let boxSize = min(
            Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3]),
            bytes.count
        )

        // Collect all 4-byte brand strings: major brand @ 8, compatible brands @ 16,20,24...
        var brands: [String] = []
        // Major brand at offset 8
        if boxSize >= 12 {
            brands.append(String(bytes: bytes[8..<12], encoding: .ascii) ?? "")
        }
        // Compatible brands start at offset 16 (after 4-byte minor version)
        var offset = 16
        while offset + 4 <= boxSize {
            brands.append(String(bytes: bytes[offset..<(offset + 4)], encoding: .ascii) ?? "")
            offset += 4
        }

        let brandSet = Set(brands)

        // Check most specific first
        if brandSet.contains("avif") || brandSet.contains("avis") {
            return "image/avif"
        }
        if brandSet.contains("heic") || brandSet.contains("heix") {
            return "image/heic"
        }
        // Check QuickTime brand BEFORE HEVC - macOS screen recordings use HEVC in MOV container
        if brandSet.contains("qt  ") {
            return "video/quicktime"
        }
        if brandSet.contains("hevc") || brandSet.contains("hev1") || brandSet.contains("hvc1") {
            return "video/mp4"
        }
        return "video/mp4"
    }

    // Fetch MIME type from the running relay via HEAD request (the "claim")
    nonisolated func fetchMimeFromRelay(config: HavenConfig, sha256: String) async -> String? {
        guard let url = URL(string: "\(config.webURL)/\(sha256)") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 3

        do {
            let (_, response) = try await TLSSkipSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode == 200,
               let ct = httpResponse.value(forHTTPHeaderField: "Content-Type") {
                // Strip parameters (e.g. "image/jpeg; charset=utf-8" → "image/jpeg")
                return ct.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces)
            }
        } catch {
            // Silently ignore timeout/connection issues
        }
        return nil
    }

    // Resolve claim (relay) vs proof (magic bytes) using trust-but-verify
    nonisolated func resolveMime(claim: String?, proof: String) -> String {
        guard let claim = claim else { return proof }
        if claim == proof { return claim }

        // octet-stream from bytes means we couldn't identify it — trust the relay
        if proof == "application/octet-stream" { return claim }

        // Check if proof allows claim as a valid refinement
        if let allowed = mimeSubsetRules[proof] {
            if allowed.isEmpty || allowed.contains(claim) {
                return claim
            }
        }

        // Same broad category (e.g. both video/*, both image/*) — trust relay
        let proofType = proof.components(separatedBy: "/").first
        let claimType = claim.components(separatedBy: "/").first
        if proofType == claimType { return claim }

        // Hard mismatch — trust the bytes
        return proof
    }

    // Fallback map for MIME types that UTType may not know on all macOS versions
    private nonisolated static let extensionFallbacks: [String: String] = [
        "application/vnd.android.package-archive": "apk",
        "application/java-archive": "jar",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "docx",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": "xlsx",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation": "pptx",
        "audio/x-m4a": "m4a",
        "audio/mp4": "m4a",
        "audio/aac": "aac",
        "audio/opus": "opus",
        "video/x-matroska": "mkv",
        "image/svg+xml": "svg",
        "application/x-tar": "tar",
        "application/gzip": "gz",
    ]

    // Convert MIME type to file extension
    private nonisolated func mimeToExtension(_ mime: String) -> String {
        if let utType = UTType(mimeType: mime),
           let ext = utType.preferredFilenameExtension {
            return ext
        }
        return Self.extensionFallbacks[mime] ?? "bin"
    }
}
