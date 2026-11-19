import Foundation

/// Whether a chat screen is still showing, for a send that finishes after
/// it closed (B5): its `@State` is gone by then, so the failure goes to
/// DMDrafts and a pill instead. A class so the send's Task sees the change.
@MainActor
final class DMThreadPresence {
    var isOnScreen = false
}
