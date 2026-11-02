import Foundation

/// The active account's bookmarks (kind 10003): whether a note is one, the
/// tap that adds or removes it, and what the Bookmarks page lists. Reads the
/// newest list from this device's vault and the account's relays; every
/// change goes through `NostrService.publishBookmark`, the merged-list path
/// the other lists use. Twin of Android `BookmarkService.kt`.
@MainActor
final class BookmarkService: ObservableObject {
    static let shared = BookmarkService()

    /// The newest list known for `author`; nil when there is none yet.
    @Published private(set) var list: NostrEvent?
    @Published private(set) var author = ""
    @Published private(set) var saving: Set<BookmarkList.Entry> = []
    private var loadedAt: Date = .distantPast
    private var inFlight: Task<Void, Never>?

    private init() {}

    private var config: HavenConfig { ConfigService.shared.config }
    private var activeNpub: String { config.activeAccountNpub.isEmpty ? config.ownerNpub : config.activeAccountNpub }

    /// Where the list is read from: this device's vault first, then the
    /// account's own relays and a few read relays.
    private func sources(for hex: String) -> [String] {
        var urls = [config.nostrURL] + NostrService.ownListRelays(for: hex) + Array(config.readRelays.prefix(3))
        var seen = Set<String>()
        urls = urls.filter { seen.insert($0).inserted }
        return urls
    }

    /// Reads the newest list again when it is older than five minutes or the
    /// account changed (`force` always). Rows call this as they appear, so
    /// one read in flight serves them all.
    func refresh(force: Bool = false) async {
        let hex = ConfigService.shared.activeAccountHexPubkey
        guard !hex.isEmpty else { list = nil; author = ""; return }
        if !force && hex == author && Date().timeIntervalSince(loadedAt) < 300 { return }
        if let inFlight, hex == author { await inFlight.value; if !force { return } }
        if hex != author { list = nil }
        author = hex
        let task = Task { await read(hex) }
        inFlight = task
        await task.value
        if inFlight == task { inFlight = nil }
    }

    private func read(_ hex: String) async {
        let found = await NostrService.shared.fetchEvents(
            filter: ["kinds": [BookmarkList.kind], "authors": [hex], "limit": 5],
            from: sources(for: hex), includeLoopback: true)
        guard author == hex else { return }
        let newest = found.filter { $0.pubkey == hex && $0.kind == BookmarkList.kind }
            .max { $0.created_at != $1.created_at ? $0.created_at < $1.created_at : $0.id > $1.id }
        if let newest, newest.created_at >= (list?.created_at ?? 0) { list = newest }
        loadedAt = Date()
    }

    func entry(for note: FeedNote) -> BookmarkList.Entry {
        BookmarkList.entry(id: note.id, pubkey: note.pubkey, kind: note.kind, tags: note.tags)
    }

    func isBookmarked(_ note: FeedNote) -> Bool {
        guard author == ConfigService.shared.activeAccountHexPubkey, let list else { return false }
        return BookmarkList.contains(list.tags, entry(for: note))
    }

    /// Adds or removes `note`, on the newest list fetched now; says how it
    /// went in a toast. Never runs for a read-only sign-in.
    func toggle(_ note: FeedNote) {
        guard ConfigService.shared.activeAccountCanSign else { return }
        let hex = ConfigService.shared.activeAccountHexPubkey
        let npub = activeNpub
        let entry = entry(for: note)
        let on = !isBookmarked(note)
        guard !hex.isEmpty, !saving.contains(entry) else { return }
        saving.insert(entry)
        Task {
            let result = await NostrService.shared.publishBookmark(entry, on: on, author: hex, signAsNpub: npub)
            saving.remove(entry)
            guard case .saved(let newest) = result else {
                ActionToastManager.shared.show(icon: "exclamationmark.triangle.fill",
                                               message: "Bookmark not saved: your relays didn't answer", tone: .error)
                return
            }
            if let newest, author == hex, newest.pubkey == hex { list = newest; loadedAt = Date() }
            ActionToastManager.shared.show(icon: on ? "bookmark.fill" : "bookmark.slash",
                                           message: on ? "Bookmarked" : "Bookmark removed")
        }
    }

    /// The public bookmarks, newest first.
    var publicEntries: [BookmarkList.Entry] { BookmarkList.entries(list?.tags ?? []) }

    /// The private bookmarks, decrypted with the active account's key; empty
    /// when there are none or they can't be opened here.
    func privateEntries() async -> [BookmarkList.Entry] {
        guard let list, !list.content.isEmpty, list.pubkey == ConfigService.shared.activeAccountHexPubkey else { return [] }
        let nip04 = list.content.contains("?iv=")
        guard let plain = try? await MuteListStore.decryptToSelf(list.content, me: list.pubkey, nip04: nip04) else { return [] }
        return BookmarkList.privateEntries(plaintext: plain)
    }

    /// The events behind `entries`, by entry, from the vault and the relays.
    func events(for entries: [BookmarkList.Entry]) async -> [BookmarkList.Entry: NostrEvent] {
        let hex = author
        let urls = sources(for: hex)
        var out: [BookmarkList.Entry: NostrEvent] = [:]
        let ids = entries.compactMap { if case .event(let id) = $0 { return id } else { return nil } }
        for chunk in stride(from: 0, to: ids.count, by: 100).map({ Array(ids[$0..<min($0 + 100, ids.count)]) }) {
            for event in await NostrService.shared.fetchEvents(filter: ["ids": chunk], from: urls, includeLoopback: true)
            where chunk.contains(event.id) {
                out[.event(event.id)] = event
            }
        }
        // Addresses grouped by kind and author; a filter matches every
        // combination of its values, so each result is checked against a wanted coordinate.
        let wanted = Set(entries.filter { $0.coordinate != nil })
        let groups = Dictionary(grouping: wanted.compactMap { $0.coordinate }, by: { "\($0.kind):\($0.pubkey)" })
        for (_, coords) in groups {
            guard let first = coords.first else { continue }
            let found = await NostrService.shared.fetchEvents(
                filter: ["kinds": [first.kind], "authors": [first.pubkey], "#d": coords.map(\.d)],
                from: urls, includeLoopback: true)
            for event in found {
                let key = BookmarkList.entry(id: event.id, pubkey: event.pubkey, kind: event.kind, tags: event.tags)
                guard wanted.contains(key) else { continue }
                if let held = out[key], held.created_at >= event.created_at { continue }
                out[key] = event
            }
        }
        return out
    }
}
