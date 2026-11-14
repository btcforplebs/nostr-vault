import Foundation

extension RelayProcessManager {
    /// Writes one startup timing mark to relay.log (StartupMarks). Before
    /// the relay's stdout is captured, straight to the file; after, through
    /// stdout (unbuffered), so it never writes past the capture's own file
    /// handle.
    func startupMark(_ step: String) {
        let line = StartupMarks.line(step, ms: StartupMarks.ms(since: StartupMarks.processStart))
        if outputPipe != nil {
            // Not print(): stdout into a pipe is block-buffered, so a mark
            // would sit unwritten until the buffer filled.
            FileHandle.standardOutput.write(Data((line + "\n").utf8))
        } else {
            appendLaunchLine(line, in: ConfigService.shared.relayDataDir)
        }
    }

    /// A mark from any thread, once the relay's stdout is captured (a store
    /// read runs only then): the main thread may be busy drawing, and a hop
    /// there would add its wait to the mark.
    nonisolated static func startupMarkOffMain(_ step: String) {
        let line = StartupMarks.line(step, ms: StartupMarks.ms(since: StartupMarks.processStart))
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    /// Copies the relay's templates out of the bundle when this build has
    /// not copied them yet (TemplatesCopy).
    func copyTemplatesIfChanged(to relayDataDir: URL) {
        let destURL = relayDataDir.appendingPathComponent("templates")
        let stampURL = relayDataDir.appendingPathComponent(TemplatesCopy.stampFile)
        let info = Bundle.main.infoDictionary
        let executableModified = Bundle.main.executableURL.flatMap {
            (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date
        }
        let stamp = TemplatesCopy.stamp(version: info?["CFBundleShortVersionString"] as? String,
                                        build: info?["CFBundleVersion"] as? String,
                                        executableModified: executableModified)
        guard TemplatesCopy.needsCopy(copiedStamp: try? String(contentsOf: stampURL, encoding: .utf8),
                                      currentStamp: stamp,
                                      templatesPresent: FileManager.default.fileExists(atPath: destURL.path)) else {
            return
        }
        guard let templatesPath = Bundle.main.path(forResource: "templates", ofType: "") else {
            logStore.append(LogEntry(timestamp: Date(), level: "WARN", message: "Templates folder not found in Bundle"))
            return
        }
        if FileManager.default.fileExists(atPath: destURL.path) {
            try? FileManager.default.removeItem(at: destURL)
        }
        do {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: templatesPath), to: destURL)
            try? stamp.write(to: stampURL, atomically: true, encoding: .utf8)
            logStore.append(LogEntry(timestamp: Date(), level: "INFO", message: "Copied templates to \(destURL.path)"))
        } catch {
            // No stamp: the next start tries again.
            logStore.append(LogEntry(timestamp: Date(), level: "WARN", message: "Templates copy failed: \(error.localizedDescription)"))
        }
    }
}
