import Foundation

/// The mesh vault copy, v2 (docs/MESH_COPY_V2_CONTRACT.md): B copies A's
/// vault as the backup zip over the mesh, then catches up on every reconnect.
/// The engine does the transfer, restore and relays; the app signs the start,
/// reads the `COPY` lines and shows them. Pure Foundation so MediaLogicTests
/// checks it against the contract's fixtures (docs/fixtures/mesh-copy/).
enum MeshCopyV2 {
    // MARK: Progress lines (contract §3.3, progress-v2-lines.json)

    struct Progress: Equatable {
        var stage: String
        var part: String
        var bytes: (done: Int64, total: Int64)
        var items: (done: Int, total: Int)
        var source: String
        /// "" unless the line names one.
        var error: String

        static func == (a: Progress, b: Progress) -> Bool {
            a.stage == b.stage && a.part == b.part && a.bytes == b.bytes && a.items == b.items
                && a.source == b.source && a.error == b.error
        }

        var isFinished: Bool { stage == "done" || stage == "failed" }

        /// 0...1 for a bar, or nil when the stage has no byte count.
        var fraction: Double? {
            guard bytes.total > 0 else { return nil }
            return min(1, Double(bytes.done) / Double(bytes.total))
        }
    }

    static let stages: Set<String> = ["building", "fetching", "restoring", "relays", "done", "failed"]
    static let parts: Set<String> = ["notes", "media", "-"]
    static let sources: Set<String> = ["mesh", "relays"]
    static let lineMarker = "COPY "

    /// One `COPY` line, anywhere in a log line (a timestamp may lead it).
    /// The first five keys must come in the contract's order; later keys
    /// other than `error` are ignored.
    static func parseLine(_ line: String) -> Progress? {
        guard let r = line.range(of: lineMarker) else { return nil }
        if r.lowerBound != line.startIndex, !line[line.index(before: r.lowerBound)].isWhitespace { return nil }
        let tokens = line[r.upperBound...].split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" })
        var pairs: [(String, String)] = []
        for t in tokens {
            guard let eq = t.firstIndex(of: "=") else { continue }
            pairs.append((String(t[..<eq]), String(t[t.index(after: eq)...])))
        }
        let order = ["stage", "part", "bytes", "items", "source"]
        guard pairs.count >= order.count, zip(pairs, order).allSatisfy({ $0.0.0 == $0.1 }) else { return nil }
        let v = pairs.prefix(order.count).map(\.1)
        guard stages.contains(v[0]), parts.contains(v[1]), sources.contains(v[4]),
              let bytes = fraction(v[2]), let items = fraction(v[3]) else { return nil }
        let error = pairs.dropFirst(order.count).first(where: { $0.0 == "error" })?.1 ?? ""
        return Progress(stage: v[0], part: v[1], bytes: (bytes.0, bytes.1),
                        items: (Int(items.0), Int(items.1)), source: v[4], error: error)
    }

    private static func fraction(_ s: String) -> (Int64, Int64)? {
        let p = s.split(separator: "/", omittingEmptySubsequences: false)
        guard p.count == 2, let a = Int64(p[0]), let b = Int64(p[1]), a >= 0, b >= 0 else { return nil }
        return (a, b)
    }

    // MARK: Errors (contract §7, errors-v2.json)

    /// What B does for an error code.
    enum Action: String {
        case stop, restart, wait, refetch, relays, `continue`
        case restartNextReconnect = "restart_next_reconnect"
        case resumeNextReconnect = "resume_next_reconnect"
        case keepState = "keep_state"
    }

    struct ErrorInfo: Equatable {
        let code: String
        let action: Action
        /// What the screen says; "" for an error B handles by itself.
        /// `{name}`, `{need}` and `{free}` are filled by `message`.
        let line: String
    }

    static let errors: [ErrorInfo] = [
        .init(code: "auth_refused", action: .stop, line: "Couldn't sign in to {name}"),
        .init(code: "not_owner", action: .stop, line: "{name} belongs to another account"),
        .init(code: "not_found", action: .restart, line: ""),
        .init(code: "building", action: .wait, line: ""),
        .init(code: "range", action: .refetch, line: ""),
        .init(code: "no_space", action: .relays, line: "{name} is short of space; copying from your relays instead"),
        .init(code: "needs_space", action: .stop, line: "Needs {need} free, this device has {free}"),
        .init(code: "wrong_owner", action: .stop, line: "{name} belongs to another account"),
        .init(code: "unsupported_version", action: .stop, line: "Update this app to copy from {name}"),
        .init(code: "bad_manifest", action: .stop, line: "{name} sent a copy this app can't read"),
        .init(code: "hash_mismatch", action: .restartNextReconnect,
              line: "The copy from {name} arrived damaged; it starts over next time"),
        .init(code: "unreachable", action: .resumeNextReconnect, line: "Waiting for {name}"),
        .init(code: "nothing_restored", action: .stop, line: "Nothing in the copy could be restored"),
        .init(code: "settings_refused", action: .continue,
              line: "Settings weren't copied: they held something that must stay on {name}"),
        .init(code: "cancelled", action: .keepState, line: "Copy stopped"),
    ]

    static func error(_ code: String) -> ErrorInfo? { errors.first { $0.code == code } }

    /// The plain line for a finished copy's error, or nil when there is none
    /// to show. An unknown code still says something rather than "Done".
    static func message(for progress: Progress, name: String) -> String? {
        guard !progress.error.isEmpty else { return nil }
        let who = displayName(name)
        guard let info = error(progress.error) else { return "The copy from \(who) stopped" }
        guard !info.line.isEmpty else { return nil }
        var text = info.line.replacingOccurrences(of: "{name}", with: who)
        if info.code == "needs_space" {
            // B's engine puts the numbers on that line: bytes=<free>/<need>.
            text = text.replacingOccurrences(of: "{need}", with: gigabytes(progress.bytes.total))
                .replacingOccurrences(of: "{free}", with: gigabytes(progress.bytes.done))
        }
        return text
    }

    static func displayName(_ name: String) -> String {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "your other device" : t
    }

    /// "2.4 GB": one decimal under 10 GB, whole above.
    static func gigabytes(_ bytes: Int64) -> String {
        let gb = Double(max(0, bytes)) / 1_000_000_000
        return gb >= 10 ? "\(Int(gb.rounded())) GB" : String(format: "%.1f GB", gb)
    }

    /// The screen's line for a running stage.
    static func stageLine(_ p: Progress, name: String) -> String {
        let who = displayName(name)
        switch p.stage {
        case "building": return "\(who) is getting your vault ready…"
        case "fetching": return p.part == "media" ? "Copying your photos and videos from \(who)…" : "Copying your notes from \(who)…"
        case "restoring": return p.part == "media" ? "Saving your photos and videos…" : "Saving your notes…"
        case "relays": return "Getting anything else from your relays…"
        case "failed": return message(for: p, name: name) ?? "The copy from \(who) stopped"
        default: return "Copied from \(who)"
        }
    }

    // MARK: Start (contract §2)

    /// The NIP-98 `u` for the start: scheme, host and port of the mesh base
    /// with the fixed path. The base's own path (its ingress token) is never
    /// signed: A checks only the path, and the token must not leave B.
    static func startURL(base: URL) -> String? {
        guard let scheme = base.scheme, let host = base.host, !host.isEmpty else { return nil }
        let port = base.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)/copy/v2/start"
    }

    static func startAuthTags(base: URL) -> [[String]]? {
        guard let u = startURL(base: base) else { return nil }
        return [["u", u], ["method", "POST"]]
    }

    /// StartCopyFromC / CopySyncC: 0 started, 2 busy, 3 relay not running.
    enum StartResult: Equatable {
        case started, busy, relayNotRunning, failed(Int32)
        init(code: Int32) {
            switch code {
            case 0: self = .started
            case 2: self = .busy
            case 3: self = .relayNotRunning
            default: self = .failed(code)
            }
        }

        /// A copy is running (this one, or one already under way).
        var isRunning: Bool { self == .started || self == .busy }
    }
}
