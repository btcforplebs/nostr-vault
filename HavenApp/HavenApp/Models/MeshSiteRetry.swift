import Foundation

/// How long a `.fips` page keeps asking a site that has not answered yet
/// (Logen 2026-11-14, routing audit). A route that is not warm yet needs the
/// engine's lookup (up to 15 s), then a session, then the door's SYN, which
/// the door gives up on after 20 s. So one request can be reset before the
/// route exists: the page asks again, through a fresh door, until `window`.
enum MeshSiteRetry {
    /// One request through the door: above the door's 20 s connect plus the
    /// 15 s lookup, so URLSession never gives up before the mesh does.
    static let requestTimeout: TimeInterval = 40
    /// How long one request keeps asking again after resets or timeouts.
    static let window: TimeInterval = 45
    /// The pause between those asks.
    static let pause: TimeInterval = 2

    /// Whether a request first sent at `startedAt` that came back with no
    /// byte at all is worth one more ask now.
    static func shouldRetry(startedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(startedAt) + pause < window
    }
}
