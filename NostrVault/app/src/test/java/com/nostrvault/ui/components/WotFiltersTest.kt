package com.nostrvault.ui.components

import com.nostrvault.data.model.TrustMap
import org.junit.Assert.assertEquals
import org.junit.Test

class WotFiltersTest {

    @Test
    fun noTwoIconsInTheBarOrTheLayerMenuMatch() {
        val icons = TrustMap.Filter.entries.map { it.icon.name } + TrustMap.Layer.entries.map { it.icon.name }
        assertEquals(icons.toString(), icons.size, icons.toSet().size)
    }

    @Test
    fun filterFacesSkipYourFollowsAndRankWhoYouTalkWithFirst() {
        val lit = setOf("follow", "quiet", "chatty", "vouched")
        val faces = filterFaceCandidates(
            lit = lit,
            follows = setOf("follow"),
            engagement = mapOf("chatty" to 5, "follow" to 9),
            vouches = mapOf("vouched" to 12),
            count = 10,
        )
        assertEquals(listOf("chatty", "vouched", "quiet"), faces)
        assertEquals(listOf("chatty"), filterFaceCandidates(lit, setOf("follow"), mapOf("chatty" to 5), null, 1))
        assertEquals(emptyList<String>(), filterFaceCandidates(null, emptySet(), emptyMap(), null, 10))
    }
}
