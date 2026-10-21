package com.nostrvault.ui.components

import com.nostrvault.data.model.TrustMap
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The WOT search's relay gate and row tags, as iOS `searchRelays` / `searchRow`. */
class WotSearchTest {
    @Test fun oneCharacterStaysLocal() {
        assertFalse(wotSearchesRelays(""))
        assertFalse(wotSearchesRelays("j"))
        assertTrue(wotSearchesRelays("jo"))
    }

    @Test fun partialNpubStaysLocal() {
        assertFalse(wotSearchesRelays("npub1abc"))
        assertFalse(wotSearchesRelays("NPUB1abc"))
        assertTrue(wotSearchesRelays("npub"))
    }

    @Test fun spinnerCapIsSixSeconds() {
        assertEquals(6_000L, WOT_SEARCH_SPINNER_CAP_MS)
    }

    @Test fun tagsYouFollowsAndWeb() {
        val me = "a".repeat(64)
        val other = "b".repeat(64)
        assertEquals("You", searchTag(TrustMap.PersonHit(me, TrustMap.Tier.OTHER), me))
        assertEquals("You follow", searchTag(TrustMap.PersonHit(other, TrustMap.Tier.FOLLOW), me))
        assertEquals("In your web", searchTag(TrustMap.PersonHit(other, TrustMap.Tier.WEB), me))
        assertNull(searchTag(TrustMap.PersonHit(other, TrustMap.Tier.OTHER), me))
    }
}
