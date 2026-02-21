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
    
    private var outputPipe: Pipe?
    private var logBuffer = Data() // Buffer for incomplete log lines
    
    // Track if we are in the middle of a shutdown to prevent recursive restarts
    private var isShuttingDown: Bool = false
    
    private var pendingImportConfig: HavenConfig?
    @Published var startDate: Date?
    
    // Auto-fix locks
    @Published var lastConfig: HavenConfig?
    private var retryAttempted = false
    private var needsLockFix = false

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
        guard state == .idle && !isRunning else {
            logs.append(LogEntry(timestamp: Date(), level: "WARN", message: "Cannot start relay: current state is \(state) (running: \(isRunning))"))
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

        // Reset conflict state
        self.isPortConflict = false

        let envURL = relayDataDir.appendingPathComponent(".env")
        let envContent = generateMinimalEnv(config: config)
        try? envContent.write(to: envURL, atomically: true, encoding: .utf8)
        
        logs.append(LogEntry(timestamp: Date(), level: "INFO", message: "Wrote .env to \(envURL.path)"))
        logs.append(LogEntry(timestamp: Date(), level: "INFO", message: "Working Directory: \(relayDataDir.path)"))
        
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
        setenv("RELAY_BIND_ADDRESS", "127.0.0.1", 1)
        if let cKey = strdup("RELAY_BIND_ADDRESS"), let cValue = strdup("127.0.0.1") {
            SetHavenEnvC(cKey, cValue)
            free(cKey)
            free(cValue)
        }
        
        // Change working directory so Go creates files in relayDataDir
        FileManager.default.changeCurrentDirectoryPath(relayDataDir.path)
        
        // Redirect stdout/stderr to capture Go logs
        captureOutput(in: relayDataDir)
        
        logs.append(LogEntry(timestamp: Date(), level: "INFO", message: "Captured output natively"))
        
        self.state = .booting
        isRunning = true
        isBooting = true
        bootStatusMessage = "Starting system..."
        
        // Launch the C-Shared relay on a background thread
        DispatchQueue.global().async { [weak self] in
            // 0 = false (not in import mode)
            StartRelayC(0)
            
            // StartRelayC returns instantly because http.ListenAndServe runs in a goroutine
            DispatchQueue.main.async {
                self?.logs.append(LogEntry(timestamp: Date(), level: "INFO", message: "Relay C-Shared process started"))
            }
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
    
    
    func stopRelay(completion: (() -> Void)? = nil) {
        // Must check if running, booting, or importing
        guard self.isRunning || self.isBooting || self.isImporting else {
            self.state = .idle
            isRunning = false
            completion?()
            return
        }
        
        self.state = .stopping
        self.isShuttingDown = true
        stopMetricsTimer()
        stopLogThrottler()
        isBooting = false
        
        logs.append(LogEntry(timestamp: Date(), level: "INFO", message: "Stopping C-Shared relay natively..."))
        
        DispatchQueue.global().async { [weak self] in
            // Tell the Go side to shut down the server and cancel the context
            StopRelayC()

            // Wait for OS to fully release DB file locks before allowing restart
            Thread.sleep(forTimeInterval: 1.0)

            DispatchQueue.main.async {
                self?.logs.append(LogEntry(timestamp: Date(), level: "INFO", message: "C-Shared relay natively stopped."))
                self?.state = .idle
                self?.isRunning = false
                self?.isShuttingDown = false
                
                // If we were stopping to start an import, trigger it now
                if let importConfig = self?.pendingImportConfig {
                    self?.pendingImportConfig = nil
                    self?.importNotes(config: importConfig)
                }
                
                completion?()
            }
        }
    }
    
    /// Aggressively kill any running haven process, clear all database locks, reset state, and restart.
    /// This replaces the old "pkill -9 haven" manual step.
    func forceCleanAndRestart() {
        self.state = .stopping
        logs.append(LogEntry(timestamp: Date(), level: "INFO", message: "Force clean & restart initiated..."))
        
        let relayDataDir = ConfigService.shared.relayDataDir
        
        DispatchQueue.global().async { [weak self] in
            StopRelayC()
            
            // Wait for OS to release file locks
            Thread.sleep(forTimeInterval: 0.5)
            
            self?.performClearDatabaseLocks(at: relayDataDir)
            
            DispatchQueue.main.async {
                self?.state = .idle
                self?.isRunning = false
                self?.isBooting = false
                self?.isLocked = false
                self?.needsLockFix = false
                self?.showProcessKillAlert = false
                self?.isShuttingDown = false
                
                self?.logs.append(LogEntry(timestamp: Date(), level: "INFO", message: "Cleanup complete. Restarting relay..."))
                
                if let config = self?.lastConfig {
                    self?.startRelay(config: config, isRetry: true)
                }
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
        logs.append(LogEntry(timestamp: Date(), level: "DEBUG", message: "importNotes called. Current State: \(state), isRunning: \(isRunning)"))
        
        // Strict guard: Must be idle and NOT running
        guard state == .idle && !isRunning else {
            if (state == .running || state == .booting) && isRunning {
                logs.append(LogEntry(timestamp: Date(), level: "INFO", message: "Stopping running relay to start import..."))
                self.pendingImportConfig = config
                stopRelay()
            } else {
                logs.append(LogEntry(timestamp: Date(), level: "WARN", message: "Cannot start import: current state is \(state) (running: \(isRunning))"))
            }
            return
        }
        
        self.pendingImportConfig = config
        self.state = .importing
        isRunning = false
        isBooting = false
        isImporting = true
        
        clearDatabaseLocks()
        
        let relayDataDir = ConfigService.shared.relayDataDir
        try? FileManager.default.createDirectory(at: relayDataDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: relayDataDir.appendingPathComponent("data"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: relayDataDir.appendingPathComponent("blossom"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: relayDataDir.appendingPathComponent("cache"), withIntermediateDirectories: true)
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        
        if let data = try? encoder.encode(config.importSeedRelays) { try? data.write(to: relayDataDir.appendingPathComponent(config.importSeedRelaysFile)) }
        if let data = try? encoder.encode(config.blastrRelays.isEmpty ? [] : config.blastrRelays) { try? data.write(to: relayDataDir.appendingPathComponent(config.blastrRelaysFile)) }
        if let data = try? encoder.encode(config.whitelistedNpubs) { try? data.write(to: relayDataDir.appendingPathComponent("whitelisted_npubs.json")) }
        if let data = try? encoder.encode(config.blacklistedNpubs) { try? data.write(to: relayDataDir.appendingPathComponent("blacklisted_npubs.json")) }
        
        let envURL = relayDataDir.appendingPathComponent(".env")
        let envContent = generateMinimalEnv(config: config)
        try? envContent.write(to: envURL, atomically: true, encoding: .utf8)
        
        let configEnv = generateEnvDictionary(config: config)
        for (key, value) in configEnv {
            setenv(key, value, 1)
        }
        setenv("RELAY_BIND_ADDRESS", "127.0.0.1", 1)
        
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
                 
                 self.logs.append(LogEntry(timestamp: Date(), level: "INFO", message: "C-Shared Import sequence started"))
                 
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
        
        self.logs.append(LogEntry(timestamp: Date(), level: "INFO", message: "Import process terminated successfully."))
        
        if let restartConfig = self.pendingImportConfig {
            self.pendingImportConfig = nil
            self.logs.append(LogEntry(timestamp: Date(), level: "INFO", message: "Import successful, restarting relay..."))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.startRelay(config: restartConfig)
            }
        }
    }
    
    /// Redirection mechanism for capturing stdout and stderr from C-Shared bindings
    private func captureOutput(in directory: URL) {
        if outputPipe == nil {
            let pipe = Pipe()
            outputPipe = pipe
            
            // Redirect STDOUT and STDERR to our pipe
            dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
            dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
            
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                
                Task { @MainActor in
                    self?.processBufferedOutput(data)
                    
                    if String(data: data, encoding: .utf8) != nil {
                        let logFileURL = directory.appendingPathComponent("relay.log")
                        if !FileManager.default.fileExists(atPath: logFileURL.path) {
                            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
                        }
                        if let fileHandle = try? FileHandle(forWritingTo: logFileURL) {
                            fileHandle.seekToEndOfFile()
                            fileHandle.write(data)
                            try? fileHandle.close()
                        }
                    }
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
                    
                    // Tagged import complete — stop the C-shared relay
                    if line.contains("tagged import complete") {
                        self.isImporting = false
                        self.importCompleted = true
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

    /// Sets environment variables and writes config files so Go's loadConfig() works.
    private func prepareEnvForBackup(config: HavenConfig) {
        let relayDataDir = ConfigService.shared.relayDataDir

        // Write config files that Go reads from the working directory
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted

        if let data = try? encoder.encode(config.importSeedRelays) {
            try? data.write(to: relayDataDir.appendingPathComponent(config.importSeedRelaysFile))
        }
        if let data = try? encoder.encode(config.whitelistedNpubs) {
            try? data.write(to: relayDataDir.appendingPathComponent(config.whitelistedNpubsFile))
        }
        if let data = try? encoder.encode(config.blacklistedNpubs) {
            try? data.write(to: relayDataDir.appendingPathComponent(config.blacklistedNpubsFile))
        }

        let envURL = relayDataDir.appendingPathComponent(".env")
        let envContent = generateMinimalEnv(config: config)
        try? envContent.write(to: envURL, atomically: true, encoding: .utf8)

        let configEnv = generateEnvDictionary(config: config)
        for (key, value) in configEnv {
            setenv(key, value, 1)
        }
        setenv("RELAY_BIND_ADDRESS", "127.0.0.1", 1)

        FileManager.default.changeCurrentDirectoryPath(relayDataDir.path)
    }

    func runBackupExport(config: HavenConfig, outputPath: String, completion: @escaping @Sendable (Bool) -> Void) {
        let wasRunning = self.isRunning

        let executeBackup = {
            self.performClearDatabaseLocks(at: ConfigService.shared.relayDataDir)
            self.prepareEnvForBackup(config: config)

            DispatchQueue.global().async {
                let result = BackupDatabaseC(strdup(outputPath))
                Task { @MainActor in
                    completion(result == 0)
                    if wasRunning {
                        self.startRelay(config: config)
                    }
                }
            }
        }

        if wasRunning {
            self.stopRelay { executeBackup() }
        } else {
            executeBackup()
        }
    }

    func runBackupRestore(config: HavenConfig, inputPath: String, completion: @escaping @Sendable (Bool) -> Void) {
        let wasRunning = self.isRunning

        let executeRestore = {
            self.performClearDatabaseLocks(at: ConfigService.shared.relayDataDir)
            self.prepareEnvForBackup(config: config)

            DispatchQueue.global().async {
                let result = RestoreDatabaseC(strdup(inputPath))
                Task { @MainActor in
                    completion(result == 0)
                    if wasRunning {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            self.startRelay(config: config)
                        }
                    }
                }
            }
        }

        if wasRunning {
            self.stopRelay { executeRestore() }
        } else {
            executeRestore()
        }
    }

    func runBackupToCloud(config: HavenConfig) {
        let wasRunning = self.isRunning

        let executeBackup = {
            self.performClearDatabaseLocks(at: ConfigService.shared.relayDataDir)
            self.prepareEnvForBackup(config: config)

            DispatchQueue.global().async {
                let result = BackupToCloudC()
                Task { @MainActor in
                    let msg = result == 0 ? "Cloud backup complete" : "Cloud backup failed"
                    self.logs.append(LogEntry(timestamp: Date(), level: result == 0 ? "INFO" : "ERROR", message: msg))
                    if wasRunning {
                        self.startRelay(config: config)
                    }
                }
            }
        }

        if wasRunning {
            self.stopRelay { executeBackup() }
        } else {
            executeBackup()
        }
    }

    func runRestoreFromCloud(config: HavenConfig) {
        let wasRunning = self.isRunning

        let executeRestore = {
            self.performClearDatabaseLocks(at: ConfigService.shared.relayDataDir)
            self.prepareEnvForBackup(config: config)

            DispatchQueue.global().async {
                let result = RestoreFromCloudC()
                Task { @MainActor in
                    let msg = result == 0 ? "Cloud restore complete" : "Cloud restore failed"
                    self.logs.append(LogEntry(timestamp: Date(), level: result == 0 ? "INFO" : "ERROR", message: msg))
                    if wasRunning {
                        self.startRelay(config: config)
                    }
                }
            }
        }

        if wasRunning {
            self.stopRelay { executeRestore() }
        } else {
            executeRestore()
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
        guard isRunning else {
            logs.append(LogEntry(timestamp: Date(), level: "WARN", message: "Cannot export: relay must be running to detect file types."))
            completion(false)
            return
        }

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

                let sha256 = fileURL.lastPathComponent
                let proof = detectMimeFromBytes(for: fileURL)
                let claim = fetchMimeFromRelay(config: config, sha256: sha256)
                let resolvedMime = resolveMime(claim: claim, proof: proof)
                let ext = mimeToExtension(resolvedMime)
                logs.append(LogEntry(timestamp: Date(), level: "DEBUG", message: "Export \(sha256.prefix(8))...: claim=\(claim ?? "nil") proof=\(proof) resolved=\(resolvedMime) ext=.\(ext)"))

                let newFilename = sha256 + (ext == "bin" ? "" : ".\(ext)")
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
    
    // Detect MIME type from file magic bytes (the "proof")
    private func detectMimeFromBytes(for url: URL) -> String {
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
    private func classifyFtyp(_ bytes: [UInt8]) -> String {
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
        if brandSet.contains("heic") || brandSet.contains("heix") || brandSet.contains("hevc") {
            return "image/heic"
        }
        if brandSet.contains("qt  ") {
            return "video/quicktime"
        }
        return "video/mp4"
    }

    // Fetch MIME type from the running relay via HEAD request (the "claim")
    private func fetchMimeFromRelay(config: HavenConfig, sha256: String) -> String? {
        guard let url = URL(string: "\(config.webURL)/\(sha256)") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 3

        let semaphore = DispatchSemaphore(value: 0)
        var contentType: String?

        let task = URLSession.shared.dataTask(with: request) { _, response, _ in
            if let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode == 200,
               let ct = httpResponse.value(forHTTPHeaderField: "Content-Type") {
                // Strip parameters (e.g. "image/jpeg; charset=utf-8" → "image/jpeg")
                contentType = ct.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces)
            }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 5)
        return contentType
    }

    // Broad MIME types that allow more specific refinements from relay metadata
    private static let subsetRules: [String: Set<String>] = [
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

    // Resolve claim (relay) vs proof (magic bytes) using trust-but-verify
    private func resolveMime(claim: String?, proof: String) -> String {
        guard let claim = claim else { return proof }
        if claim == proof { return claim }

        // octet-stream from bytes means we couldn't identify it — trust the relay
        if proof == "application/octet-stream" { return claim }

        // Check if proof allows claim as a valid refinement
        if let allowed = Self.subsetRules[proof] {
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
    private static let extensionFallbacks: [String: String] = [
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
    private func mimeToExtension(_ mime: String) -> String {
        if let utType = UTType(mimeType: mime),
           let ext = utType.preferredFilenameExtension {
            return ext
        }
        return Self.extensionFallbacks[mime] ?? "bin"
    }
}
