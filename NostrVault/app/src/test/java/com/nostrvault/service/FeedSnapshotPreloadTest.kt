package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** The launch read picks the snapshot the last visit saved and never crashes start-up on a bad file. */
class FeedSnapshotPreloadTest {

    @get:Rule val tmp = TemporaryFolder()

    @Test
    fun `the newest snapshot is the one read`() {
        val dir = tmp.root
        val older = dir.resolve("feed_snapshot_npub1old.json").apply { writeText("{}"); setLastModified(1_000_000L) }
        val newer = dir.resolve("feed_snapshot_owner.json").apply { writeText("{}"); setLastModified(2_000_000L) }
        dir.resolve("feed_mode_cache_DISCOVERY.json").apply { writeText("{}"); setLastModified(3_000_000L) }
        dir.resolve("feed_snapshot_dir.json").mkdir()

        assertEquals(newer, FeedSnapshotPreload.newestSnapshot(dir))
        older.delete()
        newer.delete()
        assertNull(FeedSnapshotPreload.newestSnapshot(dir))
    }

    @Test
    fun `a saved snapshot decodes`() {
        val file = tmp.newFile("feed_snapshot_owner.json")
        file.writeText(
            """{"notes":[],"followedPubkeys":["ab"],"noteStats":{},"contactListContent":"",""" +
                """"likedEventIds":[],"zappedEventIds":{},"savedAt":42,"unknownLater":1}""",
        )

        val snapshot = FeedSnapshotPreload.decode(file)

        assertEquals(42L, snapshot?.savedAt)
        assertEquals(listOf("ab"), snapshot?.followedPubkeys)
    }

    @Test
    fun `a torn or missing file reads as none`() {
        val torn = tmp.newFile("feed_snapshot_owner.json").apply { writeText("""{"notes":[""") }

        assertNull(FeedSnapshotPreload.decode(torn))
        assertNull(FeedSnapshotPreload.decode(tmp.root.resolve("feed_snapshot_gone.json")))
    }
}
