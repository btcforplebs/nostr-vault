import Foundation

/// Runs `TempFileSweep` once per launch, off the main thread, and logs what
/// it freed. Every launch, so a phone that already filled `tmp/` is cleared
/// on its first launch after the update.
enum LaunchTempSweep {
    static func run() {
        let tmp = FileManager.default.temporaryDirectory
        var maxAge = TempFileSweep.maxAge
        #if DEBUG
        // Simulator checks only: file status-change times can't be set back,
        // so seeded junk is made "old" by shortening the limit instead.
        if let s = ProcessInfo.processInfo.environment["NV_TEMP_SWEEP_MAX_AGE"], let v = TimeInterval(s) { maxAge = v }
        #endif
        DispatchQueue.global(qos: .utility).async {
            let r = TempFileSweep.sweep(directory: tmp, maxAge: maxAge)
            guard r.removed > 0 else { return }
            let freed = ByteCountFormatter.string(fromByteCount: r.removedBytes, countStyle: .file)
            RelayProcessManager.shared.addLog("Storage: removed \(r.removed) leftover temp files (\(freed)); kept \(r.kept) in use or new", level: "INFO")
        }
    }
}
