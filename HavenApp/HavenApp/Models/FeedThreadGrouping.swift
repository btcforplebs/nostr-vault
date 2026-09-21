import Foundation

/// The minimum a note has to expose to be arranged into a thread. `FeedNote`
/// conforms to it, and so does a plain fixture in the test package — the tree
/// logic is worth proving without a relay, a service or a view.
protocol ThreadGroupable {
    var id: String { get }
    var authorPubkey: String { get }
    var createdAt: Date { get }
    var parentEventId: String? { get }
    var tags: [[String]] { get }
}

/// One note placed in a thread, carrying how deep it sits under the root.
struct FeedThreadEntry<Note: ThreadGroupable>: Identifiable {
    let note: Note
    /// 0 for the root, 1 for a direct reply, and so on. Capped by
    /// `FeedThreadGrouping.maxDepth` so a long argument cannot indent the
    /// content off a phone screen.
    let depth: Int

    var id: String { note.id }
}

/// A root note plus every reply to it present in the feed, flattened into
/// reading order.
struct FeedThread<Note: ThreadGroupable>: Identifiable {
    /// The thread root's event ID, present whether or not the root itself loaded.
    let rootId: String
    /// The root note, or nil when the feed only carries replies to it and the
    /// root has not been fetched yet.
    let root: Note?
    /// Root first (when present), then replies depth-first, oldest sibling first.
    let entries: [FeedThreadEntry<Note>]
    /// Newest `createdAt` anywhere in the thread — what the feed sorts on, so a
    /// thread rises when someone replies rather than staying pinned to the
    /// root's age.
    let latestActivity: Date

    var id: String { rootId }

    /// Everything below the root, in the same order as `entries`.
    var replies: [FeedThreadEntry<Note>] {
        guard let root else { return entries }
        return entries.filter { $0.note.id != root.id }
    }

    /// Distinct authors, root first, in the order they appear in the thread.
    var participantPubkeys: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for entry in entries where seen.insert(entry.note.authorPubkey).inserted {
            result.append(entry.note.authorPubkey)
        }
        return result
    }
}

enum FeedThreadGrouping {
    /// Indentation stops here; deeper replies keep their order but share the
    /// last rail, which is what every readable mobile thread does.
    static let maxDepth = 4

    /// Arrange a flat, newest-first feed into threads.
    ///
    /// - Parameters:
    ///   - notes: the feed as rendered today, in feed order.
    ///   - resolveNote: looks up a note that is referenced but not in `notes`
    ///     (an ancestor the feed never showed). Returning nil is fine — the
    ///     thread is then rooted at the highest ancestor that did load.
    /// - Returns: threads ordered by `latestActivity`, newest first.
    static func build<Note: ThreadGroupable>(
        notes: [Note],
        resolveNote: (String) -> Note? = { _ in nil }
    ) -> [FeedThread<Note>] {
        guard !notes.isEmpty else { return [] }

        // Everything we can see: the feed plus any ancestor we can resolve.
        var pool: [String: Note] = [:]
        for note in notes { pool[note.id] = note }

        for note in notes {
            var currentId = note.parentEventId
            var hops = 0
            while let id = currentId, pool[id] == nil, hops < 64 {
                guard let resolved = resolveNote(id) else { break }
                pool[id] = resolved
                currentId = resolved.parentEventId
                hops += 1
            }
        }

        // Resolve each feed note to the topmost ancestor we actually have.
        var rootIdCache: [String: String] = [:]
        func rootId(for note: Note) -> String {
            if let cached = rootIdCache[note.id] { return cached }

            var chain: [String] = []
            var current = note
            var hops = 0
            while let parentId = current.parentEventId, hops < 64 {
                chain.append(current.id)
                guard let parent = pool[parentId] else {
                    // The parent never loaded. NIP-10 may still name the real
                    // root, which keeps sibling branches of one conversation
                    // together instead of scattering them.
                    let resolved = taggedRootId(of: current) ?? parentId
                    for id in chain { rootIdCache[id] = resolved }
                    rootIdCache[note.id] = resolved
                    return resolved
                }
                current = parent
                hops += 1
            }

            let resolved = current.id
            for id in chain { rootIdCache[id] = resolved }
            rootIdCache[note.id] = resolved
            return resolved
        }

        // Group, preserving the order roots first appear in the feed so a
        // stable tie-break exists for threads sharing a timestamp.
        var order: [String] = []
        var grouped: [String: [Note]] = [:]
        var seenInGroup: [String: Set<String>] = [:]

        func add(_ note: Note, to root: String) {
            if seenInGroup[root]?.contains(note.id) == true { return }
            if grouped[root] == nil {
                grouped[root] = []
                seenInGroup[root] = []
                order.append(root)
            }
            grouped[root]?.append(note)
            seenInGroup[root]?.insert(note.id)
        }

        for note in notes {
            let root = rootId(for: note)
            add(note, to: root)

            // Pull in resolved ancestors between this note and the root so the
            // thread reads as a chain rather than jumping over missing links.
            var currentId = note.parentEventId
            var hops = 0
            while let id = currentId, let ancestor = pool[id], hops < 64 {
                add(ancestor, to: root)
                currentId = ancestor.parentEventId
                hops += 1
            }
        }

        var threads: [FeedThread<Note>] = []
        for root in order {
            guard let members = grouped[root] else { continue }
            let rootNote = members.first(where: { $0.id == root })
            let entries = flatten(members: members, rootId: root)
            let latest = members.map(\.createdAt).max() ?? Date.distantPast
            threads.append(
                FeedThread(rootId: root, root: rootNote, entries: entries, latestActivity: latest)
            )
        }

        return threads.sorted { lhs, rhs in
            if lhs.latestActivity == rhs.latestActivity {
                return (order.firstIndex(of: lhs.rootId) ?? 0) < (order.firstIndex(of: rhs.rootId) ?? 0)
            }
            return lhs.latestActivity > rhs.latestActivity
        }
    }

    /// Depth-first walk from the root, oldest sibling first, so a thread reads
    /// top to bottom the way it was written.
    private static func flatten<Note: ThreadGroupable>(members: [Note], rootId: String) -> [FeedThreadEntry<Note>] {
        var byId: [String: Note] = [:]
        for note in members { byId[note.id] = note }

        var children: [String: [Note]] = [:]
        var tops: [Note] = []
        for note in members where note.id != rootId {
            // A note whose parent is missing from this group still belongs to the
            // thread; hang it off the root rather than dropping it.
            if let parentId = note.parentEventId, byId[parentId] != nil, parentId != note.id {
                children[parentId, default: []].append(note)
            } else {
                tops.append(note)
            }
        }
        for key in children.keys {
            children[key]?.sort { $0.createdAt < $1.createdAt }
        }
        tops.sort { $0.createdAt < $1.createdAt }

        var entries: [FeedThreadEntry<Note>] = []
        var visited = Set<String>()

        func visit(_ note: Note, depth: Int) {
            guard visited.insert(note.id).inserted else { return }
            entries.append(FeedThreadEntry(note: note, depth: min(depth, maxDepth)))
            for child in children[note.id] ?? [] {
                visit(child, depth: depth + 1)
            }
        }

        if let root = byId[rootId] {
            visit(root, depth: 0)
            for top in tops { visit(top, depth: 1) }
        } else {
            // Root never loaded: its direct replies become the top level.
            for top in tops { visit(top, depth: 1) }
        }

        return entries
    }

    /// The `root`-marked e-tag from NIP-10, when the author wrote one.
    private static func taggedRootId<Note: ThreadGroupable>(of note: Note) -> String? {
        note.tags.first { $0.count >= 4 && $0[0] == "e" && $0[3] == "root" }?[1]
    }
}
