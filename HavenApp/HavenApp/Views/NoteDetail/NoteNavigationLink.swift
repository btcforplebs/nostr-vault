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
