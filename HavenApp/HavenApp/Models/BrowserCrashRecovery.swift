import Foundation

/// What the in-app browser does when WebKit's page process dies (memory, a crash in the page): the web view goes
/// blank and nothing tells the app. The first time it reloads by itself; a page that dies again within `window`
/// of that reload is left on "Try Again", so a page that keeps crashing can't loop.
struct BrowserCrashRecovery: Equatable {
    enum Action: Equatable { case reload, askToReload }

    static let window: TimeInterval = 30
    static let message = "This page stopped working. Tap Try Again to reload it."

    private(set) var lastAutoReload: Date?

    mutating func processDied(at now: Date) -> Action {
        if let last = lastAutoReload, now.timeIntervalSince(last) < Self.window { return .askToReload }
        lastAutoReload = now
        return .reload
    }

    /// The reader opened a page or tapped Try Again: the next death gets its one automatic reload again.
    mutating func readerActed() { lastAutoReload = nil }
}
