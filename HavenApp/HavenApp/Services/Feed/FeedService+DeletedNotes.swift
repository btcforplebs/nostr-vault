import Foundation
import Combine
import SwiftUI

extension FeedNote: DeletableNote {}

/// Keeping deleted posts gone: your own kind-5 requests, from this device
/// or another, take their targets off the feed, the thread screen, the
/// caches a refresh or mode switch restores, and the root and quote
/// fetches. See `DeletedNotes` for the rules and `DeletedNotesStore` for
/// what is remembered. Twin: Android `FeedServiceDeletedNotes.kt`.
extension FeedService {
    private var deletedNotesAccount: String { NostrService.shared.activeHexPubkey }

    /// The active account's deleted ids.
    var deletedNoteIds: Set<String> {
        DeletedNotesStore.shared.ids(forAccount: deletedNotesAccount)
    }

    func isDeleted(_ id: String) -> Bool {
        DeletedNotesStore.shared.contains(id, account: deletedNotesAccount)
    }

    /// Whether a row stays off screen: the deleted post, or a repost of it.
    func hidesDeleted(_ note: FeedNote) -> Bool {
        DeletedNotes.hides(note, deleted: deletedNoteIds)
    }

    func withoutDeletedNotes(_ notes: [FeedNote]) -> [FeedNote] {
        DeletedNotes.visible(notes, deleted: deletedNoteIds)
    }

    func withoutDeletedNotes(_ cache: [String: FeedNote]) -> [String: FeedNote] {
        DeletedNotes.visible(cache, deleted: deletedNoteIds)
    }

    /// The feed relays' subscription for the owner's own kind-5 requests.
    /// The local relay serves the ones your other devices sent once the
    /// vault has imported them; the outbox relays serve them directly.
    static func deleteRequestsFilter(owner: String) -> [String: Any] {
        ["kinds": [DeletedNotes.requestKind], "authors": [owner], "limit": 200]
    }

    /// A kind 5 from a feed subscription. Called on the feed's processing
    /// queue; applies on the main actor like the other feed state changes.
    nonisolated func handleDeleteRequest(pubkey: String, tags: [[String]]) {
        let ids = DeletedNotes.targets(ofRequestTags: tags)
        guard !ids.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, DeletedNotes.isOwnRequest(kind: DeletedNotes.requestKind, pubkey: pubkey, owner: self.deletedNotesAccount) else { return }
            self.purgeDeletedNotes(ids)
        }
    }

    /// Remembers `ids` as deleted for the active account and takes them,
    /// and reposts of them, off every list and cache this service holds.
    func purgeDeletedNotes(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        DeletedNotesStore.shared.markDeleted(ids, account: deletedNotesAccount)
        notes = DeletedNotes.visible(notes, deleted: ids)
        pendingNotes = DeletedNotes.visible(pendingNotes, deleted: ids)
        noteBuffer = DeletedNotes.visible(noteBuffer, deleted: ids)
        parentNotesCache = DeletedNotes.visible(parentNotesCache, deleted: ids)
        // A quote or thread card waiting on one shows "unavailable" rather
        // than a skeleton, and never asks a relay for it.
        unavailableNoteIds.formUnion(ids)
        recomputeFilteredNotes()

        let nostr = NostrService.shared
        nostr.events = NoteDeletion.without(nostr.events, noteIds: ids)
        nostr.eventUpdateSubject.send()
        NotificationCenter.default.post(name: .havenOwnEventsDeleted, object: ids)
    }
}
