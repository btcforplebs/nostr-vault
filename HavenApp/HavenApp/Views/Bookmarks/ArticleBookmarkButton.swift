import SwiftUI

/// Bookmark in the article reader's action row (articles have no ••• menu).
/// Same tap as BookmarkMenuItem: one `a` entry on the account's kind 10003.
struct ArticleBookmarkButton: View {
    let note: FeedNote
    @ObservedObject private var bookmarks = BookmarkService.shared
    @ObservedObject private var configService = ConfigService.shared

    var body: some View {
        if configService.activeAccountCanSign {
            let marked = bookmarks.isBookmarked(note)
            Button { bookmarks.toggle(note) } label: {
                Image(systemName: marked ? "bookmark.fill" : "bookmark")
                    .font(.appSystem(size: 15, weight: .medium))
                    .foregroundColor(marked ? .havenPurple : .secondary)
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(bookmarks.saving.contains(bookmarks.entry(for: note)))
            .accessibilityLabel(marked ? "Remove Bookmark" : "Bookmark")
            .help(marked ? "Remove Bookmark" : "Bookmark")
            .task { await bookmarks.refresh() }
        }
    }
}
