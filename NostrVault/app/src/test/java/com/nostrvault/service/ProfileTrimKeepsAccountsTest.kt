package com.nostrvault.service

import com.nostrvault.data.model.FeedProfile
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The profile map is trimmed to its freshest entries; the switcher's accounts
 * must survive the trim however stale, or the switcher and the bottom bar
 * fall back to initials (Android port of iOS #1240).
 */
class ProfileTrimKeepsAccountsTest {
    private fun profile(hex: String, fetchedAt: Long?) =
        FeedProfile(pubkey = hex, pictureURL = "https://pics.example/$hex.jpg", fetchedAt = fetchedAt)

    private val feed = (1..50).associate { "feed$it" to profile("feed$it", 10_000L + it) }
    private val accounts = mapOf(
        "owner" to profile("owner", 1L),
        "second" to profile("second", 2L),
        "active" to profile("active", null),
    )

    @Test
    fun accountsSurviveATrimThatFillsWithFresherFeedProfiles() {
        val trimmed = trimProfileMap(feed + accounts, keep = 10, always = accounts.keys)

        accounts.forEach { (hex, p) -> assertEquals(p.pictureURL, trimmed[hex]?.pictureURL) }
        // The budget still bounds everything else: the 10 freshest feed profiles.
        assertEquals((41..50).map { "feed$it" }.toSet(), trimmed.keys - accounts.keys)
    }

    @Test
    fun accountsDoNotSpendTheBudget() {
        val trimmed = trimProfileMap(feed + accounts, keep = 10, always = accounts.keys)
        assertEquals(13, trimmed.size)
    }

    @Test
    fun anAccountWithNoProfileYetIsNotInvented() {
        val trimmed = trimProfileMap(feed, keep = 5, always = setOf("never-fetched"))
        assertTrue("never-fetched" !in trimmed)
        assertEquals(5, trimmed.size)
    }
}
