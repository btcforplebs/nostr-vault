import Foundation

/// What one failed profile-picture download says about its link.
///
/// The avatar cache used to treat every failure the same way: return nil and
/// forget it, so each reopen of the WoT tab fetched the same dead pictures
/// again (on one phone, 27 × 500 and 13 × 404 from the resizing service).
enum AvatarFetchFailure: Equatable {
    /// 404 or 410: the picture is gone. Recorded as known-dead.
    case dead
    /// The server failed or didn't answer in time, or sent something that
    /// isn't a picture. It may work later, so wait a while before asking again.
    case backOff
    /// The device itself is offline. Says nothing about the link; ask again
    /// as soon as anything wants the picture.
    case retry

    /// `statusCode` is the final HTTP status (after redirects), nil when there
    /// was no HTTP response. `error` is the transport error, if any.
    ///
    /// `AvatarThumbnail` asks the resizing service with `default=<original>`,
    /// so when the original is gone the service redirects to it and the final
    /// status is the original's own 404. A 404 from the service itself lands
    /// here the same way.
    init(statusCode: Int?, error: URLError.Code?) {
        if let statusCode {
            self = (statusCode == 404 || statusCode == 410) ? .dead : .backOff
            return
        }
        switch error {
        case .notConnectedToInternet?, .networkConnectionLost?, .dataNotAllowed?,
             .internationalRoamingOff?, .callIsActive?, .cancelled?:
            self = .retry
        default:
            // Timeouts, unknown or unreachable hosts, TLS failures.
            self = .backOff
        }
    }
}

/// In-memory cool-down for links that failed in a way that may not last.
/// Never persisted: a relaunch asks again.
final class AvatarRetryBackoff {
    static let interval: TimeInterval = 10 * 60
    private static let pruneThreshold = 1_000

    private var until: [String: Date] = [:]
    private let lock = NSLock()
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    func isBackingOff(_ url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let key = url.absoluteString
        guard let end = until[key] else { return false }
        if end > now() { return true }
        until.removeValue(forKey: key)
        return false
    }

    func backOff(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        let current = now()
        until[url.absoluteString] = current.addingTimeInterval(Self.interval)
        if until.count > Self.pruneThreshold {
            until = until.filter { $0.value > current }
        }
    }

    func clear(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        until.removeValue(forKey: url.absoluteString)
    }
}
