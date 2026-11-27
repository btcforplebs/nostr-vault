package com.nostrvault.ui.screens

import org.junit.Assert.assertEquals
import org.junit.Test

/** D1: the Media list row's detail line (iOS twin MediaItemSizeTests.testRowLine). */
class MediaRowLineTest {
    private fun item(id: Char, mime: String?) = BlossomMediaItem(
        sha256 = id.toString().repeat(64), displayUrl = "https://m.example/$id", localFile = null,
        mimeType = mime, size = null, uploaded = 1, lastModified = null, isLocal = false,
    )

    @Test fun rowLineReadsSizeTypeDate() {
        val now = java.time.LocalDate.of(2026, 11, 20)
        val utc = java.time.ZoneOffset.UTC
        val nov3 = java.time.LocalDateTime.of(2026, 11, 3, 12, 0).toEpochSecond(utc)
        val old = java.time.LocalDateTime.of(2024, 11, 3, 12, 0).toEpochSecond(utc)
        assertEquals("2.3 MB \u00B7 Video \u00B7 3 Nov", MediaRowLine.text(2_400_000, "Video", nov3, now, utc, java.util.Locale.UK))
        assertEquals("\u2014 \u00B7 Photo \u00B7 3 Nov 2024", MediaRowLine.text(null, "Photo", old, now, utc, java.util.Locale.UK))
        assertEquals("\u2014 \u00B7 File", MediaRowLine.text(0, "File", 0, now, utc, java.util.Locale.UK))
        assertEquals("GIF", MediaRowLine.typeLabel(item('g', "image/gif")))
        assertEquals("m.example", MediaRowLine.host("https://m.example/abc"))
    }
}
