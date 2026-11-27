package com.nostrvault.ui.screens.profile

import com.nostrvault.ui.screens.profile.ProfileSection.*
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ProfileTabSlotsTest {
    private val base = listOf(NOTES, MEDIA, REPLIES, REPOSTS, TAGGED)

    @Test fun threeIconTabsThenTheRestBehindMore() {
        val slots = ProfileTabSlots.of(base + listOf(ARTICLES, SHOP))
        assertEquals(listOf(NOTES, MEDIA, REPLIES), slots.tabs)
        assertEquals(listOf(REPOSTS, TAGGED, ARTICLES, SHOP), slots.more)
    }

    @Test fun sameRowOnYourOwnProfileAndOthers() {
        // Your own profile always has Shop (the Sell button); someone else's
        // only when they sell. The first three tabs are the same either way.
        val own = ProfileTabSlots.of(ProfileLateTabs.visible(emptySet(), shopAlwaysVisible = true))
        val other = ProfileTabSlots.of(ProfileLateTabs.visible(emptySet(), shopAlwaysVisible = false))
        assertEquals(own.tabs, other.tabs)
        assertEquals(listOf(REPOSTS, TAGGED, SHOP), own.more)
        assertEquals(listOf(REPOSTS, TAGGED), other.more)
    }

    @Test fun lateKindsJoinTheMoreListInOrder() {
        val visible = ProfileLateTabs.visible(setOf(MUSIC, ARTICLES, DIVINES), shopAlwaysVisible = false)
        assertEquals(listOf(REPOSTS, TAGGED, ARTICLES, DIVINES, MUSIC), ProfileTabSlots.of(visible).more)
    }

    @Test fun fourKindsAreFourTabsWithNoMore() {
        val slots = ProfileTabSlots.of(listOf(NOTES, MEDIA, REPLIES, REPOSTS))
        assertEquals(listOf(NOTES, MEDIA, REPLIES, REPOSTS), slots.tabs)
        assertEquals(emptyList<ProfileSection>(), slots.more)
    }

    @Test fun moreTabStandsForTheKindPickedFromIt() {
        val slots = ProfileTabSlots.of(base)
        assertEquals(TAGGED, ProfileTabSlots.moreSelection(slots, TAGGED))
        assertNull(ProfileTabSlots.moreSelection(slots, MEDIA))
    }
}
