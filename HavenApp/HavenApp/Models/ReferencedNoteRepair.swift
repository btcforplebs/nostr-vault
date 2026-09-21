import Foundation

/// The parts of a feed row that can reference *another* event: a thread
/// parent, the original behind a kind-6 repost, or quoted notes. Kept as a
/// protocol so the repair logic below is testable without the SwiftUI app.
protocol ReferencedNoteRow {
    var id: String { get }
    var parentEventId: String? { get }
    var repostedEventId: String? { get }
    var quotedEventIds: [String] { get }
    /// The NIP-10 thread root. Distinct from `parentEventId` for anything
    /// deeper than a direct reply, and the thread card asks for it by id, so
    /// it counts as referenced even when no row's parent points at it.
    var threadRootEventId: String? { get }
}

/// Pure selection logic for `ReferencedNoteSignal`: given the notes currently
/// on screen and the ids that just arrived, which rows need re-resolving.
/// Extracted from the view so it can be tested without SwiftUI.
enum ReferencedNoteRepair {
    /// Rows in `notes` that reference any id in `arrivedIds` as their thread
    /// parent, their kind-6 original, or one of their quoted notes.
    static func rowsNeedingRepair<T: ReferencedNoteRow>(notes: [T], arrivedIds: Set<String>) -> Set<String> {
        guard !arrivedIds.isEmpty else { return [] }
        var ids = Set<String>()
        for note in notes {
            if let parentId = note.parentEventId, arrivedIds.contains(parentId) {
                ids.insert(note.id)
                continue
            }
            if let refId = note.repostedEventId, arrivedIds.contains(refId) {
                ids.insert(note.id)
                continue
            }
            if note.quotedEventIds.contains(where: arrivedIds.contains) {
                ids.insert(note.id)
            }
        }
        return ids
    }

    /// Every event id `notes` can ask the referenced-note cache for. The cache
    /// is trimmed against this, so anything still reachable from the timeline
    /// survives — an id left out here is fetched, cached, then evicted, and
    /// the surface waiting on it falls back to its loading state forever.
    static func referencedIds<T: ReferencedNoteRow>(in notes: [T]) -> Set<String> {
        var ids = Set<String>()
        for note in notes {
            if let parentId = note.parentEventId { ids.insert(parentId) }
            if let refId = note.repostedEventId { ids.insert(refId) }
            if let rootId = note.threadRootEventId { ids.insert(rootId) }
            ids.formUnion(note.quotedEventIds)
        }
        return ids
    }
}
