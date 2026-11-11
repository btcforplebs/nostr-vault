package com.nostrvault.ui.screens

import org.junit.Assert.assertEquals
import org.junit.Test

class VaultGridRowsTest {
    private fun item(sha: String) = BlossomMediaItem(
        sha256 = sha, displayUrl = "https://x/$sha", localFile = null, mimeType = null,
        size = null, uploaded = null, lastModified = null, isLocal = false,
    )

    private fun shas(rows: Map<String, List<BlossomMediaItem>>, sha: String) = rows.getValue(sha).map { it.sha256 }

    @Test fun titledSectionStartsANewRow() {
        val rows = vaultGridRows(
            listOf(
                MediaDateSection("Today", 0, listOf(item("a"), item("b"), item("c"), item("d"))),
                MediaDateSection("This Week", 4, listOf(item("e"))),
            ),
            columns = 3,
        )
        assertEquals(listOf("a", "b", "c"), shas(rows, "b"))
        assertEquals(listOf("d"), shas(rows, "d"))
        assertEquals(listOf("e"), shas(rows, "e"))
    }

    @Test fun untitledSectionCarriesOnTheRow() {
        val rows = vaultGridRows(
            listOf(
                MediaDateSection("", 0, listOf(item("a"), item("b"))),
                MediaDateSection("", 2, listOf(item("c"), item("d"))),
            ),
            columns = 3,
        )
        assertEquals(listOf("a", "b", "c"), shas(rows, "c"))
        assertEquals(listOf("d"), shas(rows, "d"))
    }
}
