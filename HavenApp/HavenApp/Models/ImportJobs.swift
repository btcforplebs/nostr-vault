import Foundation

/// First run and the Vault's "Still to bring in" jobs (haven-go
/// import_jobs.go). The relay keeps serving while they run: `setup` is the
/// way in (own notes, follows, current lists, ~11 s); the long items run only
/// when the user taps Run (Logen, 2026-11-05).
/// Contract: PLANS/NV_FIRST_RUN_ENTRY_PLAN_2026_11_05.md, "Engine API".
///
/// Pure Foundation so MediaLogicTests can test it.
enum ImportJobs {
    static let setup = "setup"
    /// The Vault card's jobs, in the engine's order. `setup` is not one: it
    /// is the way in, and resumes by itself if it was cut.
    static let cardJobs = ["replies", "older_relays", "wider_network", "list_history"]

    /// The env key the relay reads on its first start (import_jobs.go
    /// firstRunEnv): keep to the follows web until the wider web is run.
    static let firstRunEnv = "HAVEN_FIRST_RUN"

    /// HAVEN_FIRST_RUN for one relay start. On while setup is the way in, and
    /// on for ANY start before setup is done: something else (the mesh copy,
    /// a background wake) can start the relay first, and a plain start then
    /// built the whole wider web (~4 min, 77k keys on the 12 mini, Ted
    /// 2026-11-05) before setup could even restart it.
    static func firstRunFlag(settingUp: Bool, setupDone: Bool) -> String {
        settingUp || !setupDone ? "1" : "0"
    }

    /// The vault is coming up, or going down to come straight back (a restart
    /// after setup or a settings change): say so instead of an empty vault
    /// (LogePad 2026-11-05, a 61 s restart right after Jump in).
    static func vaultStarting(booting: Bool, stopping: Bool, applyingConfig: Bool) -> Bool {
        booting || stopping || applyingConfig
    }

    static let startingLine = "Starting your vault…"

    /// RunImportJobC's answer.
    enum RunResult: Int32 {
        case started = 0, unknownJob = 1, busy = 2, relayNotRunning = 3
    }

    struct Range: Codable, Equatable {
        let relay: String
        let from: String
        let to: String
        let why: String
    }

    struct Job: Codable, Equatable, Identifiable {
        let name: String
        let status: String
        var startedAt: Int64?
        var endedAt: Int64?
        var reason: String?
        var stored: Int?
        var unread: [Range]?
        var estSeconds: Int?

        var id: String { name }

        enum CodingKeys: String, CodingKey {
            case name, status, reason, stored, unread
            case startedAt = "started_at"
            case endedAt = "ended_at"
            case estSeconds = "est_seconds"
        }
    }

    struct List: Codable, Equatable {
        var account: String?
        var startDate: String?
        /// The job running now, "" when none.
        var running: String?
        var jobs: [Job]

        enum CodingKeys: String, CodingKey {
            case account, running, jobs
            case startDate = "start_date"
        }

        func job(_ name: String) -> Job? { jobs.first { $0.name == name } }
    }

    /// ImportJobsC's JSON, or nil if it isn't that.
    static func parse(_ json: String) -> List? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(List.self, from: data)
    }

    /// One `IMPORT_JOB name=<job> status=<status> stored=<n> unread=<n>`
    /// log line. Keys it doesn't know are ignored.
    struct Line: Equatable {
        let name: String
        let status: String
        var stored: Int?
        var unread: Int?
    }

    static let lineMarker = "IMPORT_JOB "

    static func parseLine(_ line: String) -> Line? {
        guard let r = line.range(of: lineMarker) else { return nil }
        var fields: [String: String] = [:]
        for part in line[r.upperBound...].split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" }) {
            guard let eq = part.firstIndex(of: "=") else { continue }
            fields[String(part[..<eq])] = String(part[part.index(after: eq)...])
        }
        guard let name = fields["name"], !name.isEmpty, let status = fields["status"], !status.isEmpty else { return nil }
        return Line(name: name, status: status, stored: fields["stored"].flatMap(Int.init), unread: fields["unread"].flatMap(Int.init))
    }

    // MARK: First run

    /// Where setup's "Bringing in your notes" stands.
    enum SetupStage: Equatable {
        /// Waiting for the relay, or for setup to be taken.
        case starting
        case running
        /// done or partial: the user goes in. `unread` relays it could not
        /// finish are in older_relays now.
        case finished(partial: Bool)
        /// failed / cancelled, or setup could not be started: Try again.
        case couldNotFinish(reason: String?)
    }

    /// The setup job's stage from its status.
    static func setupStage(status: String?, reason: String?) -> SetupStage {
        switch status {
        case "done": return .finished(partial: false)
        case "partial": return .finished(partial: true)
        case "failed", "cancelled": return .couldNotFinish(reason: reason)
        case "running": return .running
        default: return .starting
        }
    }

    /// Plain words for a setup that ended without letting the user in.
    static func couldNotFinishText(reason: String?) -> String {
        switch reason {
        case "no_relay", "relays_unreachable":
            return "Couldn't reach any relay. Check your connection and try again."
        case "could_not_start", "unknown_job":
            return "Couldn't start bringing in your notes. Try again."
        case nil, "", "ok":
            return "Bringing in your notes stopped. Try again."
        default:
            return "Bringing in your notes stopped (\(reason!)). Try again."
        }
    }

    /// Whether a run left `relay` unread (the other vault on a copy).
    static func leftUnread(_ relay: String, in job: Job?) -> Bool {
        let want = host(relay)
        return (job?.unread ?? []).contains { host($0.relay) == want }
    }

    // MARK: Vault card

    static func title(_ name: String) -> String {
        switch name {
        case "replies": return "Replies and mentions"
        case "older_relays": return "Older and slower relays"
        case "wider_network": return "Your wider network"
        case "list_history": return "Old versions of your lists"
        case "setup": return "Your notes"
        default: return name
        }
    }

    static func blurb(_ name: String) -> String {
        switch name {
        case "replies": return "Replies, mentions and zaps to you."
        case "older_relays": return "The relays setup couldn't finish, read further back."
        case "wider_network": return "Follows of follows, for the globe and Global."
        case "list_history": return "For Recover a List."
        default: return ""
        }
    }

    /// "About 3 min", "About 45 s".
    static func estimate(_ seconds: Int?) -> String? {
        guard let s = seconds, s > 0 else { return nil }
        if s < 60 { return "About \(s) s" }
        let m = Double(s) / 60
        let text = m.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(m)) : String(format: "%.1f", m)
        return "About \(text) min"
    }

    /// The row's status line: what it is, how it went, when it last ran.
    static func statusText(_ job: Job, runningNow: Bool, now: Date = Date()) -> String {
        let last = job.endedAt.map { "Last ran \(relative(Date(timeIntervalSince1970: TimeInterval($0)), now: now))." } ?? ""
        let stored = job.stored.map { $0 > 0 ? " \($0.formatted()) saved." : "" } ?? ""
        switch job.status {
        case "running":
            if !runningNow && job.reason == "will_resume" { return "Cut short. Picks up when the vault starts again." }
            return "Bringing it in…" + stored
        case "done": return ("Done." + stored + " " + last).trimmingCharacters(in: .whitespaces)
        case "partial": return ("Not everything was read." + stored + " " + last).trimmingCharacters(in: .whitespaces)
        case "failed": return ("Didn't finish" + (job.reason.map { " (\($0))" } ?? "") + ". " + last).trimmingCharacters(in: .whitespaces)
        case "cancelled": return ("Cancelled." + stored + " " + last).trimmingCharacters(in: .whitespaces)
        default:
            let est = estimate(job.estSeconds).map { " \($0)." } ?? ""
            return "Not run yet." + est
        }
    }

    /// The ranges a run could not read, one line each: "nostr.wine:
    /// 2023-01-01 to 2026-11-05, didn't answer".
    static func unreadLines(_ job: Job) -> [String] {
        (job.unread ?? []).map { r in
            "\(label(r.relay)): \(r.from) to \(r.to), \(whyText(r.why))"
        }
    }

    static func whyText(_ why: String) -> String {
        switch why {
        case "unreachable": return "couldn't connect"
        case "silent": return "didn't answer"
        case "stopped_partway": return "stopped partway"
        case "slow": return "too slow"
        case "deadline": return "ran out of time"
        case "cut": return "cut short"
        case "not_read_yet": return "not read yet"
        default: return why.replacingOccurrences(of: "_", with: " ")
        }
    }

    /// A relay as the card names it. The other vault is read through a
    /// local link whose path is its token: never shown.
    static func label(_ relay: String) -> String {
        let h = host(relay)
        if h.hasPrefix("127.0.0.1") || h.hasPrefix("localhost") || h.hasPrefix("[::1]") { return "Your other vault" }
        return h
    }

    static func host(_ relay: String) -> String {
        var s = relay
        for p in ["wss://", "ws://", "https://", "http://"] where s.hasPrefix(p) { s.removeFirst(p.count) }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// Run on a job not running; "Run again" once it has run.
    static func runTitle(_ job: Job) -> String {
        job.status == "never" ? "Run" : "Run again"
    }

    private static func relative(_ date: Date, now: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: now)
    }
}
