import Foundation

/// Remembers the last web it built (`TrustMap.web`). `feedTrustedPubkeys`
/// is read on every feed recompute and every Global check, and each read
/// built a fresh union of a graph of thousands (Mac sweep 11-01 #3). An
/// unchanged graph and follow list compare by identity, so a repeat read
/// costs nothing. Safe from any thread.
final class TrustedWebMemo: @unchecked Sendable {
    private let lock = NSLock()
    private var last: (saved: Set<String>, follows: [String], web: Set<String>)?

    func web(saved: Set<String>, follows: [String]) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        if let last, last.saved == saved, last.follows == follows { return last.web }
        let web = TrustMap.web(saved: saved, follows: Set(follows))
        last = (saved, follows, web)
        return web
    }
}
