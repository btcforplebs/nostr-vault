package com.nostrvault.ui.components

import com.nostrvault.data.model.TrustMap
import com.nostrvault.data.model.TrustPath
import org.junit.Assert.assertEquals
import org.junit.Test

/** The WOT globe's own frame keeps what it found when your follows change (iOS TrustWebView). */
class TrustFrameTest {
    private val path = TrustPath(TrustPath.Reach.BRIDGED, listOf("b1", "b2"), true)

    @Test fun `a new follow list keeps bridges, seen lists and chains`() {
        val chains = listOf(TrustMap.Chain(bridge = "x", via = "y"))
        val found = TrustFrame("me", listOf("a", "b"), true, path).copy(
            bridges = listOf("b1", "b2", "b3"), seen = setOf("b1", "b2", "b3", "s"), exhausted = true, chains = chains,
        )
        val updated = found.withRing(listOf("a", "c"))
        assertEquals(listOf("a", "c"), updated.ring)
        assertEquals(setOf("a", "c"), updated.ringSet)
        assertEquals(found.bridges, updated.bridges)
        assertEquals(found.seen, updated.seen)
        assertEquals(true, updated.exhausted)
        assertEquals(chains, updated.chains)
    }

    @Test fun `a new author path keeps bridges you still follow and adds the new ones`() {
        val found = TrustFrame("me", listOf("b1", "b2"), true, path).copy(bridges = listOf("b1", "b2"), seen = setOf("s"))
        val traced = TrustPath(TrustPath.Reach.FOLLOW, listOf("b1", "b3"), false, listOf("b1", "b3"))
        // b2 was unfollowed; b3 is a new follow who follows the author.
        val updated = found.withPath(traced, follows = setOf("b1", "b3", "author"))
        assertEquals(traced, updated.path)
        assertEquals(listOf("b1", "b3"), updated.bridges)
        assertEquals(setOf("s"), updated.seen)
    }
}
