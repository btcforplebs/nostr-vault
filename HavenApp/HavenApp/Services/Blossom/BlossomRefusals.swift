import Foundation

/// The HTTP codes mirrors answered for a blob's upload, so `MediaPostQueue`
/// can tell "every server refused this file" (stop retrying) from "no server
/// answered" (try again later). `uploadToServer` and the BUD-06 preflight
/// record; the queue clears before a try and takes the answers after it.
final class BlossomRefusals: @unchecked Sendable {
    static let shared = BlossomRefusals()

    private let lock = NSLock()
    private var statuses: [String: [String: Int]] = [:]
    /// The words a server gave with its no (BUD-01 `X-Reason`), by blob and server.
    private var reasons: [String: [String: String]] = [:]

    func record(sha256: String, server: String, status: Int, reason: String? = nil) {
        lock.lock()
        statuses[sha256, default: [:]][server] = status
        if let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
            reasons[sha256, default: [:]][server] = reason
        }
        lock.unlock()
    }

    func clear(sha256: String) {
        lock.lock()
        statuses[sha256] = nil
        reasons[sha256] = nil
        lock.unlock()
    }

    /// The reasons since the last `clear`, keyed by server, and forgets them.
    /// Read before `take`.
    func takeReasons(sha256: String) -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return reasons.removeValue(forKey: sha256) ?? [:]
    }

    /// The answers since the last `clear`, keyed by server, and forgets them.
    func take(sha256: String) -> [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        return statuses.removeValue(forKey: sha256) ?? [:]
    }
}
