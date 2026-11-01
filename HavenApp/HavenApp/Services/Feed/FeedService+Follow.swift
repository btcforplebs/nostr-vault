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
            listConfirmed: contactListConfirmed,
            readOnly: Self.activeAccountIsReadOnly
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
            applyFollowEdit(pTags: result.pTags, pubkeys: result.pubkeys, onPublishFailed: onPublishFailed)
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
            listConfirmed: contactListConfirmed,
            readOnly: Self.activeAccountIsReadOnly
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
            publishContactList(rollback: previous, unfollowFrom: previous.pTags.count, onFailure: onPublishFailed)
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
    ///   all (empty, shrunk past the safety check, or a read-only account),
    ///   signing fails, or every relay refuses the event, and nothing has
    ///   changed the list since, it is put back so the screen never shows a
    ///   follow that was not published.
    /// - unfollowFrom: set by a single Unfollow tap; see `ContactManager.mayPublish`.
    func publishContactList(
        rollback: (pTags: [[String]], pubkeys: [String])? = nil,
        unfollowFrom: Int? = nil,
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
        guard ContactManager.mayPublish(tagCount: contactListPTags.count, lastFetchedCount: lastFetchedContactCount,
                                        unfollowFrom: unfollowFrom) else {
            #if DEBUG
            print("FeedService: BLOCKED contact list publish — \(contactListPTags.count) tags vs \(lastFetchedContactCount) fetched. Possible data loss.")
            #endif
            // After the caller's re-filter, so the rollback lands last.
            DispatchQueue.main.async { fail(nil) }
            return
        }
        // No key to sign with: don't try. Follow/unfollow already refuse
        // with `.readOnly` before the list changes; this covers any other
        // publish. `onFailure` reads the same check to say "read-only".
        guard !Self.activeAccountIsReadOnly else {
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
        // Every caller is a tap that carries the list it was made on.
        guard let before = rollback?.pTags else {
            DispatchQueue.main.async { fail(nil) }
            return
        }
        let owner = ConfigService.shared.activeAccountHexPubkey
        // One at a time, so a second tap builds on the first one's list.
        let previousPublish = Self.contactListPublishTail
        let publish = Task { @MainActor [weak self] in
            await previousPublish?.value
            guard let self else { return }
            // Never sign the copy loaded at launch: fetch the newest list right
            // now and apply only this tap's change to it (Logen 2026-10-31).
            let config = ConfigService.shared.config
            let lookup = await NostrService.shared.lookupNewestReplaceable(
                kind: 3, for: owner, alsoAsk: Array(config.readRelays.prefix(3)) + RelayDraft.indexers, skipAhead: true)
            guard owner == ConfigService.shared.activeAccountHexPubkey else { fail(nil); return }
            let base: (tags: [[String]], content: String, createdAt: Int64)
            switch ListMerge.editBase(lookup, held: Self.lastSignedContactList[owner], own: NostrService.ownListRelays(for: owner), createdAt: { $0.created_at }) {
            case .noRelayList:
                // onFailure's message says why (ContactManager.publishFailedMessage).
                fail(nil)
                return
            case .unknown:
                #if DEBUG
                print("FeedService: follow list not published — relays didn't answer (\(lookup.answered)/\(lookup.asked))")
                #endif
                fail(nil)
                return
            case .none: base = ([], "", 0)
            case .list(let newest): base = (newest.tags, newest.content, newest.created_at)
            }
            let tags = ListMerge.contactEdit(base: base.tags, before: before, after: attempted)
            let basePeople = base.tags.filter { $0.count >= 2 && $0[0] == "p" }.count
            let people = tags.filter { $0.count >= 2 && $0[0] == "p" }.count
            guard ContactManager.mayPublish(tagCount: people, lastFetchedCount: basePeople,
                                            unfollowFrom: unfollowFrom == nil ? nil : basePeople) else {
                fail(nil)
                return
            }
            // A later second than the list it replaces, or relays may keep that
            // one. editBase never picks a base dated ListMerge.maxSkew or more ahead.
            let signedAt = ListMerge.signedAt(now: Int64(Date().timeIntervalSince1970), base: base.createdAt)
            guard let event = await NostrService.shared.signEventAsync(kind: 3, content: base.content, tags: tags, notBefore: signedAt),
                  event.pubkey.lowercased() == owner.lowercased(),
                  owner == ConfigService.shared.activeAccountHexPubkey else {
                fail(nil)
                return
            }
            Self.lastSignedContactList[owner] = event
            // What went out is now the list, unless another tap is already on screen.
            if self.contactListPTags == attempted {
                let parsed = ContactManager.parseContactList(pTags: tags.filter { $0.count >= 2 && $0[0] == "p" })
                self.contactListPTags = parsed.pTags
                self.followedPubkeys = parsed.pubkeys
                self.lastFetchedContactCount = parsed.relayPTagCount
            }
            self.contactListContent = base.content
            self.recordOwnContactList(event: event)
            self.watchForRebuiltWeb()
            NostrService.shared.postEvent(event, onBroadcastOutcome: { outcome in
                guard outcome == .refused else { return }
                Task { @MainActor in fail(event.created_at) }
            })
        }
        Self.contactListPublishTail = publish
    }

    /// The last follow list signed here per account: the newest copy until
    /// the relays echo it back.
    @MainActor static var lastSignedContactList: [String: NostrEvent] = [:]
    /// The follow-list publish still running, so the next one waits for it.
    @MainActor static var contactListPublishTail: Task<Void, Never>?

    /// The active account has no kind 10002 of its own known here, so a
    /// follow list edit is refused (ListMerge.EditBase.noRelayList).
    static var activeAccountHasNoRelayList: Bool {
        NostrService.ownListRelays(for: ConfigService.shared.activeAccountHexPubkey).isEmpty
    }

    /// The active account has no key here and no bunker, so nothing it
    /// publishes can be signed.
    static var activeAccountIsReadOnly: Bool {
        let config = ConfigService.shared.config
        let activeNpub = config.activeAccountNpub.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasKey = activeNpub.isEmpty || activeNpub == config.ownerNpub
            ? !config.ownerNcryptsec.isEmpty || config.ownerHexKey != nil
            : ConfigService.shared.hasCredential(forNpub: activeNpub)
        return ContactManager.isReadOnly(signingMode: config.activeSigningMode(), hasKey: hasKey)
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

extension ConfigService {
    /// The active account can sign here: a key, or a bunker. A read-only
    /// sign-in gets no Post or Edit Profile, as on the web.
    var activeAccountCanSign: Bool { !FeedService.activeAccountIsReadOnly }
}
