package com.nostrvault.service

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NoteTranslationPolicyTest {

    /** A slice of ML Kit's TranslateLanguage list; no Hindi-only gaps matter here. */
    private val supported = setOf("en", "de", "es", "fr", "ja", "zh", "pt", "he", "id", "ar", "ko")

    private val german = "Guten Morgen zusammen, heute ist ein schöner Tag."

    @Test
    fun `short notes get no button once links, refs, hashtags and mentions are gone`() {
        assertFalse(NoteTranslationPolicy.hasEnoughText("Hallo Welt"))
        assertFalse(
            NoteTranslationPolicy.hasEnoughText(
                "gm https://example.com/a-very-long-path nostr:npub1abcdefghijklmnop #bitcoin #nostrich @someone",
            ),
        )
        assertTrue(NoteTranslationPolicy.hasEnoughText(german))
    }

    @Test
    fun `letters are counted by code point`() {
        // 13 kanji/kana: CJK letters count one each, punctuation and emoji not at all.
        assertEquals(13, NoteTranslationPolicy.letterCount("今日はとても良い天気ですね。🌞!"))
        assertTrue(NoteTranslationPolicy.hasEnoughText("今日はとても良い天気ですね。"))
    }

    @Test
    fun `offered only for an identified language other than the target`() {
        assertTrue(NoteTranslationPolicy.shouldOffer(true, german, "de", "en"))
        assertFalse(NoteTranslationPolicy.shouldOffer(true, german, "de", "de"))
        assertFalse(NoteTranslationPolicy.shouldOffer(true, german, null, "en"))
        assertFalse(NoteTranslationPolicy.shouldOffer(false, german, "de", "en"))
        assertFalse(NoteTranslationPolicy.shouldOffer(true, "Hallo Welt", "de", "en"))
    }

    @Test
    fun `identified tags map to translatable codes`() {
        assertEquals("de", NoteTranslationPolicy.sourceLanguage("de", supported))
        assertEquals("zh", NoteTranslationPolicy.sourceLanguage("zh", supported))
        assertEquals("he", NoteTranslationPolicy.sourceLanguage("iw", supported))
        assertNull(NoteTranslationPolicy.sourceLanguage("und", supported))
        assertNull(NoteTranslationPolicy.sourceLanguage("ja-Latn", supported))
        assertNull(NoteTranslationPolicy.sourceLanguage("xx", supported))
        assertNull(NoteTranslationPolicy.sourceLanguage(null, supported))
    }

    @Test
    fun `target follows the saved choice, else the device, else English`() {
        assertEquals("fr", NoteTranslationPolicy.target("fr", listOf("de-DE"), supported))
        assertEquals("de", NoteTranslationPolicy.target("", listOf("de-DE", "en-US"), supported))
        assertEquals("es", NoteTranslationPolicy.target("", listOf("gsw-CH", "es-MX"), supported))
        assertEquals("en", NoteTranslationPolicy.target("", listOf("gsw-CH"), supported))
        assertEquals("id", NoteTranslationPolicy.target("", listOf("in-ID"), supported))
    }

    @Test
    fun `picker lists device languages first and only supported ones`() {
        val list = NoteTranslationPolicy.pickerList(listOf("ko-KR", "gsw-CH"), supported)
        assertEquals("ko", list.first())
        assertEquals(list.distinct(), list)
        assertTrue(list.all { it in supported })
        assertEquals(listOf("ko", "en", "es", "pt", "de", "fr", "ja", "zh", "ar", "id"), list)
    }

    @Test
    fun `segments keep link-only and blank lines untranslated`() {
        val segments = NoteTranslationPolicy.segments("Guten Morgen zusammen\n\nhttps://example.com\n#nostr #bitcoin")
        assertEquals(
            listOf(true, false, false, false),
            segments.map { it.translate },
        )
        assertEquals("https://example.com", segments[2].text)
    }
}
