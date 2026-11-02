package com.nostrvault.service

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import java.io.File
import java.nio.file.Files

/** The vault's Blossom folder, looked up by hash without checking a dozen names per photo (iOS #1569). */
class BlossomFolderIndexTest {
    private lateinit var dir: File
    private val a = "a".repeat(64)
    private val b = "b".repeat(64)
    private var now = 0L
    private val index = BlossomFolderIndex { now }

    @Before fun setUp() {
        dir = Files.createTempDirectory("folder-index").toFile()
    }

    @After fun tearDown() {
        dir.deleteRecursively()
    }

    /** The folder was last changed at [date]; the clock reads well after it. */
    private fun settle(date: Long = 1_000_000_000L) {
        dir.setLastModified(date)
        now = dir.lastModified() + 60_000
    }

    @Test fun `misses do not list the folder again while nothing changed`() {
        File(dir, "$a.jpg").writeText("x")
        settle()
        assertEquals("$a.jpg", index.file(a, dir)?.name)
        repeat(50) { assertNull(index.file(b, dir)) }
        assertEquals(1, index.listings)
    }

    @Test fun `a file the relay adds is found on the next lookup`() {
        settle()
        assertNull(index.file(b, dir))
        File(dir, "$b.mp4").writeText("x")
        settle(1_000_100_000L)
        assertEquals("$b.mp4", index.file(b, dir)?.name)
    }

    @Test fun `a deleted file is gone on the next lookup`() {
        File(dir, "$a.jpg").writeText("x")
        settle()
        assertNotNull(index.file(a, dir))
        File(dir, "$a.jpg").delete()
        settle(1_000_100_000L)
        assertNull(index.file(a, dir))
    }

    @Test fun `a list read in the same moment the folder changed is read again`() {
        settle()
        now = dir.lastModified() + 500
        assertNull(index.file(a, dir))
        // Same folder date (a coarse clock), but the file landed after that listing.
        val date = dir.lastModified()
        File(dir, "$a.png").writeText("x")
        dir.setLastModified(date)
        assertEquals("$a.png", index.file(a, dir)?.name)
    }

    @Test fun `a corrupt copy or a stray name is never returned`() {
        File(dir, "$a.jpg.corrupt").writeText("x")
        File(dir, "${a}x.jpg").writeText("x")
        settle()
        assertNull(index.file(a, dir))
    }

    @Test fun `invalidate lists again`() {
        settle()
        index.file(a, dir)
        index.invalidate()
        index.file(a, dir)
        assertEquals(2, index.listings)
    }
}
