package com.nostrvault.ui.screens

import org.junit.Assert.assertEquals
import org.junit.Test

class UploadServersSummaryTest {
    @Test
    fun `names the first server's host and counts the rest`() {
        assertEquals("No media server set", uploadServersSummary(emptyList()))
        assertEquals("Uploads to blossom.primal.net", uploadServersSummary(listOf("https://blossom.primal.net/")))
        assertEquals(
            "Uploads to blossom.primal.net and 2 more",
            uploadServersSummary(listOf("https://blossom.primal.net", "https://a.example", "https://b.example")),
        )
    }
}
