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

    /// Asks `client` for the owner's kind-5 requests, once per connection.
    /// The subscription stays open, so later requests arrive live; sending
    /// it again on every resubscribe only replayed the same 200 events.
    /// No `since`: an old request still counts.
    func sendDeleteRequestsSubscription(client: WebSocketClient, subId: String, owner: String) {
        guard Self.deleteSubscriptions.object(forKey: client) as String? != owner else { return }
        let req = ["REQ", "del-\(subId)", Self.deleteRequestsFilter(owner: owner)] as [Any]
        guard let data = try? JSONSerialization.data(withJSONObject: req),
              let str = String(data: data, encoding: .utf8) else { return }
        client.send(text: str)
        Self.deleteSubscriptions.setObject(owner as NSString, forKey: client)
    }

    /// A new socket starts with no subscriptions.
    func forgetDeleteRequestsSubscription(client: WebSocketClient) {
        Self.deleteSubscriptions.removeObject(forKey: client)
    }

    /// Which owner each live feed client holds the kind-5 subscription for.
    private static let deleteSubscriptions = NSMapTable<WebSocketClient, NSString>.weakToStrongObjects()

    /// A kind 5 from a feed subscription, as the relay sent it. Called on
    /// the feed's processing queue. A request already handled, or naming
    /// only posts already off the feed, stops here: relays replay your
    /// requests on every subscription. Nothing is remembered until the
    /// event's signature checks out: a relay could otherwise hide any post
    /// under your name. Checked here, off the main thread; the purge runs
    /// once per main-thread hop for everything that arrived meanwhile.
    nonisolated func handleDeleteRequest(_ event: [String: Any]) {
        guard let requestId = event["id"] as? String,
              let pubkey = event["pubkey"] as? String else { return }
        let targets = DeletedNotes.targets(ofRequestTags: event["tags"] as? [[String]] ?? [])
        let store = DeletedNotesStore.shared
        let fresh = store.claimRequest(requestId, naming: targets, account: pubkey)
        guard !fresh.isEmpty else { return }
        guard DeletedNotes.isOwnSignedRequest(event, owner: pubkey, verify: NostrEventVerifier.isValid) else {
            store.releaseRequest(requestId)
            return
        }
        guard Self.pendingDeleteRequests.add(requestId, ids: fresh, account: pubkey) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.applyPendingDeleteRequests()
        }
    }

    /// Purges what `handleDeleteRequest` queued, in one pass. Requests
    /// signed by another account (the active one changed meanwhile) are
    /// released so they apply if that account comes back.
    private func applyPendingDeleteRequests() {
        let owner = deletedNotesAccount
        var ids = Set<String>()
        for request in Self.pendingDeleteRequests.take() {
            if request.account == owner {
                ids.formUnion(request.ids)
            } else {
                DeletedNotesStore.shared.releaseRequest(request.id)
            }
        }
        purgeDeletedNotes(ids)
    }

    private nonisolated static let pendingDeleteRequests = PendingDeleteRequests()

    /// Remembers `ids` as deleted for the active account and takes them,
    /// and reposts of them, off every list and cache this service holds.
    func purgeDeletedNotes(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        DeletedNotesStore.shared.markDeleted(ids, account: deletedNotesAccount)
        DeletedNotesStore.shared.markAppliedToFeed(ids, account: deletedNotesAccount)
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

/// Verified kind-5 requests waiting for the main thread. Filled on the
/// feed's processing queue, emptied by `applyPendingDeleteRequests`.
private final class PendingDeleteRequests: @unchecked Sendable {
    struct Request {
        let id: String
        let ids: Set<String>
        let account: String
    }

    private let lock = NSLock()
    private var requests: [Request] = []

    /// Queues a request. True when the queue was empty, so the caller
    /// schedules the one main-thread pass that empties it.
    func add(_ id: String, ids: Set<String>, account: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        requests.append(Request(id: id, ids: ids, account: account))
        return requests.count == 1
    }

    func take() -> [Request] {
        lock.lock(); defer { lock.unlock() }
        defer { requests = [] }
        return requests
    }
}
