import SwiftUI

// MARK: - Note Navigation Link

/// Opens a note the right way for the layout it finds itself in: a
/// `NavigationLink` push inside a plain navigation stack, or a selection into
/// the detail pane when the iPad two-pane layout supplies one.
///
/// Drop-in replacement for `NavigationLink(value: someFeedNote)`.
struct NoteNavigationLink<Label: View>: View {
    let note: FeedNote
    @ViewBuilder var label: () -> Label

    @Environment(\.noteDetailSelection) private var selection

    var body: some View {
        if let selection {
            // A tap gesture, NOT a Button. Note rows embed their own Buttons for
            // reply/repost/like/zap, and on iOS a Button nested inside another
            // Button never receives the tap -- the outer one swallows it, so
            // every action in the row dies. NavigationLink does not have that
            // problem, which is why the push path can stay a link. This mirrors
            // what the macOS branch of FeedView already does for the same reason.
            label()
                .contentShape(Rectangle())
                .onTapGesture {
                    selection.select(note)
                }
        } else {
            NavigationLink(value: note) {
                label()
            }
            .buttonStyle(.plain)
        }
    }
}

/// Pushes a note named only by id (hex, `note1`, `nevent1`, `naddr1`) onto
/// the enclosing stack, as a thread view the user swipes back from. Set on
/// the stacks that register `NotificationNoteRoute`; nil everywhere else,
/// where callers keep their sheet.
///
/// Equal by `stack` alone: the closure only appends to that stack's path, so
/// a fresh closure on each redraw must not redraw every row reading it.
struct PushNoteAction: Equatable {
    let stack: String
    let push: (String) -> Void

    func callAsFunction(_ id: String) { push(id) }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.stack == rhs.stack }
}

extension EnvironmentValues {
    @Entry var pushNoteID: PushNoteAction? = nil
}

/// One push per tap: a double tap, or a link and its row both answering,
/// would otherwise stack the same thread twice.
@MainActor
enum NotePushGuard {
    private static var last: (id: String, at: Date)?

    static func allows(_ id: String, now: Date = Date()) -> Bool {
        if let last, last.id == id, now.timeIntervalSince(last.at) < 0.8 { return false }
        last = (id, now)
        return true
    }
}

extension NavigationPath {
    /// Pushes the thread view for a note id, once per tap.
    @MainActor mutating func pushNote(id: String) {
        guard NotePushGuard.allows(id) else { return }
        append(NotificationNoteRoute(id: id))
    }

    /// Pushes the thread view for a note, once per tap.
    @MainActor mutating func pushNote(_ note: FeedNote) {
        guard NotePushGuard.allows(note.id) else { return }
        append(note)
    }
}
