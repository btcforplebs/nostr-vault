import Foundation

extension FeedService {
    /// Follows several people in one edit of the follow list, published as
    /// one kind 3 (setup's referrer step: the referrer and the people picked
    /// under them). Until the account's real list is known they wait in the
    /// follow queue, and go out together when it loads
    /// (`applyPendingFollowActions`). Yourself and people already followed
    /// are skipped. Nothing is said on screen: setup has just shown who.
    /// `onPublishFailed`: as for `followUser`.
    func followUsers(_ pubkeys: [String], onPublishFailed: (() -> Void)? = nil) {
        let me = ConfigService.shared.activeAccountHexPubkey
        let wanted = pubkeys.filter { $0 != me }
        guard !wanted.isEmpty else { return }
        switch ContactManager.prepareFollowMany(
            pubkeys: wanted,
            currentPTags: contactListPTags,
            currentPubkeys: followedPubkeys,
            hasAttemptedLoad: hasAttemptedContactLoad,
            isLoading: isLoadingContacts,
            listConfirmed: contactListConfirmed,
            readOnly: Self.activeAccountIsReadOnly
        ) {
        case .failure(.contactsNotLoaded), .failure(.listUnavailable):
            for pubkey in wanted { queueFollowAction(pubkey, follow: true) }
        case .failure:
            return
        case .success(let result):
            applyFollowEdit(pTags: result.pTags, pubkeys: result.pubkeys, onPublishFailed: onPublishFailed)
        }
    }

    /// Puts a prepared follow edit on screen and publishes it, rolling back
    /// if it can't go out. Shared by one follow and many.
    func applyFollowEdit(pTags: [[String]], pubkeys: [String], onPublishFailed: (() -> Void)?) {
        let previous = (pTags: contactListPTags, pubkeys: followedPubkeys)
        contactListPTags = pTags
        followedPubkeys = pubkeys
        publishContactList(rollback: previous, onFailure: onPublishFailed)
        // Re-filter so already-loaded notes from the newly-followed authors
        // surface immediately in the Following feed.
        recomputeFilteredNotes()
        // Re-issue the live primary REQ so the new follows' FUTURE notes
        // stream in without waiting for a full refresh.
        resubscribePrimaryIfNeeded()

        // Auto-switch back to Following now that the user has follows.
        if didAutoSwitchToCurated {
            didAutoSwitchToCurated = false
            switchMode(.following)
        }
    }
}
