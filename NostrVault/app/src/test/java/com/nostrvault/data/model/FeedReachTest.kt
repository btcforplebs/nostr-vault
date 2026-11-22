package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Test

/** Settings › Feed › Reach, as iOS `FeedReach` (phase 1.5). */
class FeedReachTest {
    @Test fun `Underrated reaches one hop out by default, every other feed its web`() {
        for (mode in FeedReach.modes) {
            val want = if (mode == FeedMode.UNDERRATED) WebGate.Reach.WEB_AND_LOOSE else WebGate.Reach.WEB
            assertEquals(mode.name, want, FeedReach.reach(mode, emptyMap()))
        }
        assertEquals(WebGate.Reach.WEB, FeedReach.reach(FeedMode.FOLLOWING, mapOf("Following" to "webAndHop3")))
        assertEquals(WebGate.Reach.WEB, FeedReach.reach(FeedMode.CATCH_UP, emptyMap()))
    }

    @Test fun `keys and words are iOS's, so the two apps read each other's`() {
        assertEquals(listOf("Discovery", "Global", "Popular", "Underrated", "Media"), FeedReach.modes.map(FeedReach::key))
        val ios = mapOf("Discovery" to "webAndHop3", "Underrated" to "web")
        assertEquals(WebGate.Reach.WEB_AND_LOOSE, FeedReach.reach(FeedMode.DISCOVERY, ios))
        assertEquals(WebGate.Reach.WEB, FeedReach.reach(FeedMode.UNDERRATED, ios))
    }

    @Test fun `Everyone, an unknown word or nothing saved is the default`() {
        for (word in listOf("everyone", "webAndLoose", "", "nonsense")) {
            assertEquals(word, WebGate.Reach.WEB, FeedReach.reach(FeedMode.GLOBAL, mapOf("Global" to word)))
            assertEquals(word, WebGate.Reach.WEB_AND_LOOSE, FeedReach.reach(FeedMode.UNDERRATED, mapOf("Underrated" to word)))
        }
    }

    @Test fun `the default is saved as absent, other settings kept`() {
        val start = mapOf("Global" to "webAndHop3")
        val set = FeedReach.setting(WebGate.Reach.WEB, FeedMode.UNDERRATED, start)
        assertEquals(mapOf("Global" to "webAndHop3", "Underrated" to "web"), set)
        assertEquals(start, FeedReach.setting(WebGate.Reach.WEB_AND_LOOSE, FeedMode.UNDERRATED, set))
        assertEquals(emptyMap<String, String>(), FeedReach.setting(WebGate.Reach.WEB, FeedMode.GLOBAL, start))
    }

    @Test fun `only Underrated is gated on Android so far, so only it has a row`() {
        assertEquals(listOf(FeedMode.UNDERRATED), FeedReach.gatedModes)
    }

    @Test fun `the loose set is saved lowercased, without the web or blanks`() {
        val clean = WebGate.cleanLoose(setOf("AB", "cd", "", "EF"), setOf("ef"))
        assertEquals(setOf("ab", "cd"), clean)
        val web = WebGate.Web(own = emptySet(), web = setOf("ef"), loose = clean)
        assertEquals(true, web.loose === clean)
    }
}
