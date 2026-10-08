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

    private fun layout(config: HavenConfig, mode: FeedMode) = FeedLayoutMode.resolve(
        storedLayout = config.feedLayoutModes[mode.name],
        storedCompact = config.feedCompactModes[mode.name],
        defaultCompact = config.useFeedCompactMode,
    )

    @Test
    fun `a new install opens the timeline feeds threaded`() {
        val fresh = HavenConfig.newInstall()
        for (mode in listOf(FeedMode.FOLLOWING, FeedMode.DISCOVERY, FeedMode.GLOBAL, FeedMode.HASHTAGS, FeedMode.POPULAR)) {
            assertEquals(mode.name, FeedLayoutMode.THREADED, layout(fresh, mode))
        }
        // Only those five: the media and article feeds keep their own layouts.
        assertEquals(5, fresh.feedLayoutModes.size)
    }

    @Test
    fun `a config saved before the setting keeps its compact choice`() {
        // Never cycled a layout, so the key was left out of the file.
        val old = json.decodeFromString(HavenConfig.serializer(), """{"ownerNpub":"npub1owner","useFeedCompactMode":true}""")
        assertTrue(old.feedLayoutModes.isEmpty())
        assertEquals(FeedLayoutMode.CONDENSED, layout(old, FeedMode.FOLLOWING))
    }

    @Test
    fun `the new install layouts survive a save and load`() {
        val saved = json.encodeToString(HavenConfig.serializer(), HavenConfig.newInstall())
        val loaded = json.decodeFromString(HavenConfig.serializer(), saved)
        assertEquals(HavenConfig.NEW_INSTALL_FEED_LAYOUTS, loaded.feedLayoutModes)
    }
}
