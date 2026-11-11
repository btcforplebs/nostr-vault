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
}
