import Foundation

/// The Feed never moves the reader on its own (Logen 2026-11-04): a load
/// that ends while they are scrolled down leaves them there, and with
/// Auto-load on, new posts go in above while they stay on the post they were
/// reading. Only at the top does the feed jump or simply grow upward.
enum FeedStayPut {
    /// A finished load (refresh, feed switch, cold start) goes back to the top
    /// only when the reader is still there.
    static func scrollsToTopAfterLoad(isAtTop: Bool) -> Bool { isAtTop }

    /// Whether waiting posts go in by themselves now: Auto-load on, some
    /// waiting, no load running, no tapped post open (posts added above would
    /// push it off its landing line). Where the reader is no longer matters.
    static func autoLoads(enabled: Bool, waiting: Int, isLoading: Bool, postOpen: Bool) -> Bool {
        enabled && waiting > 0 && !isLoading && !postOpen
    }

    /// Below the top, the post being read is kept on screen when posts go in above it.
    static func keepsReading(isAtTop: Bool) -> Bool { !isAtTop }
}
