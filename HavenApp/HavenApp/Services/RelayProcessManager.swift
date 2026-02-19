import Foundation
import Combine
import UniformTypeIdentifiers

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
    @Published var isImporting = false
    @Published var importCompleted = false
    @Published var isLocked = false
    @Published var isPortConflict = false
    @Published var bootStatusMessage: String = ""
    @Published var importStatusMessage: String = ""
    @Published var importProgress: Double = 0.0
    
    // Critical recovery alert
    @Published var showProcessKillAlert = false
    
    @Published var logs: [LogEntry] = []
    
    // Metrics
    @Published var memoryUsage: Double = 0
    @Published var cpuUsage: Double = 0
    @Published var activeConnections: Int = 0
    @Published var eventsStored: Int = 0
    
    private var process: Process?
    private var outputPipe: Pipe?
    private var logReader: FileHandle?
    private var logBuffer = Data() // Buffer for incomplete log lines
    
    // Track if we are in the middle of a shutdown to prevent recursive restarts
    private var isShuttingDown = false
    
    private var pendingImportConfig: HavenConfig?
    @Published var startDate: Date?
    
    // Auto-fix locks
    @Published var lastConfig: HavenConfig?
    private var retryAttempted = false
    private var needsLockFix = false

    // PID file for killing orphaned processes across app launches
    private var pidFileURL: URL {
        ConfigService.shared.relayDataDir.appendingPathComponent(".haven_pid")
    }
    
    // Log throttling
    private var pendingLogs: [LogEntry] = []
    private var logUpdateTimer: Timer?
    // private let logQueue = DispatchQueue(label: "com.haven.logs") // Removed: unnecessary for MainActor
    
    private var metricsTimer: Timer?
    
    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let level: String
        let message: String
        
        static func parse(_ line: String) -> LogEntry {
            // Simplified parsing
            let level = line.contains("ERROR") ? "ERROR" :
                       line.contains("WARN") ? "WARN" : "INFO"
            return LogEntry(timestamp: Date(), level: level, message: line)
        }
    }
    
    func startRelay(config: HavenConfig, isRetry: Bool = false) {
        // Strict guard: Must be idle and NO process should be running
        guard state == .idle && (process == nil || !process!.isRunning) else {
            logs.append(LogEntry(timestamp: Date(), level: "WARN", message: "Cannot start relay: current state is \(state) (running: \(process?.isRunning ?? false))"))
            return
        }

        // Immediately claim the state so no second call can slip through
        // while the Task below does async setup work.
        self.state = .booting
        self.lastConfig = config

        // Only reset retry flag if this is a fresh start request, not an auto-retry
        if !isRetry {
            self.retryAttempted = false
            self.showProcessKillAlert = false
        }
        self.needsLockFix = false

        // Start log throttler
        startLogThrottler()

        // Background setup task
        Task {
            let relayDataDir = ConfigService.shared.relayDataDir
            let pidURL = self.pidFileURL

            // 0. Kill any orphaned haven process from a previous app session
            //    Runs on a background thread and blocks until the orphan is dead
            //    and file locks are released.
            await Task.detached {
                self.killOrphanedProcessSync(pidURL: pidURL)
            }.value

            // 1. Ensure directories exist (I/O)
            try? FileManager.default.createDirectory(at: relayDataDir, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: relayDataDir.appendingPathComponent("data"), withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: relayDataDir.appendingPathComponent("blossom"), withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: relayDataDir.appendingPathComponent("cache"), withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: relayDataDir.appendingPathComponent("db"), withIntermediateDirectories: true)

            // 2. Clear Database Locks (Crucial - must happen before start)
            self.performClearDatabaseLocks(at: relayDataDir)
            
            // 3. Copy templates directory (only if missing or update needed)
            let destURL = relayDataDir.appendingPathComponent("templates")
            if let templatesPath = Bundle.main.path(forResource: "templates", ofType: "") {
                let shouldCopy: Bool
                if !FileManager.default.fileExists(atPath: destURL.path) {
                    shouldCopy = true
                } else {
                    // Check if it's empty or needs refresh (optional, but let's be safe and check if it exists)
                    let contents = (try? FileManager.default.contentsOfDirectory(atPath: destURL.path)) ?? []
                    shouldCopy = contents.isEmpty
                }
                
                if shouldCopy {
                    if FileManager.default.fileExists(atPath: destURL.path) {
                        try? FileManager.default.removeItem(at: destURL)
                    }
                    try? FileManager.default.copyItem(at: URL(fileURLWithPath: templatesPath), to: destURL)
                    await MainActor.run {
                        self.logs.append(LogEntry(timestamp: Date(), level: "INFO", message: "Copied templates to \(destURL.path)"))
                    }
                }
            } else {
                await MainActor.run {
                    self.logs.append(LogEntry(timestamp: Date(), level: "WARN", message: "Templates folder not found in Bundle"))
                }
            }

            // Continue with the rest of the startup on the MainActor
            await MainActor.run {
                self.continueStartRelay(config: config, relayDataDir: relayDataDir)
            }
        }
    }
    
    private func continueStartRelay(config: HavenConfig, relayDataDir: URL) {
        // Write/Update essential relay files (relays list, blastr relays)
        // We stop writing .env to disk and use environment variables instead
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        
        let importRelaysURL = relayDataDir.appendingPathComponent(config.importSeedRelaysFile)
        if let data = try? encoder.encode(config.importSeedRelays) {
            try? data.write(to: importRelaysURL)
        }
        
        let blastrRelaysURL = relayDataDir.appendingPathComponent(config.blastrRelaysFile)
        if let data = try? encoder.encode(config.blastrRelays) {
            try? data.write(to: blastrRelaysURL)
        }
        
        // Write whitelisted_npubs.json (Required by new binary)
        let whitelistURL = relayDataDir.appendingPathComponent("whitelisted_npubs.json")
        if let data = try? encoder.encode(config.whitelistedNpubs) {
            try? data.write(to: whitelistURL)
        }
        
        // Write blacklisted_npubs.json
        let blacklistURL = relayDataDir.appendingPathComponent("blacklisted_npubs.json")
        if let data = try? encoder.encode(config.blacklistedNpubs) {
            try? data.write(to: blacklistURL)
        }
        
        logs.append(LogEntry(timestamp: Date(), level: "INFO", message: "Config: \(config.importSeedRelays.count) import relays, \(config.blastrRelays.count) blastr relays, \(config.whitelistedNpubs.count) whitelisted npubs"))

        // Check bundle for the binary
        guard let executablePath = Bundle.main.path(forResource: "haven", ofType: ""),
              FileManager.default.fileExists(atPath: executablePath) else {
            logs.append(LogEntry(timestamp: Date(), level: "ERROR", message: "haven binary not found in application bundle"))
            return
        }
        
        logs.append(LogEntry(timestamp: Date(), level: "INFO", message: "Starting relay from: \(executablePath)"))
        
        // Reset conflict state
        self.isPortConflict = false
        
        // Ensure executable permissions
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: executablePath)
            if let perms = attributes[.posixPermissions] as? Int {
                if perms != 0o755 {
                    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executablePath)
                     logs.append(LogEntry(timestamp: Date(), level: "INFO", message: "Ensured executable permissions for binary"))
                }
            }
        } catch {
             logs.append(LogEntry(timestamp: Date(), level: "WARN", message: "Could not set permissions (might be read-only bundle): \(error)"))
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.currentDirectoryURL = relayDataDir
        
        let envURL = relayDataDir.appendingPathComponent(".env")
        let envContent = generateMinimalEnv(config: config)
        try? envContent.write(to: envURL, atomically: true, encoding: .utf8)
        
        logs.append(LogEntry(timestamp: Date(), level: "INFO", message: "Wrote .env to \(envURL.path)"))
        logs.append(LogEntry(timestamp: Date(), level: "INFO", message: "Working Directory: \(relayDataDir.path)"))
        
        // Prepare environment
        var env: [String: String] = [:]
        
        // Minimal system environment
        let sysEnv = ProcessInfo.processInfo.environment
        env["PATH"] = sysEnv["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        env["TMPDIR"] = NSTemporaryDirectory()
        env["USER"] = sysEnv["USER"] ?? "haven"
        
        // Inject all config variables
        let configEnv = generateEnvDictionary(config: config)
        for (key, value) in configEnv {
            env[key] = value
        }
        
        // Match .env default for consistent behavior with manual runs
        env["RELAY_BIND_ADDRESS"] = "127.0.0.1"
        
        process.environment = env
        
        logs.append(LogEntry(timestamp: Date(), level: "INFO", message: "Env: HOME=\(env["HOME"]?.prefix(25) ?? "")... PORT=\(env["RELAY_PORT"] ?? "") BIND=\(env["RELAY_BIND_ADDRESS"] ?? "")"))
        logs.append(LogEntry(timestamp: Date(), level: "INFO", message: "WOT Settings: DEPTH=\(env["WOT_DEPTH"] ?? "") REFRESH=\(env["WOT_REFRESH_INTERVAL"] ?? "")"))
        logs.append(LogEntry(timestamp: Date(), level: "INFO", message: "Paths: BLOSSOM=\(env["BLOSSOM_PATH"] ?? "") DB=\(env["DATABASE_PATH"] ?? "")"))
        
        // Use Pipe for stdout/stderr to ensure realtime log delivery
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = Pipe() // Isolate stdin
        
        // Save outputPipe to keep it alive
        self.outputPipe = pipe
        
        // Read from the pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            
            Task { @MainActor in
                self?.processBufferedOutput(data)
                
                // Also write to log file for persistence if needed
                if let str = String(data: data, encoding: .utf8) {
                     let logFileURL = relayDataDir.appendingPathComponent("relay.log")
                     if !FileManager.default.fileExists(atPath: logFileURL.path) {
                         FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
                     }
                     if let fileHandle = try? FileHandle(forWritingTo: logFileURL) {
                         fileHandle.seekToEndOfFile()
                         if let data = str.data(using: .utf8) {
                             fileHandle.write(data)
                         }
                         try? fileHandle.close()
                     }
                }
            }
        }
        
        logs.append(LogEntry(timestamp: Date(), level: "INFO", message: "Captured output via Pipe"))
        
        self.process = process
        
        // No readabilityHandler needed for file redirection
        
        process.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                guard let self = self else { return }
                
                // Only handle termination for the CURRENT process
                guard proc == self.process else {
                     return
                }
                
                let exitCode = proc.terminationStatus
                self.logs.append(LogEntry(timestamp: Date(), level: "WARN", message: "Relay Process Terminated with code: \(exitCode)"))
                
                let previousState = self.state
                self.state = .idle
                self.isRunning = false
                self.isBooting = false
                self.isImporting = false
                
                // If we were stopping to start an import, trigger it now
                if let importConfig = self.pendingImportConfig, previousState == .stopping {
                    self.importNotes(config: importConfig)
                    return
                }
                
                if self.needsLockFix && !self.retryAttempted && previousState != .stopping {
                    self.logs.append(LogEntry(timestamp: Date(), level: "WARN", message: "Database lock detected. Force-cleaning and restarting..."))
                    self.retryAttempted = true
                    // Use forceCleanAndRestart which SIGKILLs any stale process,
                    // clears lock files, and restarts cleanly.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self.forceCleanAndRestart()
                    }
                    return
                } else if self.retryAttempted && (self.needsLockFix || exitCode != 0) && previousState != .stopping {
                    // Force clean already ran once and it still failed.
                    // Show alert so the user can trigger another attempt.
                    self.logs.append(LogEntry(timestamp: Date(), level: "ERROR", message: "Automatic recovery failed. Tap 'Fix & Restart' to try again."))
                    self.showProcessKillAlert = true
                }
                
                self.isShuttingDown = false
                self.state = .idle
                self.isRunning = false
                self.isBooting = false
                self.isImporting = false
                
                self.logs.append(LogEntry(timestamp: Date(), level: "INFO", message: "Relay process terminated (Exit Code: \(proc.terminationStatus))"))
                self.stopLogThrottler()
            }
        }
        
        self.state = .booting
        isRunning = true
        isBooting = true
        bootStatusMessage = "Starting system..."
        
        // Launch the process (non-blocking)
        do {
            try process.run()
            savePID(process.processIdentifier)
            logs.append(LogEntry(timestamp: Date(), level: "INFO", message: "Relay process started (PID: \(process.processIdentifier))"))
        } catch {
            logs.append(LogEntry(timestamp: Date(), level: "ERROR", message: "Failed to launch relay process: \(error.localizedDescription)"))
            self.state = .idle
            isRunning = false
            isBooting = false
            return
        }
        isLocked = false
        startDate = Date()
        
        // Start metrics timer
        startMetricsTimer()
    }
    
    func clearDatabaseLocks(completion: (@Sendable () -> Void)? = nil) {
        let relayDataDir = ConfigService.shared.relayDataDir
        Task {
            self.performClearDatabaseLocks(at: relayDataDir)
            await MainActor.run {
                self.isLocked = false
                self.logs.append(LogEntry(timestamp: Date(), level: "INFO", message: "Database locks cleared."))
                completion?()
            }
        }
    }
    
    private nonisolated func performClearDatabaseLocks(at relayDataDir: URL) {
        // Run synchronously to ensure locks are gone before we proceed with any new process
        let dbDir = relayDataDir.appendingPathComponent("data")
        
        // Standard data DBs
        let standardDBs = ["chat", "inbox", "outbox", "private", "wot"] 
        for name in standardDBs {
            // Check data/NAME/LOCK
            let lockFileData = dbDir.appendingPathComponent(name).appendingPathComponent("LOCK")
            removeLockFile(at: lockFileData)
            
            // Check db/NAME/LOCK (some configurations use this path)
            let dbRoot = relayDataDir.appendingPathComponent("db")
            let lockFileDB = dbRoot.appendingPathComponent(name).appendingPathComponent("LOCK")
            removeLockFile(at: lockFileDB)
        }
        
        // Blossom DB (check both locations just in case)
        let blossomDirs = [
            relayDataDir.appendingPathComponent("blossom"),
            dbDir.appendingPathComponent("blossom")
        ]
        for dir in blossomDirs {
            let lockFile = dir.appendingPathComponent("LOCK")
            removeLockFile(at: lockFile)
        }
    }
    
    private nonisolated func removeLockFile(at url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
                // We minimize MainActor hops here by not logging DEBUG info for every lock check
            } catch {
                // Ignore errors for individual lock files
            }
        }
    }
    
    private func savePID(_ pid: Int32) {
        try? "\(pid)".write(to: pidFileURL, atomically: true, encoding: .utf8)
    }

    private nonisolated func clearSavedPID(at pidURL: URL) {
        try? FileManager.default.removeItem(at: pidURL)
    }

    /// Kill ALL haven Go binary processes system-wide.
    /// Uses pgrep -x for exact name match to avoid killing "HavenApp" (the Swift host).
    /// Falls back to killall -KILL as a second attempt.
    private nonisolated func killAllHavenProcesses() {
        // 1. Use pgrep -x to find PIDs with the exact process name "haven"
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-x", "haven"]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        pgrep.standardError = FileHandle.nullDevice
        do {
            try pgrep.run()
            pgrep.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                for line in output.components(separatedBy: .newlines) {
                    if let pid = Int32(line.trimmingCharacters(in: .whitespaces)), pid > 0 {
                        kill(pid, SIGKILL)
                    }
                }
            }
        } catch {
            // pgrep failed, try killall as fallback
        }

        // 2. Fallback: killall with exact match
        let killall = Process()
        killall.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        killall.arguments = ["-9", "-m", "^haven$"]
        killall.standardOutput = FileHandle.nullDevice
        killall.standardError = FileHandle.nullDevice
        do {
            try killall.run()
            killall.waitUntilExit()
        } catch {
            // Fallback also failed — nothing more we can do
        }
    }

    /// Fire-and-forget version for AppDelegate launch cleanup.
    /// Non-blocking: dispatches to a background queue.
    func killOrphanedProcess() {
        let pidURL = pidFileURL
        DispatchQueue.global().async {
            self.killOrphanedProcessSync(pidURL: pidURL)
        }
    }

    private nonisolated func killOrphanedProcessSync(pidURL: URL) {
        // 1. Kill by saved PID
        if let pidStr = try? String(contentsOf: pidURL, encoding: .utf8),
           let pid = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)),
           pid > 0 {
            if kill(pid, 0) == 0 {
                kill(pid, SIGKILL)
            }
            try? FileManager.default.removeItem(at: pidURL)
        }

        // 2. Also kill any haven processes we don't have a PID for (e.g. PID file was lost)
        killAllHavenProcesses()

        // 3. Wait for OS to fully release file locks
        Thread.sleep(forTimeInterval: 1.0)
    }
    
    func stopRelay(completion: (() -> Void)? = nil) {
        guard let process = process, process.isRunning else {
            self.state = .idle
            isRunning = false
            completion?()
            return
        }
        self.state = .stopping
        self.isShuttingDown = true
        stopMetricsTimer()
        stopLogThrottler()
        let pid = process.processIdentifier
        process.terminate()
        isBooting = false

        // Capture URL on MainActor before going to background
        let savedPidURL = pidFileURL

        // Wait for process to actually exit; escalate to SIGKILL if needed
        DispatchQueue.global().async { [weak self] in
            let deadline = Date().addingTimeInterval(5.0)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if process.isRunning {
                kill(pid, SIGKILL)
                // Brief wait for OS to reclaim resources / release flocks
                Thread.sleep(forTimeInterval: 0.5)
            }
            self?.clearSavedPID(at: savedPidURL)
            DispatchQueue.main.async {
                completion?()
            }
        }
    }
    
    /// Aggressively kill any running haven process, clear all database locks, reset state, and restart.
    /// This replaces the old "pkill -9 haven" manual step.
    func forceCleanAndRestart() {
        // Immediately claim stopping state to prevent concurrent starts
        self.state = .stopping
        logs.append(LogEntry(timestamp: Date(), level: "INFO", message: "Force clean & restart initiated..."))

        // 1. Kill managed process with SIGKILL
        let managedPid = process?.processIdentifier ?? 0
        if let process = process, process.isRunning {
            process.terminate()
        }

        // 2. Also kill any orphaned process from a previous run
        let savedPidURL = pidFileURL
        var orphanPid: Int32 = 0
        if let pidStr = try? String(contentsOf: savedPidURL, encoding: .utf8),
           let pid = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)),
           pid > 0 && pid != managedPid {
            orphanPid = pid
        }

        // Capture relayDataDir on MainActor before going to background
        let relayDataDir = ConfigService.shared.relayDataDir

        DispatchQueue.global().async { [weak self] in
            // Force kill managed process
            if managedPid > 0 {
                kill(managedPid, SIGKILL)
            }
            // Force kill orphan
            if orphanPid > 0 && kill(orphanPid, 0) == 0 {
                kill(orphanPid, SIGKILL)
            }

            // 3. Kill ALL haven processes system-wide (catches unknown orphans)
            self?.killAllHavenProcesses()

            // Wait for OS to release file locks
            Thread.sleep(forTimeInterval: 1.5)

            // Clear all lock files
            guard let self = self else { return }
            self.performClearDatabaseLocks(at: relayDataDir)
            self.clearSavedPID(at: savedPidURL)

            DispatchQueue.main.async {
                // Reset all state
                self.process = nil
                self.outputPipe = nil
                self.state = .idle
                self.isRunning = false
                self.isBooting = false
                self.isImporting = false
                self.isLocked = false
                self.needsLockFix = false
                // NOTE: Do NOT reset retryAttempted here. It must survive so the
                // termination handler can detect a second failure and show the alert
                // instead of looping forever.
                self.showProcessKillAlert = false
                self.isShuttingDown = false

                self.logs.append(LogEntry(timestamp: Date(), level: "INFO", message: "Cleanup complete. Restarting relay..."))

                // Restart if we have a config — mark as retry so we don't loop
                if let config = self.lastConfig {
                    self.startRelay(config: config, isRetry: true)
                }
            }
        }
    }

    func cancelImport() {
        guard let process = process, process.isRunning else {
            isImporting = false
            return
        }
        process.terminate()
        DispatchQueue.main.async {
            self.isImporting = false
            self.importProgress = 0.0
            self.importStatusMessage = "Import cancelled"
            self.pendingImportConfig = nil
        }
    }
    
    func dismissImport() {
        if let process = process, process.isRunning {
            process.terminate()
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
    
    private func startMetricsTimer() {
        metricsTimer?.invalidate()
        metricsTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateMetrics()
            }
        }
        // Update immediately
        updateMetrics()
    }
    
    private func stopMetricsTimer() {
        metricsTimer?.invalidate()
        metricsTimer = nil
    }
    
    private func updateMetrics() {
        // For now, we'll track events through log parsing
        // A proper implementation would require querying the database directly
        // which would need either:
        // 1. A metrics endpoint in the Go backend
        // 2. Direct database access (complex for LMDB/Badger from Swift)
        // 3. Parsing structured output from the relay
        
        // Keep the current log-based counting for now
        // The eventsStored counter is updated in processOutput when we see "stored" messages
    }
    
    private func countEventsInDatabase(at path: URL) -> Int? {
        // Disabled for now - file size is not a reliable indicator
        return nil
    }
    
    /// Kills any existing haven processes and clears database locks before import
    // Note: Replaced by forceCleanLocks() but kept as stub if needed for future refactoring, 
    // or we can remove it. For now, we will use forceCleanLocks() instead.
    // The usages below will be updated.
    
    func importNotes(config: HavenConfig) {
        logs.append(LogEntry(timestamp: Date(), level: "DEBUG", message: "importNotes called. Current State: \(state), Process Running: \(process?.isRunning ?? false)"))
        
        // Strict guard: Must be idle and NO process should be running
        guard state == .idle && (process == nil || !process!.isRunning) else {
            if (state == .running || state == .booting) && (process != nil && process!.isRunning) {
                logs.append(LogEntry(timestamp: Date(), level: "INFO", message: "Stopping running relay to start import..."))
                self.pendingImportConfig = config
                stopRelay()
            } else {
                logs.append(LogEntry(timestamp: Date(), level: "WARN", message: "Cannot start import: current state is \(state) (running: \(process?.isRunning ?? false))"))
            }
            return
        }
        
        self.pendingImportConfig = config
        self.state = .importing
        isRunning = false
        isBooting = false
        isImporting = true
        
        // Kill any existing haven processes and clear locks before starting import
        clearDatabaseLocks()
        
        // Create working directories
        let relayDataDir = ConfigService.shared.relayDataDir
        try? FileManager.default.createDirectory(at: relayDataDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: relayDataDir.appendingPathComponent("data"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: relayDataDir.appendingPathComponent("blossom"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: relayDataDir.appendingPathComponent("cache"), withIntermediateDirectories: true)
        
        // Write/Update all configuration files (except .env) before import
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        
        // seed relays
        let importRelaysURL = relayDataDir.appendingPathComponent(config.importSeedRelaysFile)
        if let data = try? encoder.encode(config.importSeedRelays) {
            try? data.write(to: importRelaysURL)
        }
        
        // blastr relays
        let blastrRelaysURL = relayDataDir.appendingPathComponent(config.blastrRelaysFile)
        let blastrRelays = config.blastrRelays.isEmpty ? [] : config.blastrRelays
        if let data = try? encoder.encode(blastrRelays) {
            try? data.write(to: blastrRelaysURL)
        }
        
        // Write whitelisted_npubs.json (Required by new binary)
        let whitelistURL = relayDataDir.appendingPathComponent("whitelisted_npubs.json")
        if let data = try? encoder.encode(config.whitelistedNpubs) {
            try? data.write(to: whitelistURL)
        }
        
        // Write blacklisted_npubs.json
        let blacklistURL = relayDataDir.appendingPathComponent("blacklisted_npubs.json")
        if let data = try? encoder.encode(config.blacklistedNpubs) {
            try? data.write(to: blacklistURL)
        }
        
        // Check bundle for the binary
        guard let executablePath = Bundle.main.path(forResource: "haven", ofType: ""),
              FileManager.default.fileExists(atPath: executablePath) else {
            logs.append(LogEntry(timestamp: Date(), level: "ERROR", message: "haven binary not found in application bundle"))
            self.importStatusMessage = "Binary not found"
            self.isImporting = false
            return
        }
        
        logs.append(LogEntry(timestamp: Date(), level: "INFO", message: "Launching import process from: \(executablePath) with --import"))
        
        // Reset conflict state
        self.isPortConflict = false
        
        // Ensure data directory exist for import
        let dataDir = relayDataDir.appendingPathComponent("data")
        let dbDir = relayDataDir.appendingPathComponent("db")
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        
        // Ensure executable permissions
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: executablePath)
            if let perms = attributes[.posixPermissions] as? Int {
                if perms != 0o755 {
                    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executablePath)
                     logs.append(LogEntry(timestamp: Date(), level: "INFO", message: "Ensured executable permissions for binary"))
                }
            }
        } catch {
             logs.append(LogEntry(timestamp: Date(), level: "WARN", message: "Could not set permissions for import binary: \(error)"))
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["import"]
        process.currentDirectoryURL = relayDataDir
        
        // Write .env file for import as well
        let envURL = relayDataDir.appendingPathComponent(".env")
        let envContent = generateMinimalEnv(config: config)
        try? envContent.write(to: envURL, atomically: true, encoding: .utf8)
        
        // Prepare environment
        var env: [String: String] = [:]
        
        // Minimal system environment
        let sysEnv = ProcessInfo.processInfo.environment
        env["PATH"] = sysEnv["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        env["TMPDIR"] = NSTemporaryDirectory()
        env["USER"] = sysEnv["USER"] ?? "haven"
        
        // Inject all config variables
        let configEnv = generateEnvDictionary(config: config)
        for (key, value) in configEnv {
            env[key] = value
        }
        
        // Bind to localhost by default
        env["RELAY_BIND_ADDRESS"] = "127.0.0.1"
        
        process.environment = env
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        // Set standardInput to a new pipe to avoid signals like SIGPIPE
        process.standardInput = Pipe()
        
        self.outputPipe = pipe
        self.process = process
        
        // Update @Published properties on main thread
        DispatchQueue.main.async {
            self.importProgress = 0.0
            self.importStatusMessage = "Starting import for \(config.ownerNpub.prefix(12))..."
        }
        
        process.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                guard let self = self else { return }
                
                // Only handle termination for the CURRENT process
                guard proc == self.process else {
                    self.logs.append(LogEntry(timestamp: Date(), level: "WARN", message: "Stray import process terminated (PID: \(proc.processIdentifier))"))
                    return
                }
                
                self.outputPipe?.fileHandleForReading.readabilityHandler = nil
                self.isImporting = false
                self.state = .idle // CRITICAL: Reset state so we are no longer stuck in .importing
                
                let exitCode = proc.terminationStatus
                self.logs.append(LogEntry(timestamp: Date(), level: exitCode == 0 ? "INFO" : "ERROR", message: "Import process terminated with exit code: \(exitCode)"))
                
                if (exitCode == 0 || exitCode == 15) && self.importCompleted {
                    self.importProgress = 1.0
                    self.importStatusMessage = "Import Complete!"
                    self.importCompleted = true
                    
                    // Automatically restart relay if we have a config ready
                    if let restartConfig = self.pendingImportConfig {
                        self.pendingImportConfig = nil
                        self.logs.append(LogEntry(timestamp: Date(), level: "INFO", message: "Import successful, restarting relay..."))
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            self.startRelay(config: restartConfig)
                        }
                    }
                } else {
                    self.importStatusMessage = "Import Failed (Exit Code \(exitCode))"
                    self.importCompleted = false
                    self.pendingImportConfig = nil
                }
                
                self.isShuttingDown = false
            }
        }
        
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            
             if let str = String(data: data, encoding: .utf8) {
                 Task { @MainActor in
                     self?.logs.append(LogEntry(timestamp: Date(), level: "RAW", message: "Received \(data.count) bytes: \(str)"))
                 }
            }

            Task { @MainActor in
                self?.processBufferedOutput(data)
            }
        }
        
        // Wait for locks to clear before running
        clearDatabaseLocks { [weak self] in
             Task { @MainActor in
                 guard let self = self else { return }
                 
                 // Check if we were cancelled while waiting
                 if self.state != .importing { return }
                 
                 // Check if process was already created (it was, above)
                 // But we need to run it NOW.
                 
                 do {
                     try process.run()
                     self.logs.append(LogEntry(timestamp: Date(), level: "INFO", message: "Import process started (PID: \(process.processIdentifier))"))
                 } catch {
                     let errorMsg = "Failed to launch import process: \(error.localizedDescription)"
                     self.logs.append(LogEntry(timestamp: Date(), level: "ERROR", message: errorMsg))
                     self.isImporting = false
                     self.importStatusMessage = "Launch failed: \(error.localizedDescription)"
                 }
             }
        }
    }
    
    func generateMinimalEnv(config: HavenConfig) -> String {
        let envDict = generateEnvDictionary(config: config)
        var content = ""
        for (key, value) in envDict.sorted(by: { $0.key < $1.key }) {
            // Robust quoting: 
            // 1. If contains spaces, wrap in double quotes
            // 2. If contains double quotes, escape them
            if value.contains(" ") || value.contains("\"") {
                let escapedValue = value.replacingOccurrences(of: "\"", with: "\\\"")
                content += "\(key)=\"\(escapedValue)\"\n"
            } else if value.isEmpty {
                content += "\(key)=\"\"\n"
            } else {
                content += "\(key)=\(value)\n"
            }
        }
        return content
    }
    
    private func processBufferedOutput(_ data: Data) {
        logBuffer.append(data)
        
        // Find the last newline character
        guard let range = logBuffer.range(of: Data([0x0A]), options: .backwards) else {
            // No newline yet, keep buffering
            return
        }
        
        // Extract all complete lines
        let validData = logBuffer.subdata(in: 0..<range.upperBound)
        
        // Keep the remainder in the buffer
        logBuffer = logBuffer.subdata(in: range.upperBound..<logBuffer.endIndex)
        
        if let output = String(data: validData, encoding: .utf8) {
            processOutput(output)
        }
    }
    
    private func processOutput(_ output: String) {
        let lines = output.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard !lines.isEmpty else { return }
        
        var newEntries: [LogEntry] = []
        // Note: Logic inside loop needs to be preserved, but append to pendingLogs instead of logs

        for line in lines {
            let entry = LogEntry.parse(line)
            newEntries.append(entry)
            
            if isImporting {
               if line.contains("connected successfully") {
                   importProgress = 0.1
                   importStatusMessage = "Connected to relays..."
               } else if line.contains("Imported") && line.contains("notes") {
                   if let dateStr = line.components(separatedBy: "to ").last?.prefix(10) {
                        calculateProgress(currentDateStr: String(dateStr))
                   }
                   if let rangeStart = line.range(of: "from ")?.upperBound,
                      let rangeEnd = line.range(of: " to")?.lowerBound {
                       importStatusMessage = "Found notes from \(line[rangeStart..<rangeEnd])..."
                   } else {
                       importStatusMessage = "Found notes..."
                   }
               } else if line.contains("Initializing WoT") || line.contains("building WoT") || line.contains("fetching Nostr events") {
                   importStatusMessage = "Building Web of Trust..."
                   importProgress = 0.2
               } else if line.contains("analysing Nostr events") {
                   importStatusMessage = "Analysing Web of Trust..."
                   importProgress = 0.3
               } else if line.contains("importing inbox notes") || line.contains("Importing inbox notes") {
                   importStatusMessage = "Importing tagged notes..."
                   importProgress = 0.85 // More conservative estimate
               } else if line.contains("subscribing to inbox") || line.contains("tagged import complete") {
                   // Import is effectively done when it starts subscribing or explicitly says complete
                   self.isImporting = false
                   self.importCompleted = true
                   importProgress = 1.0
                   importStatusMessage = "Import Complete!"
                   
                   // Force terminate the process so we can switch to normal relay mode
                   DispatchQueue.main.async {
                       if let process = self.process, process.isRunning {
                           self.logs.append(LogEntry(timestamp: Date(), level: "INFO", message: "Import phase finished, transitioning to relay..."))
                           process.terminate()
                       }
                   }
               } else if line.contains("imported") && line.contains("tagged notes") {
                   // Tagged notes import completed
                   importProgress = 0.95
                   if let count = line.components(separatedBy: " ").first(where: { Int($0) != nil }) {
                       importStatusMessage = "Imported \(count) tagged notes"
                   } else {
                       importStatusMessage = "Tagged notes imported"
                   }
               } else if line.contains("Import complete") || line.contains("import complete") {
                   importProgress = 1.0
                   importStatusMessage = "Import Complete!"
                    
                    // Terminate process if tagged import complete (Go doesnt exit)
                    if line.contains("tagged import complete") {
                        self.isImporting = false
                        self.importCompleted = true
                        
                        // Give Go a chance to exit naturally, but force kill if it hangs
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            if let process = self.process, process.isRunning {
                                self.logs.append(LogEntry(timestamp: Date(), level: "WARN", message: "Import process didn't exit naturally, forcing termination..."))
                                process.terminate()
                            }
                        }
                    }
               } else if line.contains("No notes found") {
                   if let dateStr = line.components(separatedBy: "to ").last?.prefix(10) {
                       calculateProgress(currentDateStr: String(dateStr))
                       if let fromIndex = line.components(separatedBy: "for ").last?.prefix(10) {
                            importStatusMessage = "Checking \(fromIndex)... (No notes found)"
                       }
                   } else {
                        importProgress = min(importProgress + 0.03, 0.85) // Smaller increments, cap at 85%
                   }
               }
            }
            
            // Parse event counts from logs
            if line.contains("Imported") && line.contains("notes") {
                // Extract number from "Imported X notes from..."
                let components = line.components(separatedBy: " ")
                if let importedIndex = components.firstIndex(of: "Imported"),
                   importedIndex + 1 < components.count,
                   let count = Int(components[importedIndex + 1]) {
                    eventsStored += count
                }
            } else if line.contains("imported") && line.contains("tagged notes") {
                // Extract from "imported X tagged notes"
                let components = line.components(separatedBy: " ")
                if let importedIndex = components.firstIndex(of: "imported"),
                   importedIndex + 1 < components.count,
                   let count = Int(components[importedIndex + 1]) {
                    eventsStored += count
                }
            } else if line.contains("new note") || line.contains("new reaction") || 
                      line.contains("new zap") || line.contains("new encrypted message") ||
                      line.contains("new gift-wrapped") || line.contains("new repost") {
                // Individual events coming in
                eventsStored += 1
            }
            
            // Booting status
            if isBooting {
                let lowerLine = line.lowercased()
                
                if lowerLine.contains("subscribing to") {
                    if let topic = line.components(separatedBy: "to ").last {
                        bootStatusMessage = "Subscribing to \(topic.trimmingCharacters(in: .punctuationCharacters))..."
                    }
                } else if lowerLine.contains("is booting up") { // "HAVEN X.X.X is booting up"
                     DispatchQueue.main.async { self.bootStatusMessage = "Booting Haven..." }
                } else if lowerLine.contains("starting") {
                    if let service = line.components(separatedBy: "starting ").last ?? line.components(separatedBy: "Starting ").last {
                         bootStatusMessage = "Starting \(service.trimmingCharacters(in: .punctuationCharacters))..."
                    }
                } else if lowerLine.contains("listening at") || lowerLine.contains("listening on") { // Match both
                     DispatchQueue.main.async { self.bootStatusMessage = " initializing" } // Final state
                } else if lowerLine.contains("building web of trust graph") || lowerLine.contains("initializing wot") {
                     DispatchQueue.main.async { self.bootStatusMessage = "Building Web of Trust..." }
                } else if lowerLine.contains("analysed") || lowerLine.contains("analysing nostr events") {
                    // OLD: analysed 123
                    // NEW: analysing Nostr events count=123
                    // Broad match for digits
                    let pattern = "(?:analysed|count=)(\\d+)"
                    if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                       let match = regex.firstMatch(in: line, options: [], range: NSRange(line.startIndex..., in: line)),
                       let range = Range(match.range(at: 1), in: line) {
                        let count = line[range]
                        bootStatusMessage = "Analysed \(count) keys..."
                    }
                } else if lowerLine.contains("network size") {
                     if let count = line.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces) {
                         bootStatusMessage = "Network Size: \(count)"
                     }
                } else if lowerLine.contains("totals") && lowerLine.contains("pubkeys") {
                    // NEW: totals pubkeys=123 relays=456
                    let pattern = "pubkeys=(\\d+)"
                    if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                       let match = regex.firstMatch(in: line, options: [], range: NSRange(line.startIndex..., in: line)),
                       let range = Range(match.range(at: 1), in: line) {
                        let count = line[range]
                        bootStatusMessage = "Network Size: \(count)"
                    }
                } else if lowerLine.contains("relays discovered") {
                     if let count = line.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces) {
                         bootStatusMessage = "Discovered \(count) relays..."
                     }
                } else if lowerLine.contains("pubkeys with minimum followers") || lowerLine.contains("eliminating pubkeys") {
                     // NEW: eliminating pubkeys ... kept=123
                     // OLD: pubkeys with minimum followers: 123
                     let pattern = "(?:kept=|followers: )(\\d+)"
                     if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                        let match = regex.firstMatch(in: line, options: [], range: NSRange(line.startIndex..., in: line)),
                        let range = Range(match.range(at: 1), in: line) {
                        let count = line[range]
                        bootStatusMessage = "Trust Graph: \(count) users"
                     }
                }
            }
            
            // Connection tracking
            if line.contains("subscribing to inbox") || line.contains("Subscribing to inbox") {
                isBooting = false
                bootStatusMessage = ""
            }
            
            if line.contains("accepted connection") || line.contains("new connection") || line.contains("WS connect") {
                activeConnections += 1
            } else if line.contains("connection closed") || line.contains("WS disconnect") || line.contains("disconnected") {
                activeConnections = max(0, activeConnections - 1)
            }
            
            if line.contains("Cannot acquire directory lock") || line.contains("Another process is using this Badger database") {
                isLocked = true
                needsLockFix = true
            }
            
            if line.contains("bind: address already in use") {
                isPortConflict = true
            }
        }
        
        // Batch append logs to queue
        self.pendingLogs.append(contentsOf: newEntries)
    }
    
    private func startLogThrottler() {
        stopLogThrottler()
        DispatchQueue.main.async {
            self.logUpdateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.flushLogs()
                }
            }
        }
    }
    
    private func stopLogThrottler() {
        DispatchQueue.main.async {
            self.logUpdateTimer?.invalidate()
            self.logUpdateTimer = nil
            self.flushLogs() // Flush remaining
        }
    }
    
    private func flushLogs() {
        guard !pendingLogs.isEmpty else { return }
        let batch = pendingLogs
        pendingLogs.removeAll()
        
        self.logs.append(contentsOf: batch)
        // Keep max buffer
        if self.logs.count > 1000 {
            self.logs.removeFirst(max(0, self.logs.count - 1000))
        }
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
        // Double-check sanitization here just in case ConfigService.save() wasn't called
        let cleanNpub = config.ownerNpub.trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { "abcdefghijklmnopqrstuvwxyz0123456789".contains($0.lowercased()) }

        return [
            "OWNER_NPUB": cleanNpub,
            "RELAY_URL": config.relayURL,
            "RELAY_PORT": String(config.relayPort),
            "RELAY_BIND_ADDRESS": "127.0.0.1",
            "DB_ENGINE": config.dbEngine,
            "LMDB_MAPSIZE": "0",
            "DATABASE_PATH": ConfigService.shared.relayDataDir.appendingPathComponent("data").standardized.path + "/",
            "BLOSSOM_PATH": ConfigService.shared.relayDataDir.appendingPathComponent(config.blossomPath).standardized.path + "/",
            "HAVEN_LOG_LEVEL": config.logLevel,
            "LOG_FORMAT": "$$host $$remote_addr - $$remote_user [$$time_local] \"$$request\" $$status $$body_bytes_sent \"$$http_referer\" \"$$http_user_agent\" \"$$upstream_addr\"",
            "TZ": "UTC",

            // Whitelisted Npubs
            // Whitelisted Npubs
            "WHITELISTED_NPUBS_FILE": config.whitelistedNpubsFile,
            
            // Blacklisted Npubs
            "BLACKLISTED_NPUBS_FILE": config.blacklistedNpubsFile,

            // Private Relay
            "PRIVATE_RELAY_NAME": config.privateRelayName,
            "PRIVATE_RELAY_NPUB": config.ownerNpub,
            "PRIVATE_RELAY_DESCRIPTION": config.privateRelayDescription,
            "PRIVATE_RELAY_ICON": config.privateRelayIcon,
            "PRIVATE_RELAY_EVENT_IP_LIMITER_TOKENS_PER_INTERVAL": "50",
            "PRIVATE_RELAY_EVENT_IP_LIMITER_INTERVAL": "1",
            "PRIVATE_RELAY_EVENT_IP_LIMITER_MAX_TOKENS": "100",
            "PRIVATE_RELAY_ALLOW_EMPTY_FILTERS": "true",
            "PRIVATE_RELAY_ALLOW_COMPLEX_FILTERS": "true",
            "PRIVATE_RELAY_CONNECTION_RATE_LIMITER_TOKENS_PER_INTERVAL": "3",
            "PRIVATE_RELAY_CONNECTION_RATE_LIMITER_INTERVAL": "5",
            "PRIVATE_RELAY_CONNECTION_RATE_LIMITER_MAX_TOKENS": "9",

            // Chat Relay
            "CHAT_RELAY_NAME": config.chatRelayName,
            "CHAT_RELAY_NPUB": config.ownerNpub,
            "CHAT_RELAY_DESCRIPTION": config.chatRelayDescription,
            "CHAT_RELAY_ICON": config.chatRelayIcon,
            "CHAT_RELAY_WOT_DEPTH": String(config.chatRelayWotDepth),
            "CHAT_RELAY_WOT_REFRESH_INTERVAL_HOURS": String(config.chatRelayWotRefreshHours),
            "WOT_REFRESH_INTERVAL": config.wotRefreshInterval,
            "WOT_DEPTH": String(config.chatRelayWotDepth),
            "WOT_MINIMUM_FOLLOWERS": String(config.chatRelayMinFollowers),
            "CHAT_RELAY_MINIMUM_FOLLOWERS": String(config.chatRelayMinFollowers),
            "CHAT_RELAY_EVENT_IP_LIMITER_TOKENS_PER_INTERVAL": "50",
            "CHAT_RELAY_EVENT_IP_LIMITER_INTERVAL": "1",
            "CHAT_RELAY_EVENT_IP_LIMITER_MAX_TOKENS": "100",
            "CHAT_RELAY_ALLOW_EMPTY_FILTERS": "true",
            "CHAT_RELAY_ALLOW_COMPLEX_FILTERS": "false",
            "CHAT_RELAY_CONNECTION_RATE_LIMITER_TOKENS_PER_INTERVAL": "3",
            "CHAT_RELAY_CONNECTION_RATE_LIMITER_INTERVAL": "3",
            "CHAT_RELAY_CONNECTION_RATE_LIMITER_MAX_TOKENS": "9",

            // Outbox Relay
            "OUTBOX_RELAY_NAME": config.outboxRelayName,
            "OUTBOX_RELAY_NPUB": config.ownerNpub,
            "OUTBOX_RELAY_DESCRIPTION": config.outboxRelayDescription,
            "OUTBOX_RELAY_ICON": config.outboxRelayIcon,
            "OUTBOX_MAX_EVENTS_PER_MINUTE": String(config.outboxMaxEventsPerMinute),
            "OUTBOX_MAX_CONNECTIONS_PER_MINUTE": String(config.outboxMaxConnectionsPerMinute),
            "OUTBOX_RELAY_EVENT_IP_LIMITER_TOKENS_PER_INTERVAL": "10",
            "OUTBOX_RELAY_EVENT_IP_LIMITER_INTERVAL": "60",
            "OUTBOX_RELAY_EVENT_IP_LIMITER_MAX_TOKENS": "100",
            "OUTBOX_RELAY_ALLOW_EMPTY_FILTERS": "true",
            "OUTBOX_RELAY_ALLOW_COMPLEX_FILTERS": "false",
            "OUTBOX_RELAY_CONNECTION_RATE_LIMITER_TOKENS_PER_INTERVAL": "3",
            "OUTBOX_RELAY_CONNECTION_RATE_LIMITER_INTERVAL": "1",
            "OUTBOX_RELAY_CONNECTION_RATE_LIMITER_MAX_TOKENS": "9",

            // Inbox Relay
            "INBOX_RELAY_NAME": config.inboxRelayName,
            "INBOX_RELAY_NPUB": config.ownerNpub,
            "INBOX_RELAY_DESCRIPTION": config.inboxRelayDescription,
            "INBOX_RELAY_ICON": config.inboxRelayIcon,
            "INBOX_PULL_INTERVAL_SECONDS": String(config.inboxPullIntervalSeconds),
            "INBOX_RELAY_EVENT_IP_LIMITER_TOKENS_PER_INTERVAL": "10",
            "INBOX_RELAY_EVENT_IP_LIMITER_INTERVAL": "1",
            "INBOX_RELAY_EVENT_IP_LIMITER_MAX_TOKENS": "20",
            "INBOX_RELAY_ALLOW_EMPTY_FILTERS": "true",
            "INBOX_RELAY_ALLOW_COMPLEX_FILTERS": "false",
            "INBOX_RELAY_CONNECTION_RATE_LIMITER_TOKENS_PER_INTERVAL": "3",
            "INBOX_RELAY_CONNECTION_RATE_LIMITER_INTERVAL": "1",
            "INBOX_RELAY_CONNECTION_RATE_LIMITER_MAX_TOKENS": "9",

            // Import
            "IMPORT_START_DATE": config.importStartDate,
            "IMPORT_SEED_RELAYS_FILE": config.importSeedRelaysFile,
            "IMPORT_QUERY_INTERVAL_SECONDS": "600",
            "IMPORT_OWNER_NOTES_FETCH_TIMEOUT_SECONDS": "300",
            "IMPORT_TAGGED_NOTES_FETCH_TIMEOUT_SECONDS": "600",

            // Backup
            "BACKUP_PROVIDER": config.backupProvider,
            "BACKUP_INTERVAL_HOURS": String(config.backupIntervalHours),
            "S3_ACCESS_KEY_ID": config.s3AccessKeyId,
            "S3_SECRET_KEY": config.s3SecretKey,
            "S3_ENDPOINT": config.s3Endpoint,
            "S3_REGION": config.s3Region,
            "S3_BUCKET_NAME": config.s3BucketName,

            // Blastr
            "BLASTR_RELAYS_FILE": config.blastrRelaysFile,

            // WoT
            "WOT_FETCH_TIMEOUT_SECONDS": "60"
        ]
    }

    // MARK: - Backup / Restore helpers

    /// Runs the haven binary with `backup` subcommand to export to a local .zip file
    func runBackupExport(config: HavenConfig, outputPath: String, completion: @escaping @Sendable (Bool) -> Void) {
        // Must stop relay first to release DB locks
        let wasRunning = self.isRunning
        
        let executeBackup = {
            // Force clear locks before running backup to avoid "resource temporarily unavailable"
            self.performClearDatabaseLocks(at: ConfigService.shared.relayDataDir)
            
            self.runHavenSubcommand(config: config, arguments: ["backup", outputPath]) { exitCode in
                Task { @MainActor in
                    completion(exitCode == 0)
                    // Restart if it was running
                    if wasRunning {
                        self.startRelay(config: config)
                    }
                }
            }
        }
        
        if wasRunning {
            self.stopRelay {
                executeBackup()
            }
        } else {
            executeBackup()
        }
    }

    /// Runs the haven binary with `restore` subcommand to import from a local .zip file
    func runBackupRestore(config: HavenConfig, inputPath: String, completion: @escaping @Sendable (Bool) -> Void) {
        // Must stop relay first to release DB locks
        let wasRunning = self.isRunning
        
        let executeRestore = {
            self.performClearDatabaseLocks(at: ConfigService.shared.relayDataDir)
            
            self.runHavenSubcommand(config: config, arguments: ["restore", inputPath]) { exitCode in
                Task { @MainActor in
                    completion(exitCode == 0)
                    // Restart if it was running (and restore succeeded? maybe always restart to be safe)
                    if wasRunning {
                        // Add a delay to ensure port release and prevent race conditions
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            self.startRelay(config: config)
                        }
                    }
                }
            }
        }
        
        if wasRunning {
            self.stopRelay {
                executeRestore()
            }
        } else {
            executeRestore()
        }
    }

    /// Runs the haven binary with `backup --to-cloud`
    func runBackupToCloud(config: HavenConfig) {
        let wasRunning = self.isRunning
        
        let executeBackup = {
            self.performClearDatabaseLocks(at: ConfigService.shared.relayDataDir)
            
            self.runHavenSubcommand(config: config, arguments: ["backup", "--to-cloud"]) { exitCode in
                Task { @MainActor in
                    let msg = exitCode == 0 ? "Cloud backup complete" : "Cloud backup failed (exit \(exitCode))"
                    self.logs.append(LogEntry(timestamp: Date(), level: exitCode == 0 ? "INFO" : "ERROR", message: msg))
                    
                    if wasRunning {
                        self.startRelay(config: config)
                    }
                }
            }
        }
        
        if wasRunning {
            self.stopRelay {
                executeBackup()
            }
        } else {
            executeBackup()
        }
    }

    /// Runs the haven binary with `restore --from-cloud`
    func runRestoreFromCloud(config: HavenConfig) {
        let wasRunning = self.isRunning
        
        let executeRestore = {
            self.performClearDatabaseLocks(at: ConfigService.shared.relayDataDir)
            
            self.runHavenSubcommand(config: config, arguments: ["restore", "--from-cloud"]) { exitCode in
                Task { @MainActor in
                    let msg = exitCode == 0 ? "Cloud restore complete" : "Cloud restore failed (exit \(exitCode))"
                    self.logs.append(LogEntry(timestamp: Date(), level: exitCode == 0 ? "INFO" : "ERROR", message: msg))
                    
                    if wasRunning {
                        self.startRelay(config: config)
                    }
                }
            }
        }
        
        if wasRunning {
            self.stopRelay {
                executeRestore()
            }
        } else {
            executeRestore()
        }
    }

    /// Generic helper to run haven binary with given arguments in a fire-and-forget subprocess
    private func runHavenSubcommand(config: HavenConfig, arguments: [String], completion: @escaping @Sendable (Int32) -> Void) {
        let relayDataDir = ConfigService.shared.relayDataDir

        guard let executablePath = Bundle.main.path(forResource: "haven", ofType: ""),
              FileManager.default.fileExists(atPath: executablePath) else {
            logs.append(LogEntry(timestamp: Date(), level: "ERROR", message: "haven binary not found for subcommand"))
            completion(1)
            return
        }

        // Ensure config files are up to date
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted

        let importRelaysURL = relayDataDir.appendingPathComponent(config.importSeedRelaysFile)
        if let data = try? encoder.encode(config.importSeedRelays) {
            try? data.write(to: importRelaysURL)
        }

        // Write whitelisted npubs file
        let npubsURL = relayDataDir.appendingPathComponent(config.whitelistedNpubsFile)
        if let data = try? encoder.encode(config.whitelistedNpubs) {
            try? data.write(to: npubsURL)
        }
        
        // Write blacklisted npubs file
        let blacklistedURL = relayDataDir.appendingPathComponent(config.blacklistedNpubsFile)
        if let data = try? encoder.encode(config.blacklistedNpubs) {
            try? data.write(to: blacklistedURL)
        }

        // Write .env
        let envURL = relayDataDir.appendingPathComponent(".env")
        let envContent = generateMinimalEnv(config: config)
        try? envContent.write(to: envURL, atomically: true, encoding: .utf8)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executablePath)
        proc.arguments = arguments
        proc.currentDirectoryURL = relayDataDir

        var env: [String: String] = [:]
        let sysEnv = ProcessInfo.processInfo.environment
        env["PATH"] = sysEnv["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        env["TMPDIR"] = NSTemporaryDirectory()
        env["USER"] = sysEnv["USER"] ?? "haven"

        let configEnv = generateEnvDictionary(config: config)
        for (key, value) in configEnv {
            env[key] = value
        }
        env["RELAY_BIND_ADDRESS"] = "127.0.0.1"
        proc.environment = env

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        proc.standardInput = Pipe()

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                Task { @MainActor in
                    self?.processOutput(str)
                }
            }
        }

        proc.terminationHandler = { p in
            completion(p.terminationStatus)
        }

        do {
            try proc.run()
            logs.append(LogEntry(timestamp: Date(), level: "INFO", message: "Running: haven \(arguments.joined(separator: " "))"))
        } catch {
            logs.append(LogEntry(timestamp: Date(), level: "ERROR", message: "Failed to run haven subcommand: \(error)"))
            completion(1)
        }
    }
    
    // MARK: - Blossom Backup
    
    func runBlossomBackup(config: HavenConfig, outputPath: String, completion: @escaping @Sendable (Bool) -> Void) {
        let blossomDir = ConfigService.shared.relayDataDir.appendingPathComponent(config.blossomPath)
        
        // Ensure blossom directory exists
        guard FileManager.default.fileExists(atPath: blossomDir.path) else {
            logs.append(LogEntry(timestamp: Date(), level: "WARN", message: "Blossom directory not found: \(blossomDir.path)"))
            completion(false)
            return
        }
        
        logs.append(LogEntry(timestamp: Date(), level: "INFO", message: "Starting Blossom backup..."))
        
        // Create a temporary file path
        let tempDir = FileManager.default.temporaryDirectory
        let tempZipURL = tempDir.appendingPathComponent("blossom_backup_\(UUID().uuidString).zip")
        
        // Use /usr/bin/zip to archive to TEMP first
        // This avoids sandbox issues where the subprocess cannot write to the user-selected URL directly
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        
        proc.currentDirectoryURL = blossomDir
        // -r: recursive
        proc.arguments = ["-r", tempZipURL.path, "."]
        
        // Capture output for debugging
        let pipeOut = Pipe()
        let pipeErr = Pipe()
        proc.standardOutput = pipeOut
        proc.standardError = pipeErr
        
        proc.terminationHandler = { [weak self] p in
            // Read data before notification
            _ = pipeOut.fileHandleForReading.readDataToEndOfFile()
            let errData = pipeErr.fileHandleForReading.readDataToEndOfFile()
            
            Task { @MainActor in
                if let errStr = String(data: errData, encoding: .utf8), !errStr.isEmpty {
                     self?.logs.append(LogEntry(timestamp: Date(), level: "ERROR", message: "Zip Error: \(errStr)"))
                }
                
                let success = p.terminationStatus == 0
                if success {
                    // Now move/copy the temp file to the actual destination
                    do {
                        let destURL = URL(fileURLWithPath: outputPath)
                        // Remove destination if it exists (overwrite)
                        if FileManager.default.fileExists(atPath: destURL.path) {
                            try FileManager.default.removeItem(at: destURL)
                        }
                        try FileManager.default.moveItem(at: tempZipURL, to: destURL)
                        self?.logs.append(LogEntry(timestamp: Date(), level: "INFO", message: "Blossom backup saved to \(outputPath)"))
                        completion(true)
                    } catch {
                        self?.logs.append(LogEntry(timestamp: Date(), level: "ERROR", message: "Failed to move backup to destination: \(error.localizedDescription)"))
                        // Try to clean up temp
                        try? FileManager.default.removeItem(at: tempZipURL)
                        completion(false)
                    }
                } else {
                    self?.logs.append(LogEntry(timestamp: Date(), level: "ERROR", message: "Blossom backup failed (exit \(p.terminationStatus))"))
                    try? FileManager.default.removeItem(at: tempZipURL)
                    completion(false)
                }
            }
        }
        
        do {
            try proc.run()
        } catch {
            logs.append(LogEntry(timestamp: Date(), level: "ERROR", message: "Failed to run zip command: \(error)"))
            completion(false)
        }
    }
    
    func runBlossomImport(config: HavenConfig, inputPath: String, completion: @escaping @Sendable (Bool) -> Void) {
        let blossomDir = ConfigService.shared.relayDataDir.appendingPathComponent(config.blossomPath)
        
        // Ensure blossom directory exists
        try? FileManager.default.createDirectory(at: blossomDir, withIntermediateDirectories: true)
        
        logs.append(LogEntry(timestamp: Date(), level: "INFO", message: "Starting Blossom import..."))
        
        // Copy to temp first to avoid sandbox issues with unzip subprocess
        let tempDir = FileManager.default.temporaryDirectory
        let tempZipURL = tempDir.appendingPathComponent("blossom_import_\(UUID().uuidString).zip")
        
        do {
            if FileManager.default.fileExists(atPath: tempZipURL.path) {
                try FileManager.default.removeItem(at: tempZipURL)
            }
            try FileManager.default.copyItem(atPath: inputPath, toPath: tempZipURL.path)
        } catch {
            logs.append(LogEntry(timestamp: Date(), level: "ERROR", message: "Failed to copy import file to temp: \(error)"))
            completion(false)
            return
        }
        
        // Use /usr/bin/unzip
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        // -o: overwrite existing files without prompting
        // -d: extract to directory
        proc.arguments = ["-o", tempZipURL.path, "-d", blossomDir.path]
        
        let pipeOut = Pipe()
        let pipeErr = Pipe()
        proc.standardOutput = pipeOut
        proc.standardError = pipeErr
        
        proc.terminationHandler = { [weak self] p in
             _ = pipeOut.fileHandleForReading.readDataToEndOfFile()
             let errData = pipeErr.fileHandleForReading.readDataToEndOfFile()
            
            Task { @MainActor in
                if let errStr = String(data: errData, encoding: .utf8), !errStr.isEmpty {
                     // Check if it's actually an error or just warning
                     if errStr.contains("checkdir error") || errStr.contains("cannot create") {
                         self?.logs.append(LogEntry(timestamp: Date(), level: "ERROR", message: "Unzip Error: \(errStr)"))
                     }
                }
                
                // Cleanup temp
                try? FileManager.default.removeItem(at: tempZipURL)
                
                let success = p.terminationStatus == 0
                if success {
                    self?.logs.append(LogEntry(timestamp: Date(), level: "INFO", message: "Blossom import complete."))
                } else {
                    self?.logs.append(LogEntry(timestamp: Date(), level: "ERROR", message: "Blossom import failed (exit \(p.terminationStatus))"))
                }
                completion(success)
            }
        }
        
        do {
            try proc.run()
        } catch {
            logs.append(LogEntry(timestamp: Date(), level: "ERROR", message: "Failed to run unzip command: \(error)"))
            try? FileManager.default.removeItem(at: tempZipURL)
            completion(false)
        }
    }
    
    // MARK: - Blossom Extensions Logic
    
    func runBlossomExportWithExtensions(config: HavenConfig, outputPath: String, completion: @escaping @Sendable (Bool) -> Void) {
        let blossomDir = ConfigService.shared.relayDataDir.appendingPathComponent(config.blossomPath)
        
        guard FileManager.default.fileExists(atPath: blossomDir.path) else {
            logs.append(LogEntry(timestamp: Date(), level: "WARN", message: "Blossom directory not found: \(blossomDir.path)"))
            completion(false)
            return
        }
        
        logs.append(LogEntry(timestamp: Date(), level: "INFO", message: "Starting Blossom export with extensions..."))
        
        // Create temp dir for staging files with extensions
        let tempDir = FileManager.default.temporaryDirectory
        let stagingDir = tempDir.appendingPathComponent("BlossomExport_\(UUID().uuidString)")
        let tempZipURL = tempDir.appendingPathComponent("blossom_export_temp_\(UUID().uuidString).zip")
        
        do {
            try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            
            // Iterate files in blossomDir
            let fileURLs = try FileManager.default.contentsOfDirectory(at: blossomDir, includingPropertiesForKeys: nil)
            
            for fileURL in fileURLs {
                // Ignore hidden files
                if fileURL.lastPathComponent.hasPrefix(".") { continue }
                
                // Determine extension using 'file --extension'
                let ext = getExtension(for: fileURL)
                
                let newFilename = fileURL.lastPathComponent + (ext.isEmpty ? "" : ".\(ext)")
                let destURL = stagingDir.appendingPathComponent(newFilename)
                
                try FileManager.default.copyItem(at: fileURL, to: destURL)
            }
            
            // Zip the staging directory content
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            proc.currentDirectoryURL = stagingDir
            // -r: recursive, -j: junk paths (flatten) - not using -j so structure is preserved if any, but flat here
            proc.arguments = ["-r", tempZipURL.path, "."]
            
            let pipeOut = Pipe()
            let pipeErr = Pipe()
            proc.standardOutput = pipeOut
            proc.standardError = pipeErr
            
            proc.terminationHandler = { [weak self] p in
                // Cleanup staging
                try? FileManager.default.removeItem(at: stagingDir)
                
                 _ = pipeOut.fileHandleForReading.readDataToEndOfFile()
                 let errData = pipeErr.fileHandleForReading.readDataToEndOfFile()
                
                Task { @MainActor in
                    if let errStr = String(data: errData, encoding: .utf8), !errStr.isEmpty {
                         self?.logs.append(LogEntry(timestamp: Date(), level: "ERROR", message: "Zip Error: \(errStr)"))
                    }
                    
                    let success = p.terminationStatus == 0
                    if success {
                        // Move zip to final destination
                        do {
                            let destURL = URL(fileURLWithPath: outputPath)
                            if FileManager.default.fileExists(atPath: destURL.path) {
                                try FileManager.default.removeItem(at: destURL)
                            }
                            try FileManager.default.moveItem(at: tempZipURL, to: destURL)
                            self?.logs.append(LogEntry(timestamp: Date(), level: "INFO", message: "Blossom export saved to \(outputPath)"))
                            completion(true)
                        } catch {
                            self?.logs.append(LogEntry(timestamp: Date(), level: "ERROR", message: "Failed to move export to destination: \(error.localizedDescription)"))
                            try? FileManager.default.removeItem(at: tempZipURL)
                            completion(false)
                        }
                    } else {
                        self?.logs.append(LogEntry(timestamp: Date(), level: "ERROR", message: "Blossom export failed (exit \(p.terminationStatus))"))
                        try? FileManager.default.removeItem(at: tempZipURL)
                        completion(false)
                    }
                }
            }
            
            try proc.run()
            
        } catch {
            logs.append(LogEntry(timestamp: Date(), level: "ERROR", message: "Export failed: \(error.localizedDescription)"))
            try? FileManager.default.removeItem(at: stagingDir)
            completion(false)
        }
    }
    
    func runBlossomImportStrippingExtensions(config: HavenConfig, inputPath: String, completion: @escaping @Sendable (Bool) -> Void) {
        let blossomDir = ConfigService.shared.relayDataDir.appendingPathComponent(config.blossomPath)
        
        // Ensure blossom directory exists
        try? FileManager.default.createDirectory(at: blossomDir, withIntermediateDirectories: true)
        
        logs.append(LogEntry(timestamp: Date(), level: "INFO", message: "Starting Blossom import (stripping extensions)..."))
        
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
            logs.append(LogEntry(timestamp: Date(), level: "ERROR", message: "Failed to setup temp dirs: \(error)"))
            completion(false)
            return
        }
        
        // 2. Unzip to staging
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-o", tempZipURL.path, "-d", stagingDir.path]
        
        let pipeOut = Pipe()
        let pipeErr = Pipe()
        proc.standardOutput = pipeOut
        proc.standardError = pipeErr
        
        proc.terminationHandler = { [weak self] p in
             // Cleanup zip copy
             try? FileManager.default.removeItem(at: tempZipURL)
             
             _ = pipeOut.fileHandleForReading.readDataToEndOfFile()
             let errData = pipeErr.fileHandleForReading.readDataToEndOfFile()
            
            Task { @MainActor in
                if let errStr = String(data: errData, encoding: .utf8), !errStr.isEmpty {
                     if errStr.contains("checkdir error") || errStr.contains("cannot create") {
                         self?.logs.append(LogEntry(timestamp: Date(), level: "ERROR", message: "Unzip Error: \(errStr)"))
                     }
                }
                
                if p.terminationStatus == 0 {
                    // 3. Process files in staging
                    do {
                        let fileURLs = try FileManager.default.contentsOfDirectory(at: stagingDir, includingPropertiesForKeys: nil)
                        var count = 0
                        
                        for fileURL in fileURLs {
                            // Recursively find files if unzip created subdirs? 
                            // For now assume flat or verify if unzip -j was needed. 
                            // Actually backup used -r, so structure is preserved. 
                            // If structure is flat (current backup), we are good.
                            // If user provides arbitrary zip, we might need deep scan.
                            // Sticking to basic flat scan for now as per plan.
                            
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
                                self?.logs.append(LogEntry(timestamp: Date(), level: "WARN", message: "Skipping invalid blossom file: \(fileURL.lastPathComponent)"))
                            }
                        }
                        
                        self?.logs.append(LogEntry(timestamp: Date(), level: "INFO", message: "Blossom import complete. Imported \(count) files."))
                        try? FileManager.default.removeItem(at: stagingDir)
                        completion(true)
                        
                    } catch {
                         self?.logs.append(LogEntry(timestamp: Date(), level: "ERROR", message: "Error processing imported files: \(error)"))
                         try? FileManager.default.removeItem(at: stagingDir)
                         completion(false)
                    }
                } else {
                    self?.logs.append(LogEntry(timestamp: Date(), level: "ERROR", message: "Unzip failed (exit \(p.terminationStatus))"))
                    try? FileManager.default.removeItem(at: stagingDir)
                    completion(false)
                }
            }
        }
        
        do {
            try proc.run()
        } catch {
             try? FileManager.default.removeItem(at: tempZipURL)
             try? FileManager.default.removeItem(at: stagingDir)
             logs.append(LogEntry(timestamp: Date(), level: "ERROR", message: "Failed to run unzip: \(error)"))
             completion(false)
        }
    }
    
    // Helper to get extension from file magic bytes
    private func getExtension(for url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "bin" }
        defer { handle.closeFile() }
        let header = handle.readData(ofLength: 12)
        guard header.count >= 4 else { return "bin" }
        let bytes = [UInt8](header)

        let mime: String
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
            mime = "image/jpeg"
        } else if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            mime = "image/png"
        } else if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) {
            mime = "image/gif"
        } else if bytes.count >= 12,
                  bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46 {
            // RIFF container — check subtype at offset 8
            if bytes[8] == 0x57, bytes[9] == 0x45, bytes[10] == 0x42, bytes[11] == 0x50 {
                mime = "image/webp"    // RIFF....WEBP
            } else if bytes[8] == 0x57, bytes[9] == 0x41, bytes[10] == 0x56, bytes[11] == 0x45 {
                mime = "audio/wav"     // RIFF....WAVE
            } else {
                return "bin"
            }
        } else if bytes.count >= 12,
                  bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 {
            // ftyp container — check brand at offset 8
            if bytes[8] == 0x71, bytes[9] == 0x74, bytes[10] == 0x20, bytes[11] == 0x20 {
                mime = "video/quicktime"  // ftyp qt  → .mov
            } else {
                mime = "video/mp4"
            }
        } else if bytes.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) {
            mime = "video/webm"
        } else if bytes.starts(with: [0x25, 0x50, 0x44, 0x46]) {
            mime = "application/pdf"
        } else if bytes.starts(with: [0x49, 0x44, 0x33]) {
            mime = "audio/mpeg"        // ID3 tag → .mp3
        } else if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] & 0xE0 == 0xE0 {
            mime = "audio/mpeg"        // MPEG sync word → .mp3
        } else {
            return "bin"
        }

        if let utType = UTType(mimeType: mime),
           let ext = utType.preferredFilenameExtension {
            return ext
        }
        return "bin"
    }
}
