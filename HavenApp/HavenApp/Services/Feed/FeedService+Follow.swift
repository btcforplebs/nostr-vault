import Foundation
import Combine
import SwiftUI

extension FeedService {
    // MARK: - Follow / Unfollow

    /// Backward-compatible typealias — error type now lives in ContactManager.
    typealias FollowActionError = ContactManager.FollowActionError

    @discardableResult
    /// `onPublishFailed` runs on the main actor if the new list could not be
    /// signed or every relay refused it; the follow has been rolled back by then.
    func followUser(_ pubkey: String, onPublishFailed: (() -> Void)? = nil) -> Result<Void, FollowActionError> {
        switch ContactManager.prepareFollow(
            pubkey: pubkey,
            currentPTags: contactListPTags,
            currentPubkeys: followedPubkeys,
            hasAttemptedLoad: hasAttemptedContactLoad,
            isLoading: isLoadingContacts,
            listConfirmed: contactListConfirmed
        ) {
        case .failure(.contactsNotLoaded):
            queueFollowAction(pubkey, follow: true)
            return .failure(.contactsNotLoaded)
        case .failure(.listUnavailable):
            // Kept queued and retried; never published against an unknown list.
            queueFollowAction(pubkey, follow: true)
            return .failure(.listUnavailable)
        case .failure(let err): return .failure(err)
        case .success(let result):
            let previous = (pTags: contactListPTags, pubkeys: followedPubkeys)
            contactListPTags = result.pTags
            followedPubkeys = result.pubkeys
            publishContactList(rollback: previous, onFailure: onPublishFailed)
            // Re-filter so already-loaded notes from the newly-followed author
            // surface immediately in the Following feed.
            recomputeFilteredNotes()
            // Re-issue the live primary REQ so the new follow's FUTURE notes stream
            // in without waiting for a full refresh.
            resubscribePrimaryIfNeeded()

            // Auto-switch back to Following now that the user has follows.
            if didAutoSwitchToCurated {
                didAutoSwitchToCurated = false
                switchMode(.following)
            }

            return .success(())
        }
    }

    @discardableResult
    /// `onPublishFailed`: as for `followUser`.
    func unfollowUser(_ pubkey: String, onPublishFailed: (() -> Void)? = nil) -> Result<Void, FollowActionError> {
        switch ContactManager.prepareUnfollow(
            pubkey: pubkey,
            activeAccountHex: ConfigService.shared.activeAccountHexPubkey,
            currentPTags: contactListPTags,
            currentPubkeys: followedPubkeys,
            hasAttemptedLoad: hasAttemptedContactLoad,
            isLoading: isLoadingContacts,
            listConfirmed: contactListConfirmed
        ) {
        case .failure(.contactsNotLoaded):
            queueFollowAction(pubkey, follow: false)
            return .failure(.contactsNotLoaded)
        case .failure(.listUnavailable):
            // Kept queued and retried; never published against an unknown list.
            queueFollowAction(pubkey, follow: false)
            return .failure(.listUnavailable)
        case .failure(let err): return .failure(err)
        case .success(let result):
            let previous = (pTags: contactListPTags, pubkeys: followedPubkeys)
            contactListPTags = result.pTags
            followedPubkeys = result.pubkeys
            publishContactList(rollback: previous, onFailure: onPublishFailed)
            // Re-filter so the unfollowed author's notes disappear from the
            // Following feed immediately (the filter now excludes non-follows).
            recomputeFilteredNotes()
            // Re-issue the live primary REQ so the relay stops streaming the
            // unfollowed author's future notes.
            resubscribePrimaryIfNeeded()
            return .success(())
        }
    }

    /// - rollback: the list before this edit. If it may not be published at
    ///   all (empty, or shrunk past the safety check), signing fails, or every
    ///   relay refuses the event, and nothing has changed the list since, it
    ///   is put back so the screen never shows a follow that was not published.
    func publishContactList(
        rollback: (pTags: [[String]], pubkeys: [String])? = nil,
        onFailure: (() -> Void)? = nil
    ) {
        let attempted = contactListPTags
        let fail: @MainActor (_ refusedAt: Int64?) -> Void = { [weak self] refusedAt in
            guard let self else { return }
            if let rollback, self.contactListPTags == attempted {
                if let refusedAt { self.refusedContactListCreatedAt = refusedAt }
                self.contactListPTags = rollback.pTags
                self.followedPubkeys = rollback.pubkeys
                self.recomputeFilteredNotes()
                self.resubscribePrimaryIfNeeded()
            }
            onFailure?()
        }
        guard ContactManager.mayPublish(tagCount: contactListPTags.count, lastFetchedCount: lastFetchedContactCount) else {
            #if DEBUG
            print("FeedService: BLOCKED contact list publish — \(contactListPTags.count) tags vs \(lastFetchedContactCount) fetched. Possible data loss.")
            #endif
            // After the caller's re-filter, so the rollback lands last.
            DispatchQueue.main.async { fail(nil) }
            return
        }
        // The key has a list now; from here on its load must find it.
        FreshAccountKeys.clear(ConfigService.shared.activeAccountHexPubkey)
        // Bump the local-edit guard synchronously to "now" so an immediate contact
        // refresh (firing before the async sign/post below completes) can't accept a
        // stale relay copy and drop the edit we're about to publish.
        ownContactListAccountKey = currentSnapshotKey()
        ownContactListCreatedAt = max(ownContactListCreatedAt, Int64(Date().timeIntervalSince1970))
        Task { [weak self] in
            guard let self = self else { return }
            guard let event = await NostrService.shared.signEventAsync(kind: 3, content: self.contactListContent, tags: attempted) else {
                fail(nil)
                return
            }
            self.recordOwnContactList(event: event)
            NostrService.shared.postEvent(event, onBroadcastOutcome: { outcome in
                guard outcome == .refused else { return }
                Task { @MainActor in fail(event.created_at) }
            })
        }
    }

    /// Records the timestamp + a durable backup of a contact list we just signed,
    /// so a later relay fetch returning an older copy can't clobber this edit.
    @MainActor
    private func recordOwnContactList(event: NostrEvent) {
        ownContactListCreatedAt = max(ownContactListCreatedAt, event.created_at)
        FollowingBackupService.shared.maybeCreateSnapshot(
            pubkeys: followedPubkeys,
            pTags: contactListPTags,
            contactListContent: contactListContent,
            contactListCreatedAt: event.created_at,
            forAccountKey: currentSnapshotKey()
        )
    }

    /// A key setup just generated has no kind 3 anywhere, so its empty follow
    /// list is known without waiting for every relay to say so. Without this
    /// one silent relay leaves a new account unable to follow anyone (the
    /// follow is queued) and the Fill your feed guide never starts.
    func markFreshAccount(_ hex: String) {
        guard !hex.isEmpty else { return }
        FreshAccountKeys.mark(hex)
        // The first load may already have finished without a list.
        if hex == ConfigService.shared.activeAccountHexPubkey,
           hasAttemptedContactLoad, !isLoadingContacts, followedPubkeys.isEmpty {
            contactListConfirmed = true
        }
    }

    /// Restores the contact list from a backup, bypassing the shrinkage safety check.
    /// Used when the user explicitly chooses to restore from a historical Kind 3 event.
    func restoreContactList(pTags: [[String]], content: String) {
        guard !pTags.isEmpty else { return }
        self.contactListPTags = pTags
        self.followedPubkeys = pTags.compactMap { $0.count >= 2 ? $0[1] : nil }
        self.contactListContent = content
        self.lastFetchedContactCount = pTags.count
        Task { [weak self] in
            guard let self = self else { return }
            guard let event = await NostrService.shared.signEventAsync(kind: 3, content: self.contactListContent, tags: self.contactListPTags) else { return }
            self.recordOwnContactList(event: event)
            NostrService.shared.postEvent(event)
        }
    }
}
