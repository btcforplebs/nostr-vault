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
}
