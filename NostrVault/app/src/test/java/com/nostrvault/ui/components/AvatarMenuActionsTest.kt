package com.nostrvault.ui.components

import com.nostrvault.service.FeedService
import io.mockk.every
import io.mockk.mockk
import io.mockk.verify
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AvatarMenuActionsTest {
    private val feed = mockk<FeedService>(relaxed = true)
    private val menu = avatarMenuActions(feed) { it == "me" }

    @Test fun ownAvatarHasNoMenu() {
        assertTrue(menu.isOwn("me"))
        assertFalse(menu.isOwn("them"))
    }

    @Test fun readsFollowStateFromTheFeed() {
        every { feed.isFollowing("them") } returns true
        assertTrue(menu.isFollowed("them"))
        assertFalse(menu.isFollowed("other"))
    }

    @Test fun actionsGoToTheFeed() {
        menu.onFollow("a")
        menu.onUnfollow("b")
        menu.onBlock("c")
        verify { feed.followUser("a", null) }
        verify { feed.unfollowUser("b", null) }
        verify { feed.blockUser("c") }
    }
}
