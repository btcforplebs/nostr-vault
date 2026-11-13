package com.nostrvault.fips

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** Tron's PR 2024 F1: a drain pass writes its outcomes in one go, and emoji notes go after photos. */
class QueueDrainBatchTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private fun sha(i: Int) = "%064x".format(i)

    private fun emoji(i: Int, code: String = "e$i") = HomeVaultQueue.FileNoteDraft(
        HomeVaultQueue.FileNoteDraft.EMOJI, sha(i), "image/png", 7, emptyList(), listOf(listOf(code, "https://x.example/$i.png")), emptyList(),
    )

    @Test
    fun `outcomes drop sent items, keep retries, and leave alone what changed since it was tried`() {
        val q = HomeVaultQueue(tmp.newFolder())
        q.addFileNotes((1..4).map { emoji(it) })
        val tried = q.items()
        // A newer word for note 3 arrives while the pass is sending.
        q.addFileNote(emoji(3, "newer"))
        val retry = tried[1].copy(attempts = 1, nextAt = 99)
        q.applyOutcomes(listOf(tried[0] to null, tried[1] to retry, tried[2] to null))
        val left = q.items().associateBy { it.key }
        assertFalse(HomeVaultQueue.emojiNoteKey(sha(1)) in left)
        assertEquals(retry, left[HomeVaultQueue.emojiNoteKey(sha(2))])
        assertEquals("newer", left[HomeVaultQueue.emojiNoteKey(sha(3))]?.fileNote?.emojiCodes?.single()?.get(0))
        assertTrue(HomeVaultQueue.emojiNoteKey(sha(4)) in left)
    }

    @Test
    fun `a dropped blob takes its file with it`() {
        val q = HomeVaultQueue(tmp.newFolder())
        q.addBlob(sha(7), "image/png", 1) { it.writeText("x") }
        val item = q.items().single()
        assertTrue(q.blobFile(sha(7)).exists())
        q.applyOutcomes(listOf(item to null))
        assertEquals(0, q.size)
        assertFalse(q.blobFile(sha(7)).exists())
    }

    @Test
    fun `a pass sends emoji notes after photos and plain notes`() {
        val q = HomeVaultQueue(tmp.newFolder())
        q.addFileNotes((1..3).map { emoji(it) })
        q.addBlob(sha(50), "image/png", 1) { it.writeText("x") }
        q.addFileNote(HomeVaultQueue.FileNoteDraft(HomeVaultQueue.FileNoteDraft.ADD, sha(50), "image/png", 1))
        val order = HomeVaultRules.select(q.items(), now = 0, userInitiated = false, localSigner = true, needsSignature = { false }).toTry
        assertEquals(listOf(sha(50), HomeVaultQueue.fileNoteKey(sha(50))), order.take(2).map { it.key })
        assertTrue(order.drop(2).all { it.fileNote?.action == HomeVaultQueue.FileNoteDraft.EMOJI })
    }
}
