import Foundation
@preconcurrency import Dispatch
import Combine
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

extension RelayProcessManager {
    /// Appends one line to relay.log, the file pulled off a device, and to
    /// Settings > Logs. For lines from before the relay starts: until
    /// captureOutput redirects stdout, a `print` reaches neither.
    func appendLaunchLine(_ line: String, in directory: URL) {
        addLog(line)
        let url = directory.appendingPathComponent("relay.log")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(Data("\(ISO8601DateFormatter().string(from: Date())) \(line)\n".utf8))
    }

    /// Redirection mechanism for capturing stdout and stderr from C-Shared bindings
    func captureOutput(in directory: URL) {
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
    func restoreOutput() {
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
                // Relay is up; WoT may still be building, unless the inbox
                // subscription (which waits on WoT) already started.
                isWotSyncing = !inboxSubscribed
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
            inboxSubscribed = true
            isWotSyncing = false
            bootStatusMessage = ""
        }

        // Metrics
        if batch.eventsStoredDelta != 0 {
            eventsStored += batch.eventsStoredDelta
        }
        // Red dot reflects only inbound activity from OTHERS (events tagging you /
        // DMs) — never your own posts, blasts, or private/outbox writes.
        let zapsOnly = ConfigService.shared.config.zapsOnlyMode
        let landed = Set(batch.inboxActivityKinds.compactMap(VaultMode.listing(inboxKind:)))
            .filter { !(zapsOnly && $0 == .likes) } // no Likes list to open
        if !landed.isSubset(of: newActivityModes) {
            newActivityModes.formUnion(landed)
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
        // Both platforms: there is no push server, so on macOS too these markers
        // are the only source of mention, reply, zap and DM notifications.
        for marker in batch.notifyMarkers {
            LocalNotificationService.shared.handle(marker)
        }
        // Each account's count in the account switcher.
        if !batch.notifyMarkers.isEmpty {
            AccountUnreadStore.shared.record(markers: batch.notifyMarkers, rules: .vaultList())
        }
    }

    func startLogThrottler() {
        logStore.startThrottler()
    }

    func stopLogThrottler() {
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
}
