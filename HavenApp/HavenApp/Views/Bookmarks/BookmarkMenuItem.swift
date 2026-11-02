import SwiftUI

/// "Bookmark" / "Remove Bookmark" in a note's or article's ••• menu. Adds or
/// removes this one entry on the account's kind 10003 (BookmarkService).
/// Not shown to a read-only sign-in, which can't sign the list.
struct BookmarkMenuItem: View {
    let note: FeedNote
    @ObservedObject private var bookmarks = BookmarkService.shared
    @ObservedObject private var configService = ConfigService.shared

    var body: some View {
        if configService.activeAccountCanSign {
            let marked = bookmarks.isBookmarked(note)
            Button {
                bookmarks.toggle(note)
            } label: {
                Label(marked ? "Remove Bookmark" : "Bookmark", systemImage: marked ? "bookmark.slash" : "bookmark")
            }
            .disabled(bookmarks.saving.contains(bookmarks.entry(for: note)))
            .task { await bookmarks.refresh() }
        }
    }
}
