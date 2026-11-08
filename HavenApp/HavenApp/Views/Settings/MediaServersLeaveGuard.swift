import SwiftUI

/// Lets whatever shows Settings › Media Servers ask before leaving it with
/// unsaved changes: the back button, a sheet's Done, or a Settings sidebar
/// row (Mac, iPad). `BlossomSettingsView` keeps `hasChanges` current and
/// answers `pendingLeave` with Save / Discard / Keep Editing.
@MainActor
final class MediaServersLeaveGuard: ObservableObject {
    static let shared = MediaServersLeaveGuard()

    /// The page is on screen with changes not yet saved.
    @Published var hasChanges = false
    /// A leave waiting on the user's answer.
    @Published private(set) var pendingLeave: (() -> Void)?

    /// Leaves at once when nothing is unsaved; otherwise asks first.
    func requestLeave(_ leave: @escaping () -> Void) {
        if hasChanges { pendingLeave = leave } else { leave() }
    }

    /// Saved or discarded: go where the user was going.
    func proceed() {
        let leave = pendingLeave
        pendingLeave = nil
        hasChanges = false
        leave?()
    }

    func cancel() { pendingLeave = nil }
}
