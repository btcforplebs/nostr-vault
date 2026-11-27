import SwiftUI

/// Everything a `FeedThreadCard` draws, as one Equatable value, so the feed
/// can skip a card whose conversation, people, open note and quotes did not
/// change (Feed tab perf review 11-27 #3: 20 live notes ran 1,967 card
/// bodies, about 100 per note, because a card takes closures and Bindings
/// and was redrawn with every FeedView pass). Same idea as the Vault rows'
/// input model (#2630).
///
/// Built by the feed each pass from the same lookups the card makes, so a
/// change that would alter a card (a profile arriving, a reposted original
/// or quote loading, a like on the open note) changes its input.
struct FeedThreadCardInput: Equatable {
    let entries: [FeedNote]
    let depths: [Int]
    let rootUnavailable: Bool
    let openNoteId: String?
    let isExpanded: Bool
    let isOLED: Bool
    /// Each entry's author, a bare repost's original author and each loaded
    /// quote's author.
    let profiles: [FeedProfile?]
    /// Row data the card asks for: the open note's, and each bare repost's
    /// (its original).
    let rowData: [FeedNoteRowData]
    /// For each quoted id across the entries (a bare repost's are its
    /// original's, as the card draws): the loaded note's id, so a newer
    /// replaceable version (a 30311 stream update) redraws; "!" unavailable;
    /// "" loading.
    let quoteStates: [String]

    @MainActor
    init(thread: FeedThread<FeedNote>, openNoteId: String?, isExpanded: Bool, rootUnavailable: Bool,
         profileFor: (String) -> FeedProfile?, rowDataFor: (FeedNote) -> FeedNoteRowData,
         find: (String) -> FeedNote?, unavailable: Set<String>, isOLED: Bool) {
        var entries: [FeedNote] = [], depths: [Int] = [], profiles: [FeedProfile?] = []
        var rowData: [FeedNoteRowData] = [], quoteStates: [String] = []
        entries.reserveCapacity(thread.entries.count)
        for entry in thread.entries {
            let note = entry.note
            entries.append(note)
            depths.append(entry.depth)
            profiles.append(profileFor(note.pubkey))
            let isBareRepost = note.kind == 6 && note.content.isEmpty && note.repostedEventId != nil
            var shown = note
            if isBareRepost || note.id == openNoteId {
                let data = rowDataFor(note)
                rowData.append(data)
                if let original = data.resolvedOriginal {
                    profiles.append(profileFor(original.pubkey))
                    // The card resolves quotes and live cleanup on a bare
                    // repost's original, not the empty repost.
                    if isBareRepost { shown = original }
                }
            }
            for id in shown.quotedEventIds {
                if let quoted = find(id) {
                    quoteStates.append(quoted.id)
                    profiles.append(profileFor(quoted.pubkey))
                } else {
                    quoteStates.append(unavailable.contains(id) ? "!" : "")
                }
            }
            if let refId = note.repostedEventId, isBareRepost {
                quoteStates.append(unavailable.contains(refId) ? "!" : "")
            }
        }
        self.entries = entries
        self.depths = depths
        self.rootUnavailable = rootUnavailable
        self.openNoteId = openNoteId
        self.isExpanded = isExpanded
        self.isOLED = isOLED
        self.profiles = profiles
        self.rowData = rowData
        self.quoteStates = quoteStates
    }
}

/// A thread card the feed skips when its input is unchanged. The card's
/// closures and Bindings are left out of `==`: they only reach the feed's
/// own state, which the Bindings read when used.
struct EquatableFeedThreadCard: View, Equatable {
    let input: FeedThreadCardInput
    let card: FeedThreadCard

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.input == rhs.input }

    var body: some View { card }
}
