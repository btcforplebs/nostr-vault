import Foundation
import Combine

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
    
    @Published var logs: [LogEntry] = []
    
    // Metrics
    @Published var memoryUsage: Double = 0
    @Published var cpuUsage: Double = 0
    @Published var activeConnections: Int = 0
    @Published var eventsStored: Int = 0
    
    private var process: Process?
    private var outputPipe: Pipe?
    private var logReader: FileHandle?
    
    // Track if we are in the middle of a shutdown to prevent recursive restarts
    private var isShuttingDown = false
    
    private var pendingImportConfig: HavenConfig?
    @Published var startDate: Date?
    
    // Auto-fix locks
    private var lastConfig: HavenConfig?
    private var retryAttempted = false
    private var needsLockFix = false
    
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
    
    func startRelay(config: HavenConfig) {
        // Strict guard: Must be idle and NO process should be running
        guard state == .idle && (process == nil || !process!.isRunning) else {
            logs.append(LogEntry(timestamp: Date(), level: "WARN", message: "Cannot start relay: current state is \(state) (running: \(process?.isRunning ?? false))"))
            return
        }
        
        self.lastConfig = config
        self.retryAttempted = false
        self.needsLockFix = false
        
        let relayDataDir = ConfigService.shared.relayDataDir
        try? FileManager.default.createDirectory(at: relayDataDir, withIntermediateDirectories: true)
        
        // Ensure critical subdirectories exist for the Go relay
        try? FileManager.default.createDirectory(at: relayDataDir.appendingPathComponent("data"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: relayDataDir.appendingPathComponent("blossom"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: relayDataDir.appendingPathComponent("cache"), withIntermediateDirectories: true)
        
        // Copy templates directory
        if let templatesPath = Bundle.main.path(forResource: "templates", ofType: "") {
             let destURL = relayDataDir.appendingPathComponent("templates")
             // Always update templates on start (clean up old first)
             if FileManager.default.fileExists(atPath: destURL.path) {
                 try? FileManager.default.removeItem(at: destURL)
             }
             try? FileManager.default.copyItem(at: URL(fileURLWithPath: templatesPath), to: destURL)
             logs.append(LogEntry(timestamp: Date(), level: "INFO", message: "Copied templates to \(destURL.path)"))
        } else {
             logs.append(LogEntry(timestamp: Date(), level: "WARN", message: "Templates folder not found in Bundle"))
        }

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

        // Check bundle for the binary
        guard let executablePath = Bundle.main.path(forResource: "haven", ofType: ""),
              FileManager.default.fileExists(atPath: executablePath) else {
            logs.append(LogEntry(timestamp: Date(), level: "ERROR", message: "haven binary not found in application bundle"))
            return
        }
        
        logs.append(LogEntry(timestamp: Date(), level: "INFO", message: "Starting relay from: \(executablePath)"))
        
        // Reset conflict state
        self.isPortConflict = false
        
        // Always try to clear locks and ensure directories exist
        cleanupBeforeImport()
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
        env["RELAY_BIND_ADDRESS"] = "0.0.0.0"
        
        process.environment = env
        
        logs.append(LogEntry(timestamp: Date(), level: "INFO", message: "Env: HOME=\(env["HOME"]?.prefix(25) ?? "")... PORT=\(env["RELAY_PORT"] ?? "") BIND=\(env["RELAY_BIND_ADDRESS"] ?? "")"))
        logs.append(LogEntry(timestamp: Date(), level: "INFO", message: "Paths: BLOSSOM=\(env["BLOSSOM_PATH"] ?? "") DB=\(env["DATABASE_PATH"] ?? "")"))
        
        // Redirect stdout/stderr to a file to prevent pipe buffer blocking
        let logFileURL = relayDataDir.appendingPathComponent("relay.log")
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        }
        
        do {
            let logHandle = try FileHandle(forWritingTo: logFileURL)
            logHandle.seekToEndOfFile()
            process.standardOutput = logHandle
            process.standardError = logHandle
            
            // We can still tail this file if needed, or just let the user view it in Console
            logs.append(LogEntry(timestamp: Date(), level: "INFO", message: "Redirecting output to \(logFileURL.path)"))
            
            // Tail the log file to restore UI updates
            let readHandle = try FileHandle(forReadingFrom: logFileURL)
            // Seek to end so we only read new logs
            readHandle.seekToEndOfFile()
            
            readHandle.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                    Task { @MainActor in
                        self?.processOutput(str)
                    }
                }
            }
            
            self.logReader = readHandle
        } catch {
             logs.append(LogEntry(timestamp: Date(), level: "ERROR", message: "Failed to create log handle: \(error)"))
        }
        
        process.standardInput = Pipe()
        
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
                
                // Check if we need to auto-fix locks
                if self.needsLockFix && !self.retryAttempted && previousState != .stopping {
                    self.logs.append(LogEntry(timestamp: Date(), level: "WARN", message: "Database lock detected. Attempting automatic fix..."))
                    self.retryAttempted = true
                    self.clearDatabaseLocks {
                        Task { @MainActor in
                            if let config = self.lastConfig {
                                self.startRelay(config: config)
                            }
                        }
                    }
                    return
                }
                
                self.isShuttingDown = false
                self.state = .idle
                self.isRunning = false
                self.isBooting = false
                self.isImporting = false
                
                self.logs.append(LogEntry(timestamp: Date(), level: "INFO", message: "Relay process terminated (Exit Code: \(proc.terminationStatus))"))
            }
        }
        
        self.state = .booting
        isRunning = true
        isBooting = true
        bootStatusMessage = "Starting system..."
        
        // Launch the process (non-blocking)
        do {
            try process.run()
        } catch {
            logs.append(LogEntry(timestamp: Date(), level: "ERROR", message: "Failed to launch relay process: \(error.localizedDescription)"))
            self.state = .idle
            isRunning = false
            isBooting = false
            return
        }
        isLocked = false
        startDate = Date()
        startMetricsTimer()
    }
    
    func clearDatabaseLocks(completion: (@Sendable () -> Void)? = nil) {
        let relayDataDir = ConfigService.shared.relayDataDir
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let dbDir = relayDataDir.appendingPathComponent("data")
            
            // Relays list from init.go: blossom, chat, inbox, outbox, private
            let dbNames = ["blossom", "chat", "inbox", "outbox", "private"]
            
            for name in dbNames {
                let lockFile = dbDir.appendingPathComponent(name).appendingPathComponent("LOCK")
                if FileManager.default.fileExists(atPath: lockFile.path) {
                    try? FileManager.default.removeItem(at: lockFile)
                }
            }
            
            Task { @MainActor in
                self?.isLocked = false
                self?.logs.append(LogEntry(timestamp: Date(), level: "INFO", message: "Database locks cleared. You can now try starting the relay again."))
                completion?()
            }
        }
    }
    
    nonisolated private func killAllHavenProcesses() {
        // No-op in Sandbox: We cannot use pkill/killall.
        // We rely on process.terminate() for our managed process.
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
        process.terminate()
        isBooting = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            completion?()
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
    private func cleanupBeforeImport() {
        // In Sandbox, we cannot use pkill/killall.
        // Clear database lock files from the correct locations
        let relayDataDir = ConfigService.shared.relayDataDir
        let dbDir = relayDataDir.appendingPathComponent("data")
        
        // Standard data DBs
        let standardDBs = ["chat", "inbox", "outbox", "private", "wot"]
        for name in standardDBs {
            let lockFile = dbDir.appendingPathComponent(name).appendingPathComponent("LOCK")
            if FileManager.default.fileExists(atPath: lockFile.path) {
                try? FileManager.default.removeItem(at: lockFile)
            }
        }
        
        // Blossom DB is separate (at root of relayDataDir)
        let blossomLock = relayDataDir.appendingPathComponent("blossom").appendingPathComponent("LOCK")
        if FileManager.default.fileExists(atPath: blossomLock.path) {
            try? FileManager.default.removeItem(at: blossomLock)
        }
    }
    
    func importNotes(config: HavenConfig) {
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
        cleanupBeforeImport()
        
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
        process.arguments = ["--import"]
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
        
        // Bind to all interfaces by default
        env["RELAY_BIND_ADDRESS"] = "0.0.0.0"
        
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
        
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                Task { @MainActor in
                    self?.processOutput(str)
                }
            }
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
                
                if exitCode == 0 || self.importCompleted {
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
                    
                    // Even if import failed, we might want to try starting the relay anyway?
                    // For now, let's keep it safe but allow manual restart by resetting state
                    self.pendingImportConfig = nil
                }
                
                self.isShuttingDown = false
            }
        }
        
        // Launch the process (non-blocking)
        do {
            try process.run()
            logs.append(LogEntry(timestamp: Date(), level: "INFO", message: "Import process started (PID: \(process.processIdentifier))"))
        } catch {
            let errorMsg = "Failed to launch import process: \(error.localizedDescription)"
            logs.append(LogEntry(timestamp: Date(), level: "ERROR", message: errorMsg))
            DispatchQueue.main.async {
                self.isImporting = false
                self.importStatusMessage = "Launch failed: \(error.localizedDescription)"
            }
        }
    }
    
    private func generateMinimalEnv(config: HavenConfig) -> String {
        let envDict = generateEnvDictionary(config: config)
        var content = ""
        for (key, value) in envDict.sorted(by: { $0.key < $1.key }) {
            // Values should NOT be quoted in most shell-agnostic parsers unless they have spaces
            // Nostr-rs-relay/Haven parser might be strict.
            if value.contains(" ") {
                content += "\(key)=\"\(value)\"\n"
            } else {
                content += "\(key)=\(value)\n"
            }
        }
        return content
    }
    
    private func processOutput(_ output: String) {
        let lines = output.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard !lines.isEmpty else { return }
        
        var newEntries: [LogEntry] = []
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
               } else if line.contains("importing inbox notes") || line.contains("Importing inbox notes") {
                   importStatusMessage = "Importing tagged notes..."
                   importProgress = 0.85 // More conservative estimate
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
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            if let process = self.process, process.isRunning {
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
                } else if lowerLine.contains("starting") {
                    if let service = line.components(separatedBy: "starting ").last ?? line.components(separatedBy: "Starting ").last {
                         bootStatusMessage = "Starting \(service.trimmingCharacters(in: .punctuationCharacters))..."
                    }
                } else if lowerLine.contains("loading") {
                     bootStatusMessage = "Loading databases..."
                } else if lowerLine.contains("listening on") {
                     bootStatusMessage = "Establishing listener..."
                } else if lowerLine.contains("wot") || lowerLine.contains("pubkeys") || lowerLine.contains("analysed") || lowerLine.contains("network size") {
                    let pattern = "(\\d+)" // Just find digits
                    if let regex = try? NSRegularExpression(pattern: pattern, options: []),
                       let _ = regex.firstMatch(in: line, options: [], range: NSRange(line.startIndex..., in: line)) {
                        let matches = regex.matches(in: line, options: [], range: NSRange(line.startIndex..., in: line))
                        if let lastMatch = matches.last, let countRange = Range(lastMatch.range(at: 0), in: line) {
                            let count = line[countRange]
                            if count.count < 10 { // Avoid long hex/hashes
                                if lowerLine.contains("analysed") {
                                    bootStatusMessage = "Analysing \(count) pubkeys..."
                                } else if lowerLine.contains("network size") {
                                    bootStatusMessage = "Network: \(count) profiles..."
                                } else if lowerLine.contains("minimum followers") {
                                    bootStatusMessage = "WoT: \(count) trusted keys..."
                                } else {
                                    bootStatusMessage = "WoT: Loading \(count) keys..."
                                }
                            }
                        }
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
        
        // Batch append logs
        logs.append(contentsOf: newEntries)
        if logs.count > 1000 {
            logs.removeFirst(max(0, logs.count - 1000))
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
        return [
            "OWNER_NPUB": config.ownerNpub,
            "RELAY_URL": config.relayURL,
            "RELAY_PORT": String(config.relayPort),
            "RELAY_BIND_ADDRESS": "0.0.0.0",
            "DB_ENGINE": config.dbEngine,
            "LMDB_MAPSIZE": "0",
            "DATABASE_PATH": ConfigService.shared.relayDataDir.appendingPathComponent("data").standardized.path + "/",
            "BLOSSOM_PATH": ConfigService.shared.relayDataDir.appendingPathComponent(config.blossomPath).standardized.path + "/",
            "HAVEN_LOG_LEVEL": config.logLevel,
            "LOG_FORMAT": "$$host $$remote_addr - $$remote_user [$$time_local] \"$$request\" $$status $$body_bytes_sent \"$$http_referer\" \"$$http_user_agent\" \"$$upstream_addr\"",
            "TZ": "UTC",
            
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
            "IMPORT_OWNER_NOTES_FETCH_TIMEOUT_SECONDS": "300", // Increased from 60
            "IMPORT_TAGGED_NOTES_FETCH_TIMEOUT_SECONDS": "600", // Increased from 120
            
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
    
    // pkill removed to ensure consistent behavior across debug and release builds
}
