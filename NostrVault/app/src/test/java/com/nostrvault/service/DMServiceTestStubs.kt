package com.nostrvault.service

/** A FeedService with an empty Web of Trust, enough for DMService to start. */
internal fun stubFeedService(): dagger.Lazy<FeedService> {
    val feed = io.mockk.mockk<FeedService>(relaxed = true)
    io.mockk.every { feed.wotPubkeys } returns kotlinx.coroutines.flow.MutableStateFlow(emptySet())
    io.mockk.every { feed.followedPubkeys } returns kotlinx.coroutines.flow.MutableStateFlow(emptyList())
    return dagger.Lazy { feed }
}
