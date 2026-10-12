package com.nostrvault.service

// ── Error types ───────────────────────────────────────────────────

sealed class FollowActionError : Exception() {
    data object ContactsNotLoaded : FollowActionError()
    /** No key on this phone and no outside signer: the account can read but not sign. */
    data object ReadOnly : FollowActionError()
    data object AlreadyFollowing : FollowActionError()
    data object NotFollowing : FollowActionError()
}
