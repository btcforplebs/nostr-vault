package com.nostrvault.service.translate

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class LanguageIdGuessTest {
    @Test
    fun `parses the native label and probability`() {
        assertEquals(LanguageIdentifier.Guess("de", 0.973), LanguageIdentifier.Guess.parse("de 0.973000"))
    }

    @Test
    fun `no guess or junk is null`() {
        assertNull(LanguageIdentifier.Guess.parse(""))
        assertNull(LanguageIdentifier.Guess.parse(null))
        assertNull(LanguageIdentifier.Guess.parse("de"))
        assertNull(LanguageIdentifier.Guess.parse("de x"))
    }
}
