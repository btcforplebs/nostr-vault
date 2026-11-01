import SwiftUI

/// The feed's row data and its thread grouping, held by reference.
///
/// As `@State` on `FeedView` these were copied into every `FeedView` value
/// that SwiftUI or a queued work item kept (ForEach content, `rowDataFor`,
/// the debounced rebuilds), and each copy held the dictionary as it was at
/// that moment. Tom's heap snapshot found 24 live row-data dictionaries
/// (44 MB) and 40 thread arrays (sweep 11-01 #3). Every copy of the view
/// shares this one object, so only the current dictionary stays alive.
@MainActor
final class FeedRowStore: ObservableObject {
    @Published var rows: [String: FeedNoteRowData] = [:]
    @Published var threads: [FeedThread<FeedNote>] = []
    /// Bumped by every thread rebuild, so an off-main grouping that a newer
    /// rebuild overtook is dropped rather than applied.
    var threadGeneration = 0
}

extension FeedView {
    /// Pre-resolved row data by note id; see `FeedRowStore`.
    var rowDataCache: [String: FeedNoteRowData] {
        get { rowStore.rows }
        nonmutating set { rowStore.rows = newValue }
    }

    /// Conversations built from `filteredNotes` for threaded mode. Rebuilt on
    /// the same signals as the row-data cache and left empty in the other two
    /// layouts so nothing is grouped that will never be drawn.
    var feedThreads: [FeedThread<FeedNote>] {
        get { rowStore.threads }
        nonmutating set { rowStore.threads = newValue }
    }
}
