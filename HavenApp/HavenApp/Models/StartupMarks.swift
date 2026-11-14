import Foundation
import Darwin

/// Startup timing marks: one "⏱ startup <step> +<ms>ms" line per step in
/// relay.log, counted from when the OS started the process. Go writes the
/// same shape (haven-go/startup_marks.go), so one pulled log shows the whole
/// cold start in milliseconds (Logen 2026-11-14: Vault rows < 0.5 s).
enum StartupMarks {
    static func line(_ step: String, ms: Int) -> String {
        "⏱ startup \(step) +\(ms)ms"
    }

    /// Milliseconds from process start to `now`, never negative.
    static func ms(since start: Date, now: Date = Date()) -> Int {
        max(0, Int((now.timeIntervalSince(start) * 1000).rounded()))
    }

    /// When the OS started this process; when the app first asked, if the
    /// kernel won't say.
    static let processStart: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return Date() }
        let tv = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
    }()
}

/// The relay's templates folder is copied out of the app bundle only when
/// the app changed (install or update), not on every launch.
enum TemplatesCopy {
    static let stampFile = ".templates-copied-from"

    /// Identifies one installed build: version, build number, and the
    /// executable's modification time (a rebuilt dev app keeps its numbers).
    static func stamp(version: String?, build: String?, executableModified: Date?) -> String {
        let when = executableModified.map { String(Int($0.timeIntervalSince1970)) } ?? "?"
        return "\(version ?? "?") (\(build ?? "?")) \(when)"
    }

    static func needsCopy(copiedStamp: String?, currentStamp: String, templatesPresent: Bool) -> Bool {
        !templatesPresent || copiedStamp?.trimmingCharacters(in: .whitespacesAndNewlines) != currentStamp
    }
}

/// Whether the launch's vault start runs right in the launch handler
/// (RelayProcessManager.startRelayAtLaunch) or waits on the lifecycle chain:
/// now only when nothing is queued before it, no earlier engine is still
/// draining, and no Mac relay needs a mesh dial first.
enum LaunchStart {
    static func startsNow(chainBusy: Bool, draining: Bool, meshDial: Bool) -> Bool {
        !chainBusy && !draining && !meshDial
    }
}
