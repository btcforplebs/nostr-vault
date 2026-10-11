package com.nostrvault.service

// ── Error types ───────────────────────────────────────────────────

sealed class FollowActionError : Exception() {
    data object ContactsNotLoaded : FollowActionError()
    data object SafetyCheckFailed : FollowActionError()
    data object AlreadyFollowing : FollowActionError()
    data object NotFollowing : FollowActionError()
}
