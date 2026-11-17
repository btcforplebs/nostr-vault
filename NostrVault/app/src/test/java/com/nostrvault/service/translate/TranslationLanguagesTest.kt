package com.nostrvault.service.translate

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TranslationLanguagesTest {

    @Test
    fun `English to or from a language is one model`() {
        assertEquals(listOf("es" to "en"), TranslationLanguages.plan("es", "en"))
        assertEquals(listOf("en" to "de"), TranslationLanguages.plan("en", "de"))
    }

    @Test
    fun `other pairs go through English`() {
        assertEquals(listOf("de" to "en", "en" to "fr"), TranslationLanguages.plan("de", "fr"))
    }

    @Test
    fun `same language needs nothing`() {
        assertTrue(TranslationLanguages.plan("ja", "ja").isEmpty())
    }

    @Test
    fun `fastText labels map to app codes`() {
        assertEquals("nb", TranslationLanguages.fromLanguageId("no"))
        assertEquals("he", TranslationLanguages.fromLanguageId("he"))
        assertEquals("zh", TranslationLanguages.fromLanguageId("zh"))
        assertEquals("de", TranslationLanguages.fromLanguageId("de"))
        // Languages Mozilla has no model for get no button.
        assertNull(TranslationLanguages.fromLanguageId("eo"))
        assertNull(TranslationLanguages.fromLanguageId("nn"))
    }

    @Test
    fun `Chinese is filed by script`() {
        assertEquals("zh-Hans", TranslationLanguages.mozillaCode("zh", traditionalChinese = false))
        assertEquals("zh-Hant", TranslationLanguages.mozillaCode("zh", traditionalChinese = true))
        assertEquals("ja", TranslationLanguages.mozillaCode("ja", traditionalChinese = true))
    }

    @Test
    fun `the offered languages all have both directions on Mozilla`() {
        // From the 2026-11-16 records list: mt and nn only go into English.
        assertTrue("mt" !in TranslationLanguages.SUPPORTED)
        assertTrue("en" in TranslationLanguages.SUPPORTED)
        assertEquals(57, TranslationLanguages.SUPPORTED.size)
    }
}
