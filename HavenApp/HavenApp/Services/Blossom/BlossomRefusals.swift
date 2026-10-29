import Foundation

/// The HTTP codes mirrors answered for a blob's upload, so `MediaPostQueue`
/// can tell "every server refused this file" (stop retrying) from "no server
/// answered" (try again later). `uploadToServer` and the BUD-06 preflight
/// record; the queue clears before a try and takes the answers after it.
final class BlossomRefusals: @unchecked Sendable {
    static let shared = BlossomRefusals()

    private let lock = NSLock()
    private var statuses: [String: [String: Int]] = [:]

    func record(sha256: String, server: String, status: Int) {
        lock.lock()
        statuses[sha256, default: [:]][server] = status
        lock.unlock()
    }

    func clear(sha256: String) {
        lock.lock()
        statuses[sha256] = nil
        lock.unlock()
    }

    /// The answers since the last `clear`, keyed by server, and forgets them.
    func take(sha256: String) -> [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        return statuses.removeValue(forKey: sha256) ?? [:]
    }
}
