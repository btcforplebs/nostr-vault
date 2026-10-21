package com.nostrvault.ui.screens.profile

import com.nostrvault.ui.screens.profile.ProfileLateTabs.Loaded
import com.nostrvault.ui.screens.profile.ProfileSection.*
import org.junit.Assert.assertEquals
import org.junit.Test

class ProfileLateTabsTest {
    private val nothing = Loaded(
        extrasLoading = false, hasArticles = false, hasReels = false, hasTracks = false,
        shopLoading = false, hasListings = false,
    )

    @Test fun extrasWaitUntilTheLoaderIsDone() {
        // Articles have landed but music is still being looked for: no tab yet.
        val partway = nothing.copy(extrasLoading = true, hasArticles = true)
        assertEquals(emptySet<ProfileSection>(), ProfileLateTabs.reveal(emptySet(), partway))
    }

    @Test fun extrasComeInTogether() {
        val done = nothing.copy(hasArticles = true, hasTracks = true)
        assertEquals(setOf(ARTICLES, MUSIC), ProfileLateTabs.reveal(emptySet(), done))
    }

    @Test fun shownTabsStayWhileARefreshRuns() {
        val refreshing = nothing.copy(extrasLoading = true, shopLoading = true)
        val shown = setOf(ARTICLES, SHOP)
        assertEquals(shown, ProfileLateTabs.reveal(shown, refreshing))
    }

    @Test fun aTabWithNothingLeftGoesOnceLoaded() {
        val done = nothing.copy(hasReels = true)
        assertEquals(setOf(DIVINES), ProfileLateTabs.reveal(setOf(ARTICLES, DIVINES, SHOP), done))
    }

    @Test fun shopFollowsItsOwnLoader() {
        // The shop answers while the extras are still loading.
        val shopIn = nothing.copy(extrasLoading = true, hasListings = true)
        assertEquals(setOf(SHOP), ProfileLateTabs.reveal(emptySet(), shopIn))
    }

    @Test fun visibleKeepsTheTabOrder() {
        assertEquals(
            listOf(NOTES, MEDIA, REPLIES, REPOSTS, TAGGED, MUSIC, SHOP),
            ProfileLateTabs.visible(setOf(SHOP, MUSIC), shopAlwaysVisible = false),
        )
    }

    @Test fun shopIsAlwaysOnTheProfileTab() {
        assertEquals(
            listOf(NOTES, MEDIA, REPLIES, REPOSTS, TAGGED, SHOP),
            ProfileLateTabs.visible(emptySet(), shopAlwaysVisible = true),
        )
        assertEquals(
            listOf(NOTES, MEDIA, REPLIES, REPOSTS, TAGGED),
            ProfileLateTabs.visible(emptySet(), shopAlwaysVisible = false),
        )
    }

    @Test fun aVanishedTabFallsBackToNotes() {
        val visible = ProfileLateTabs.visible(emptySet(), shopAlwaysVisible = false)
        assertEquals(NOTES, ProfileLateTabs.selection(MUSIC, visible))
        assertEquals(NOTES, ProfileLateTabs.selection(SHOP, visible))
    }

    @Test fun aShownTabIsKept() {
        val visible = ProfileLateTabs.visible(setOf(ARTICLES), shopAlwaysVisible = false)
        assertEquals(ARTICLES, ProfileLateTabs.selection(ARTICLES, visible))
        assertEquals(REPLIES, ProfileLateTabs.selection(REPLIES, visible))
    }
}
