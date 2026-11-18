package com.nostrvault.ui.screens.dashboard

import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test
import java.io.File

/** The list under Copy draws at most 100 rows: 8,000 at once ran a Moto out of memory (2026-11-17). */
class ShownCopyFilesTest {
    private fun file(i: Int, status: MediaCopyFile.Status = MediaCopyFile.Status.Waiting) = MediaCopyFile(
        hash = i.toString().padStart(64, '0'), file = File("/x/$i"), kind = MediaCopyFile.Kind.values().first(),
        size = 1, addedMillis = i.toLong(), servers = listOf("s"), status = status,
    )

    @Test
    fun `a short list is drawn whole, as is`() {
        val files = (0 until 100).map { file(it) }
        assertSame(files, shownCopyFiles(files))
    }

    @Test
    fun `a long list draws sending, then failed, then the rest, capped`() {
        val failed = MediaCopyFile.Status.Failed(listOf(MediaCopyFile.Failure("s", "503")))
        val files = (0 until 8000).map { i ->
            when (i) {
                7000 -> file(i, MediaCopyFile.Status.Copying)
                5000, 6000 -> file(i, failed)
                else -> file(i)
            }
        }
        val shown = shownCopyFiles(files)
        assertEquals(MediaCopyFile.SHOWN_MAX, shown.size)
        assertEquals(listOf(7000L, 5000L, 6000L, 0L, 1L), shown.take(5).map { it.addedMillis })
    }
}
