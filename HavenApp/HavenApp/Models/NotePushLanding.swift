import Foundation

/// Watches one note push onto a navigation stack. If the pushed screen
/// never appears, the push missed: SwiftUI found no destination for the
/// value, so a link could not activate or the path drew its bare yellow
/// placeholder. The caller then opens the note another way (a sheet).
/// SwiftUI gives no failure callback, so the check is "did it land in time".
struct NotePushLanding: Equatable {
    /// How long a pushed screen has to appear. A push starts its screen at
    /// once; this is the slack for a busy main thread.
    static let window: Duration = .milliseconds(600)

    private(set) var pending: String?

    /// A push for `id` went onto the path.
    mutating func began(_ id: String) { pending = id }

    /// The pushed screen for `id` appeared.
    mutating func landed(_ id: String) {
        if pending == id { pending = nil }
    }

    /// After `window`: true, once, when the push for `id` never landed.
    mutating func missed(_ id: String) -> Bool {
        guard pending == id else { return false }
        pending = nil
        return true
    }
}
