import SwiftUI

/// Vault > Bookmarks: the active account's kind 10003, newest first. Notes
/// and articles bookmarked in any app; the private ones (encrypted in the
/// list) are shown read-only. Bookmark sets (30003) are not in v1.
/// Twin of Android `BookmarksScreen.kt`.
struct BookmarksView: View {
    @ObservedObject private var bookmarks = BookmarkService.shared
    @ObservedObject private var configService = ConfigService.shared
    @EnvironmentObject var nostrService: NostrService

    @State private var privateEntries: [BookmarkList.Entry] = []
    @State private var events: [BookmarkList.Entry: NostrEvent] = [:]
    @State private var loading = true
    @State private var reading: ArticleRoute?

    var body: some View {
        List {
            if loading && events.isEmpty {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading your bookmarks…").foregroundColor(.secondary) }
            } else if bookmarks.publicEntries.isEmpty && privateEntries.isEmpty {
                Text("No bookmarks yet. Use Bookmark in a note's ••• menu to keep it here.")
                    .foregroundColor(.secondary)
            }
            if !bookmarks.publicEntries.isEmpty {
                Section("Bookmarks") {
                    ForEach(bookmarks.publicEntries, id: \.self) { entry in
                        row(entry, removable: true)
                    }
                }
            }
            if !privateEntries.isEmpty {
                Section {
                    ForEach(privateEntries, id: \.self) { entry in
                        row(entry, removable: false)
                    }
                } header: {
                    Text("Private bookmarks")
                } footer: {
                    Text("Only you can see these. They are shown here as they are; change them in the app that made them.")
                }
            }
        }
        .navigationTitle("Bookmarks")
        .refreshable { await load(force: true) }
        .task(id: configService.config.activeAccountNpub) { await load(force: true) }
        .onChange(of: bookmarks.list?.id) { _, _ in Task { await loadEvents() } }
        .sheet(item: $reading) { route in
            NavigationStack { ArticleReaderView(note: route.note) }
                .environmentObject(nostrService)
                .environmentObject(configService)
        }
    }

    @ViewBuilder
    private func row(_ entry: BookmarkList.Entry, removable: Bool) -> some View {
        Group {
            if let event = events[entry] {
                let note = event.asFeedNote
                if entry.coordinate != nil {
                    ArticleCardView(note: note, profile: nostrService.profiles[note.pubkey])
                        .contentShape(Rectangle())
                        .onTapGesture { reading = ArticleRoute(note: note) }
                } else {
                    QuotedNoteView(note: note)
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(loading ? "Loading…" : "Not found on your relays")
                        .foregroundColor(.secondary)
                    Text(label(entry)).font(.appCaption).foregroundColor(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .contextMenu {
            if removable, configService.activeAccountCanSign, let event = events[entry] {
                Button(role: .destructive) { bookmarks.toggle(event.asFeedNote) } label: {
                    Label("Remove Bookmark", systemImage: "bookmark.slash")
                }
            }
        }
    }

    private func label(_ entry: BookmarkList.Entry) -> String {
        switch entry {
        case .event(let id): return id
        case .address(let coordinate): return coordinate
        }
    }

    private func load(force: Bool) async {
        loading = true
        await bookmarks.refresh(force: force)
        privateEntries = await bookmarks.privateEntries()
        await loadEvents()
    }

    private func loadEvents() async {
        loading = true
        let wanted = bookmarks.publicEntries + privateEntries
        let found = await bookmarks.events(for: wanted.filter { events[$0] == nil })
        events.merge(found) { held, new in held.created_at >= new.created_at ? held : new }
        nostrService.fetchMissingProfiles(for: Array(Set(found.values.map(\.pubkey))))
        loading = false
    }
}
