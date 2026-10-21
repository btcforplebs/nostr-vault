package com.nostrvault.ui.screens.feed

import com.nostrvault.data.model.MarketCategory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The Marketplace grid and listing rules matched to iOS. */
class MarketplaceIosParityTest {

    @Test fun `seller fallback is npub and the last six of the key`() {
        val hex = "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d"
        assertEquals("npub…fa459d", sellerFallbackName(hex))
        assertEquals("npub…fa459d", sellerName(hex, null))
    }

    @Test fun `tapping the selected chip clears to All, another selects it`() {
        assertNull(toggledCategory(MarketCategory.entries[0], MarketCategory.entries[0]))
        assertEquals(MarketCategory.entries[1], toggledCategory(MarketCategory.entries[0], MarketCategory.entries[1]))
        assertEquals(MarketCategory.entries[1], toggledCategory(null, MarketCategory.entries[1]))
    }

    @Test fun `message seller is hidden on your own listing`() {
        assertFalse(showsMessageSeller("aa", "aa"))
        assertTrue(showsMessageSeller("aa", "bb"))
    }
}
