import SwiftUI

extension FeedView {
    #if os(iOS)
    /// Opens the post a tapped notification parked, with no push animation:
    /// the app should come up already showing it.
    func openNotificationNote() {
        guard let open = NotificationOpen.pending else { return }
        NotificationOpen.pending = nil
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            switch open {
            case .note(let note):
                if let noteDetailSelection {
                    noteDetailSelection.select(note)
                } else {
                    navigationPath = NavigationPath([note])
                }
            case .id(let id):
                if let noteDetailSelection {
                    noteDetailSelection.select(id: id)
                } else {
                    var path = NavigationPath()
                    path.append(NotificationNoteRoute(id: id))
                    navigationPath = path
                }
            }
        }
    }

    @ViewBuilder
    var feedStack: some View {
        if noteDetailSelection != nil {
            // iPad two-pane layout: the enclosing NoteSplitPane owns the detail
            // column, so the feed must NOT wrap itself in a stack — a private
            // stack here would swallow selections and push over the list again.
            rootContent
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
                // The article reader is pushed onto the enclosing NoteSplitPane
                // stack in two-pane mode, so the destination has to be
                // registered on both branches.
                .navigationDestination(for: ArticleRoute.self) { route in
                    ArticleReaderView(note: route.note)
                }
        } else {
            NavigationStack(path: $navigationPath) {
                rootContent
                    .navigationTitle("")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(.hidden, for: .navigationBar)
                    .navigationDestination(for: FeedNote.self) { note in
                        NoteDetailView(note: note)
                    }
                    .navigationDestination(for: ArticleRoute.self) { route in
                        ArticleReaderView(note: route.note)
                    }
                    .navigationDestination(for: NotificationNoteRoute.self) { route in
                        NoteDetailViewWrapper(noteId: route.id, pushed: true)
                    }
            }
            .environment(\.pushNoteID, PushNoteAction(stack: "feed") { navigationPath.pushNote(id: $0) })
            // Over the stack, not in the feed: the navigation bar would
            // take its taps.
            .overlay(alignment: .top) { foldedNewPostsPill }
        }
    }
    #endif
}
