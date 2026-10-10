package com.nostrvault.ui.screens.feed

/**
 * What a follow-set feed (Following, and the Following side of Media,
 * Articles and Polls) shows while it has no notes. Port of iOS
 * `FollowingFeedState`.
 *
 * "You follow nobody" is a conclusion, and it needs a contact load that
 * actually finished behind it. Read off the loading flags alone it is true in
 * the first seconds of every launch, before anything has started, which is
 * exactly when someone is looking.
 */
internal enum class FollowingFeedPlaceholder {
    /** Notes, or an honest empty list: enough is known to draw the feed. */
    FEED,
    /** The follow set is not known yet. Never say "follow someone" here. */
    LOADING,
    /** The follow set is empty, and a finished load says so. */
    EMPTY,
}

internal fun followingFeedPlaceholder(
    followCount: Int,
    hasAttemptedContactLoad: Boolean,
    isLoadingContacts: Boolean,
    isLoadingFeed: Boolean,
    hasNotes: Boolean,
): FollowingFeedPlaceholder = when {
    // Readable notes outrank everything, whatever the follow set turns out to be.
    hasNotes -> FollowingFeedPlaceholder.FEED
    isLoadingContacts || isLoadingFeed -> FollowingFeedPlaceholder.LOADING
    // A follow set seeded from the local backup is a guess, not an answer.
    !hasAttemptedContactLoad -> FollowingFeedPlaceholder.LOADING
    followCount > 0 -> FollowingFeedPlaceholder.FEED
    else -> FollowingFeedPlaceholder.EMPTY
}
