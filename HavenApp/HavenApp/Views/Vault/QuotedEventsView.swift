import SwiftUI

/// The cards for whatever a relay-tab note quotes.
///
/// The timeline hides `nostr:` quote references from the body text and renders
/// the quoted event underneath; this is the same behaviour for the relay tab,
/// which previously left the reference in the text as a bare "Quote" link and
/// drew no card at all. An event the relay does not hold is requested and
/// holds a skeleton while it is fetched — through the feed's loader too, which
/// asks the author's outbox relays — and says so if it never turns up. It used
/// to ask only the local and feed relays, once, and draw nothing meanwhile, so a
/// quote of a note living elsewhere showed just the quoting post.
struct QuotedEventsView: View {
    let identifiers: [String]
    /// The quoting note's text: its nevents say where the quoted notes live.
    var content: String = ""
    @EnvironmentObject var nostrService: NostrService

    var body: some View {
        if !identifiers.isEmpty {
            VStack(spacing: 8) {
                ForEach(identifiers, id: \.self) { identifier in
                    if let quoted = nostrService.storedEvent(matching: identifier)?.asFeedNote
                        ?? FeedService.shared.findNote(id: identifier) {
                        QuotedNoteView(note: quoted)
                            .environmentObject(nostrService)
                    } else {
                        PendingQuotedEventView(identifier: identifier, content: content)
                    }
                }
            }
        }
    }
}

/// A relay-tab quote that has not arrived yet. Split out so only unresolved
/// cards observe `FeedService`, not every row that quotes something.
private struct PendingQuotedEventView: View {
    let identifier: String
    let content: String
    @EnvironmentObject var nostrService: NostrService
    @ObservedObject private var feedService = FeedService.shared

    var body: some View {
        if let note = feedService.findNote(id: identifier) {
            QuotedNoteView(note: note)
                .environmentObject(nostrService)
        } else if feedService.unavailableNoteIds.contains(identifier) {
            Text("Quoted note unavailable")
                .font(.appSystem(size: 12, weight: .regular))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            QuotedNoteSkeleton()
                .onAppear {
                    nostrService.fetchQuotedEvent(identifier)
                    feedService.rememberQuoteHints(in: content)
                    feedService.fetchMissingNote(id: identifier)
                }
        }
    }
}
