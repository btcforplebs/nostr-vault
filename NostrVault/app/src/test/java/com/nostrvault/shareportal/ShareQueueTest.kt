package com.nostrvault.shareportal

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class ShareQueueTest {
    @get:Rule val tmp = TemporaryFolder()

    private fun queue() = ShareQueue(File(tmp.root, "queue"), File(tmp.root, "claimed"))

    private fun intent(id: String, created: Long = 1, files: List<ShareFile> = emptyList()) =
        ShareIntent(id, created, ShareAction.HIGHLIGHT, source = ShareSource(url = "https://e.com"), files = files)

    @Test fun commitThenClaimMovesItOnce() {
        val q = queue()
        assertTrue(q.commit(intent("one")))
        assertTrue(q.hasPending)
        assertEquals(listOf("one"), q.claimAll().map { it.id })
        assertFalse(q.hasPending)
        // A second claim (another activation) wins nothing.
        assertEquals(emptyList<ShareIntent>(), q.claimAll())
        assertEquals(listOf("one"), q.claimed().map { it.id })
    }

    @Test fun filesTravelWithTheirIntentAndFinishDeletesThem() {
        val q = queue()
        val staged = q.stageFile("withfile", "page.pdf")!!
        staged.writeText("pdf")
        val f = ShareFile("page.pdf", "application/pdf", ShareIntent.filePath("withfile", "page.pdf"), 3)
        assertTrue(q.commit(intent("withfile", files = listOf(f))))
        val claimed = q.claimAll().single()
        val copy = q.claimedFile(claimed, f)!!
        assertEquals("pdf", copy.readText())
        assertFalse(staged.exists())
        q.finish("withfile")
        assertFalse(copy.exists())
        assertEquals(emptyList<ShareIntent>(), q.claimed())
    }

    @Test fun aPartialWriteIsNeverPending() {
        val dir = File(tmp.root, "queue").apply { mkdirs() }
        File(dir, ".partial-x.json").writeText(intent("x").encode())
        assertEquals(emptyList<String>(), queue().pendingIds())
    }

    @Test fun brokenOrMismatchedIntentsAreDeletedNotShown() {
        val dir = File(tmp.root, "queue").apply { mkdirs() }
        File(dir, "bad.json").writeText("{not json")
        File(dir, "liar.json").writeText(intent("other").encode())
        File(dir, "files/bad").mkdirs()
        File(dir, "files/bad/x").writeText("x")
        val q = queue()
        assertEquals(emptyList<ShareIntent>(), q.claimAll())
        assertEquals(emptyList<ShareIntent>(), q.claimed())
        assertFalse(File(tmp.root, "claimed/files/bad").exists())
        assertFalse(File(tmp.root, "claimed/bad.json").exists())
    }

    @Test fun unsafeNamesAreRefused() {
        val q = queue()
        assertNull(q.stageFile("../x", "a"))
        assertNull(q.stageFile("ok", "../a"))
        assertNull(q.stageFile("ok", ".hidden"))
        assertNull(q.stageFile("ok", "a/b"))
        assertFalse(q.commit(intent("a/b")))
        // A file named like a traversal in the queue folder is dropped.
        File(tmp.root, "queue").mkdirs()
        File(tmp.root, "queue/..json").writeText("{}")
        assertEquals(emptyList<String>(), q.pendingIds())
    }

    @Test fun claimedComesBackOldestFirst() {
        val q = queue()
        q.commit(intent("b", created = 20))
        q.commit(intent("a", created = 30))
        q.commit(intent("c", created = 10))
        q.claimAll()
        assertEquals(listOf("c", "b", "a"), q.claimed().map { it.id })
    }

    @Test fun accountsSnapshotRoundTripsAndRejectsJunk() {
        val file = File(tmp.root, "share_portal/accounts.json")
        val snap = ShareAccountsSnapshot("npub1a", listOf(ShareAccountsSnapshot.Account("npub1a", "Me", "https://x/p.jpg")))
        assertTrue(ShareAccountsSnapshot.write(file, snap))
        assertEquals(snap, ShareAccountsSnapshot.read(file))
        assertNull(ShareAccountsSnapshot.decode("""{"v":2,"active":"","accounts":[]}"""))
        assertEquals(emptyList<ShareAccountsSnapshot.Account>(),
            ShareAccountsSnapshot.decode("""{"v":1,"active":"","accounts":[{"npub":"nsec1x","name":"k"}]}""")!!.accounts)
    }
}
