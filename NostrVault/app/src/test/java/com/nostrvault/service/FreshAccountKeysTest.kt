package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FreshAccountKeysTest {
    private val hex = "ab".repeat(32)

    @Test fun markMakesEveryListKindFresh() {
        val keys = FreshAccountKeys.marked(emptySet(), hex)
        assertTrue(FreshAccountKeys.isFresh(keys, hex, 3))
        assertTrue(FreshAccountKeys.isFresh(keys, hex, 10015))
        assertFalse(FreshAccountKeys.isFresh(keys, "cd".repeat(32), 3))
    }

    /** The scan-join follow publishes a kind 3; the guide's hashtag save must still start from empty. */
    @Test fun followListPublishLeavesHashtagListFresh() {
        val keys = FreshAccountKeys.cleared(FreshAccountKeys.marked(emptySet(), hex), hex, 3)
        assertFalse(FreshAccountKeys.isFresh(keys, hex, 3))
        assertTrue(FreshAccountKeys.isFresh(keys, hex, 10015))
        val both = FreshAccountKeys.cleared(keys, hex, 10015)
        assertFalse(FreshAccountKeys.isFresh(both, hex, 10015))
        assertTrue(both.isEmpty())
    }

    /** A bare mark from before the split meant every kind; clearing one keeps the rest. */
    @Test fun oldBareMarkSplitsOnFirstClear() {
        val old = setOf(hex)
        assertTrue(FreshAccountKeys.isFresh(old, hex, 10015))
        val keys = FreshAccountKeys.cleared(old, hex, 3)
        assertFalse(FreshAccountKeys.isFresh(keys, hex, 3))
        assertTrue(FreshAccountKeys.isFresh(keys, hex, 10015))
    }

    @Test fun clearingAnUnmarkedKeyChangesNothing() {
        val keys = setOf("other:3")
        assertEquals(keys, FreshAccountKeys.cleared(keys, hex, 3))
        assertFalse(FreshAccountKeys.isFresh(keys, "", 3))
    }
}
