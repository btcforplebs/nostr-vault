package com.nostrvault.relay

import com.nostrvault.data.model.FeedLayoutMode
import com.nostrvault.data.model.FeedMode
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** New installs open the timeline feeds in Threaded View; saved configs keep theirs (iOS e3decc63). */
class NewInstallFeedLayoutTest {
    /** As ConfigStore saves: values equal to their default are left out. */
    private val json = Json { ignoreUnknownKeys = true; prettyPrint = true }

    private fun layout(config: HavenConfig, mode: FeedMode) = FeedLayoutMode.resolve(config.feedLayoutModes[mode.name])

    @Test
    fun `a new install opens the timeline feeds threaded`() {
        val fresh = HavenConfig.newInstall()
        for (mode in listOf(FeedMode.FOLLOWING, FeedMode.DISCOVERY, FeedMode.GLOBAL, FeedMode.HASHTAGS, FeedMode.POPULAR,
            FeedMode.CATCH_UP, FeedMode.UNDERRATED)) {
            assertEquals(mode.name, FeedLayoutMode.THREADED, layout(fresh, mode))
        }
        // Only those seven: the media and article feeds keep their own layouts.
        assertEquals(7, fresh.feedLayoutModes.size)
    }

    @Test
    fun `a config saved before the setting opens expanded now that Compact View is gone`() {
        // Never cycled a layout, so the key was left out of the file.
        val old = json.decodeFromString(HavenConfig.serializer(), """{"ownerNpub":"npub1owner","useFeedCompactMode":true}""")
        assertTrue(old.feedLayoutModes.isEmpty())
        assertEquals(FeedLayoutMode.EXPANDED, layout(old, FeedMode.FOLLOWING))
    }

    @Test
    fun `a saved condensed feed decodes without a crash and reads as expanded`() {
        val old = json.decodeFromString(
            HavenConfig.serializer(),
            """{"ownerNpub":"npub1owner","feedLayoutModes":{"FOLLOWING":"condensed","GLOBAL":"threaded"}}""",
        )
        assertEquals(FeedLayoutMode.EXPANDED, layout(old, FeedMode.FOLLOWING))
        assertEquals(FeedLayoutMode.THREADED, layout(old, FeedMode.GLOBAL))
    }

    @Test
    fun `the new install layouts survive a save and load`() {
        val saved = json.encodeToString(HavenConfig.serializer(), HavenConfig.newInstall())
        val loaded = json.decodeFromString(HavenConfig.serializer(), saved)
        assertEquals(HavenConfig.NEW_INSTALL_FEED_LAYOUTS, loaded.feedLayoutModes)
    }
}
