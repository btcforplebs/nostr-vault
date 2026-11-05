package com.nostrvault.data.model

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * New-user hashtag loop (Logen 2026-11-05): hashtag views open screened while
 * Everyone is locked, not only with an empty web, and follows keep the top
 * group while screened. iOS twin: HashtagScreenedTests.swift.
 */
class HashtagScreenedTest {
    @Test
    fun screenedWhileUnderFiveFollowsEvenWithASmallWeb() {
        for (n in 0 until WotUnlock.MIN_FOLLOWS) {
            assertTrue("$n follows", WotUnlock.hashtagsScreened(everyoneIsOn = false, followCount = n, noWebYet = false))
        }
        assertTrue(WotUnlock.hashtagsScreened(everyoneIsOn = false, followCount = 0, noWebYet = true))
    }

    @Test
    fun fiveFollowsUseTheWebOfTrust() {
        assertFalse(WotUnlock.hashtagsScreened(everyoneIsOn = false, followCount = 5, noWebYet = false))
        assertFalse(WotUnlock.hashtagsScreened(everyoneIsOn = false, followCount = 300, noWebYet = false))
        assertTrue(WotUnlock.hashtagsScreened(everyoneIsOn = false, followCount = 300, noWebYet = true))
    }

    @Test
    fun everyoneOnIsNeverScreened() {
        assertFalse(WotUnlock.hashtagsScreened(everyoneIsOn = true, followCount = 0, noWebYet = true))
        assertFalse(WotUnlock.hashtagsScreened(everyoneIsOn = true, followCount = 2, noWebYet = false))
    }

    @Test
    fun followsKeepTheTopGroupWhenScreened() {
        val follows = setOf("friend")
        assertTrue(TopicFeedFilter.inFollowsGroup("friend", follows, trustScoped = false, screened = true))
        assertTrue(TopicFeedFilter.inFollowsGroup("friend", follows, trustScoped = true, screened = false))
        assertFalse(TopicFeedFilter.inFollowsGroup("stranger", follows, trustScoped = false, screened = true))
        assertFalse(TopicFeedFilter.inFollowsGroup("friend", follows, trustScoped = false, screened = false))
        assertTrue(TopicFeedFilter.keepsFollowsGroup(trustScoped = false, screened = true))
        assertFalse(TopicFeedFilter.keepsFollowsGroup(trustScoped = false, screened = false))
    }
}
