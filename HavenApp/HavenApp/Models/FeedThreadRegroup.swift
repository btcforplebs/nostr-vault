import Foundation

/// Grouping the threaded feed off the main thread.
enum FeedThreadRegroup {
    /// Runs `group` on a background task, then `apply` on the main actor only
    /// if `isCurrent()` still holds, so a grouping a newer one overtook is
    /// dropped rather than applied over it.
    @discardableResult
    static func offMain<T>(_ group: @escaping () -> T,
                           isCurrent: @escaping @MainActor () -> Bool,
                           apply: @escaping @MainActor (T) -> Void) -> Task<Void, Never> {
        Task.detached(priority: .userInitiated) {
            let built = group()
            await MainActor.run {
                guard isCurrent() else { return }
                apply(built)
            }
        }
    }

    /// Whether a finished grouping is shown. The current one always is. While
    /// the feed shows nothing, any newer one is too: notes streaming in faster
    /// than one grouping takes would otherwise overtake every result, and the
    /// feed would stay blank for the whole fill. `floor` is the first
    /// generation of the feed on screen, so a grouping of the feed just left
    /// never lands on the new one. A result older than one already shown is
    /// dropped.
    static func shouldApply(generation: Int, current: Int, floor: Int,
                            lastApplied: Int, showingNothing: Bool) -> Bool {
        guard generation >= floor, generation > lastApplied else { return false }
        return generation == current || showingNothing
    }
}
