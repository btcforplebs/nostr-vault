import SwiftUI

/// Bookmark in the article reader's action row (articles have no ••• menu).
/// Same tap as BookmarkMenuItem: one `a` entry on the account's kind 10003.
struct ArticleBookmarkButton: View {
    let note: FeedNote
    @ObservedObject private var bookmarks = BookmarkService.shared
    @ObservedObject private var configService = ConfigService.shared

    var body: some View {
        if configService.activeAccountCanSign {
            let state = bookmarks.menuState(note)
            let marked = state != .add
            Button { bookmarks.toggle(note) } label: {
                Image(systemName: marked ? "bookmark.fill" : "bookmark")
                    .font(.appSystem(size: 15, weight: .medium))
                    .foregroundColor(marked ? .havenPurple : .secondary)
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(state == .privately || bookmarks.saving.contains(bookmarks.entry(for: note)))
            .accessibilityLabel(state == .privately ? "Bookmarked privately" : marked ? "Remove Bookmark" : "Bookmark")
            .help(state == .privately ? "Bookmarked privately" : marked ? "Remove Bookmark" : "Bookmark")
            .task { await bookmarks.refresh() }
        }
    }
}
