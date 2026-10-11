import Foundation
import Combine
import SwiftUI

extension FeedService {
    func markViewed() {
        newNoteCount = 0
        newSinceLastView = Date()
    }

    func addNote(_ note: FeedNote) {
        if !notes.contains(where: { $0.id == note.id }) {
            notes.insert(note, at: 0)
            if notes.count > Self.maxNotes {
                notes.removeLast(notes.count - Self.maxNotes)
            }
            seenIds.insert(note.id)
            trimSeenIdsIfNeeded()
            recomputeFilteredNotes()
        }
    }

    func removeNote(id: String) {
        notes.removeAll { $0.id == id }
        pendingNotes.removeAll { $0.id == id }
        parentNotesCache.removeValue(forKey: id)
        recomputeFilteredNotes()
    }

    func applyPendingNotes() {
        guard !pendingNotes.isEmpty else { return }
        
        // Merge pending into active notes
        let newNotes = pendingNotes
        pendingNotes.removeAll()
        
        notes.append(contentsOf: newNotes)
        notes.sort { $0.createdAt > $1.createdAt }
        if notes.count > Self.maxNotes {
            notes.removeLast(notes.count - Self.maxNotes)
        }
        recomputeFilteredNotes()

        // Update new note count/tracking
        newSinceLastView = Date()
        newNoteCount = 0
    }

    /// Looks up a note in the local parent notes cache or in the main feed list.
    /// Also handles naddr coordinate strings ("naddr:<kind>:<pubkey>:<d-tag>").
    func findNote(id: String) -> FeedNote? {
        if id.hasPrefix(QuoteReference.coordinatePrefix) {
            return findNoteByNaddrCoordinate(id)
        }
        if let cached = parentNotesCache[id] {
            return cached
        }
        return noteIndex[id]
    }

    /// The note a reply should actually answer. A bare kind-6 repost is a
    /// wrapper with no body of its own, so replying to one has to address the
    /// note it carries. Every reply entry point — the feed row, a thread card's
    /// opened line, and both of the thread view's reply buttons — resolves
    /// through here, because each one used to carry its own copy of this rule
    /// and one of them was always missing it.
    func replyTarget(for note: FeedNote) -> FeedNote {
        guard note.kind == 6,
              let refId = note.repostedEventId,
              let original = findNote(id: refId) else { return note }
        return original
    }

    /// The note a quote should actually cite. Quoting a repost has to cite the
    /// note it carries — otherwise the `q` tag and `nostr:nevent` point at the
    /// kind-6 wrapper, and every client renders the quote as a repost card.
    /// When the original isn't loaded, rebuild it from the repost. Only trust
    /// the author/body/tags `FeedNote.init` unpacked if it really unpacked the
    /// NIP-18 embedded event. `repostedBy` can't tell us (the feed sets it on
    /// every kind 6) and `content` is already the inner body, but the tags can:
    /// the repost's own tags always carry `["e", refId]` — that's where
    /// `repostedEventId` comes from — and an event can never tag its own id.
    /// Still holding that tag means nothing was unpacked and this note carries
    /// the reposter's identity, so take the author from the repost's `p` tag.
    func quoteTarget(for note: FeedNote) -> FeedNote {
        originalNote(for: note)
    }

    /// The note a repost stands for, for anything that acts on it: quoting,
    /// liking, zapping, and the counts and states a repost row shows. Always
    /// carries the original's id and author, even before its body arrives;
    /// see `quoteTarget` for how an embedded copy is told from a bare repost.
    func originalNote(for note: FeedNote) -> FeedNote {
        guard note.kind == 6, let refId = note.repostedEventId else { return note }
        if let original = findNote(id: refId) { return original }
        let carriesOriginal = !note.tags.contains { $0.count >= 2 && $0[0] == "e" && $0[1] == refId }
        guard !carriesOriginal else {
            return FeedNote(id: refId, pubkey: note.pubkey, content: note.content,
                            createdAt: note.createdAt, tags: note.tags, kind: 1)
        }
        let author = note.tags.first { $0.count >= 2 && $0[0] == "p" }?[1] ?? note.pubkey
        return FeedNote(id: refId, pubkey: author, content: "",
                        createdAt: note.createdAt, tags: [], kind: 1)
    }

    /// The note a thread view should open. Opening a kind-6 repost showed the
    /// original's text over the wrapper's own empty likes and zaps, with no
    /// conversation above it. Uses the loaded original, else the one the
    /// repost embeds (same test as `quoteTarget`). A bare repost whose
    /// original hasn't arrived stays as it is; the thread view already
    /// handles that wrapper.
    func threadTarget(for note: FeedNote) -> FeedNote {
        guard note.kind == 6, let refId = note.repostedEventId else { return note }
        if let original = findNote(id: refId) { return original }
        let carriesOriginal = !note.tags.contains { $0.count >= 2 && $0[0] == "e" && $0[1] == refId }
        guard carriesOriginal else { return note }
        return FeedNote(id: refId, pubkey: note.pubkey, content: note.content,
                        createdAt: note.originalCreatedAt ?? note.createdAt, tags: note.tags, kind: 1)
    }

    /// Finds a note matching an naddr coordinate ("naddr:<kind>:<pubkey>:<d-tag>").
    private func findNoteByNaddrCoordinate(_ coordinate: String) -> FeedNote? {
        let matcher = QuoteReference.matcher(for: coordinate)
        let match: (FeedNote) -> Bool = { note in
            matcher.matches(id: note.id, kind: note.kind, pubkey: note.pubkey, tags: note.tags)
        }

        // Check parentNotesCache first
        if let cached = parentNotesCache.values.first(where: match) {
            return cached
        }
        return notes.first(where: match)
    }

    /// Load older notes (pagination) — fetches the page before the oldest note currently shown.
    func loadMore() {
        guard feedMode != .popular else { return } // Popular is a fixed ranked set
        guard !isLoadingFeed, let oldest = notes.last?.createdAt else { return }
        let until = Int64(oldest.timeIntervalSince1970) - 1
        if (isFollowSetMode || (feedMode == .media && mediaFeedMode == .following)) && followedPubkeys.isEmpty { return }
        if feedMode == .discovery && extendedNetworkPubkeys.isEmpty { return }

        isLoadingFeed = true
        shouldScrollToTopOnLoad = false
        eoseCount = 0

        let allURLs = feedRelayURLs()

        let totalRelays = allURLs.count
        for url in allURLs {
            connectFeedRelayWithUntil(url: url, until: until, totalRelays: totalRelays)
        }

        // A page client that never connects never sends EOSE, and nothing else
        // ended the page — one dead relay stopped older pages for good. The
        // outbox relays come from other people's lists, so that is now likely.
        pageLoadTimeout?.invalidate()
        pageLoadTimeout = Timer.scheduledTimer(withTimeInterval: 20.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isLoadingFeed else { return }
                self.flushNoteBuffer()
                self.isLoadingFeed = false
            }
        }
    }
}
